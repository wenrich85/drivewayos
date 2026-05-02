defmodule DrivewayOSWeb.BookingLive do
  @moduledoc """
  Customer booking wizard at `{slug}.lvh.me/book`.

  Four-step flow (signed-in customers only — guest checkout lands
  in Phase A4):

      1. service   — pick a ServiceType
      2. vehicle   — pick saved OR add new (Pro+) / free-text (Starter)
      3. address   — pick saved OR add new (Pro+) / free-text (Starter)
      4. schedule  — slot picker (or datetime fallback) + notes + submit

  Wizard state lives in the socket's `:wizard_step` (atom) and
  `:wizard_data` (map accumulated across steps). Each step has its
  own form whose submit handler validates that step + advances.
  Back buttons preserve state.

  Feature gating:
    * `:saved_vehicles` / `:saved_addresses` — when off (Starter),
      the vehicle + address steps render free-text inputs only,
      no list of saved entries
    * Submit logic identical at all tiers — the resulting
      Appointment carries `vehicle_id` / `address_id` only when
      a saved row was selected; the denormalized `vehicle_description`
      / `service_address` strings are always populated as the
      historical snapshot

  Stripe Connect routing on the schedule-step submit is unchanged
  from the V1 single-form version.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.AppointmentBroadcaster
  alias DrivewayOS.Billing.StripeClient
  alias DrivewayOS.Fleet.{Address, Vehicle}
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.{BookingEmail, BookingSms}
  alias DrivewayOS.Plans
  alias DrivewayOS.Scheduling.{Appointment, BookingDraft, Photo, ServiceType}
  alias DrivewayOS.Uploads

  require Ash.Query

  # Platform's cut on every booking, in basis points.
  @application_fee_bps 1000

  @impl true
  def mount(params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) and
          not Plans.tenant_can?(socket.assigns.current_tenant, :guest_checkout) ->
        # Tenant disallows guests + nobody's signed in → bounce to
        # /sign-in (existing V1 behavior).
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        tenant = socket.assigns.current_tenant
        signed_in = socket.assigns.current_customer

        # Admins can pass `?on_behalf_of=<customer_id>` to drive the
        # wizard for a phone walk-in. The override only applies when
        # the signed-in customer is an admin AND the target row exists
        # in this tenant — anything else falls back to a normal
        # self-booking flow.
        {customer, acting_admin} =
          case maybe_resolve_on_behalf(signed_in, tenant.id, params["on_behalf_of"]) do
            nil -> {signed_in, nil}
            target -> {target, signed_in}
          end

        services = load_services(tenant.id)
        slots = DrivewayOS.Scheduling.upcoming_slots(tenant.id, 14)

        saved_vehicles =
          if customer && Plans.tenant_can?(tenant, :saved_vehicles),
            do: load_saved_vehicles(customer.id, tenant.id),
            else: []

        saved_addresses =
          if customer && Plans.tenant_can?(tenant, :saved_addresses),
            do: load_saved_addresses(customer.id, tenant.id),
            else: []

        {restored_step, restored_data} =
          case params["from"] do
            from when is_binary(from) and from != "" ->
              # ?from=<appt_id> seeds the wizard with that prior
              # appointment's service / vehicle / address. The
              # signed-in customer must own it (Ash multitenancy
              # filters cross-tenant; we double-check ownership).
              prefill_from_appointment(tenant.id, customer, from)

            _ ->
              restore_draft(tenant.id, customer)
          end

        socket =
          socket
          |> assign(:page_title, "Book a wash")
          |> assign(:services, services)
          |> assign(:slots, slots)
          |> assign(:saved_vehicles, saved_vehicles)
          |> assign(:saved_addresses, saved_addresses)
          |> assign(:wizard_step, restored_step)
          |> assign(:wizard_data, restored_data)
          |> assign(:vehicle_mode, initial_mode(saved_vehicles))
          |> assign(:address_mode, initial_mode(saved_addresses))
          |> assign(:account_mode, :guest)
          |> assign(:loyalty_can_redeem?, loyalty_can_redeem?(tenant, customer))
          |> assign(:current_customer, customer)
          |> assign(:acting_admin, acting_admin)
          |> assign(:errors, %{})

        socket =
          if Plans.tenant_can?(tenant, :booking_photos) do
            allow_upload(socket, :photos,
              accept: ~w(.jpg .jpeg .png .heic .webp),
              max_entries: 5,
              max_file_size: 10_000_000
            )
          else
            socket
          end

        {:ok, socket}
    end
  end

  # Returns the target Customer when the signed-in row is an admin
  # AND the requested customer exists in this tenant. Anything else
  # returns nil so the caller falls back to normal self-booking.
  defp maybe_resolve_on_behalf(_, _, nil), do: nil
  defp maybe_resolve_on_behalf(_, _, ""), do: nil

  defp maybe_resolve_on_behalf(%{role: :admin}, tenant_id, id) when is_binary(id) do
    case Ash.get(DrivewayOS.Accounts.Customer, id, tenant: tenant_id, authorize?: false) do
      {:ok, target} -> target
      _ -> nil
    end
  end

  defp maybe_resolve_on_behalf(_, _, _), do: nil

  # --- Step 1: service ---

  @impl true
  def handle_event("submit_service", %{"booking" => %{"service_type_id" => id}}, socket) do
    case fetch_service(id, socket.assigns.current_tenant.id) do
      {:ok, _svc} ->
        socket
        |> put_data(:service_type_id, id)
        |> assign(:errors, %{})
        |> advance_to(after_service_step(socket))
        |> noreply()

      _ ->
        {:noreply, assign(socket, :errors, %{service_type_id: "Pick a service"})}
    end
  end

  # --- Step 2 (conditional): account ---

  def handle_event("set_account_mode", %{"mode" => mode}, socket) do
    {:noreply,
     socket
     |> assign(:account_mode, String.to_existing_atom(mode))
     |> assign(:errors, %{})}
  end

  def handle_event("submit_account_guest", %{"guest" => params}, socket) do
    tenant = socket.assigns.current_tenant

    attrs = %{
      email: params["email"] |> to_string() |> String.trim() |> String.downcase(),
      name: params["name"] |> to_string() |> String.trim(),
      phone: params["phone"]
    }

    case DrivewayOS.Accounts.Customer
         |> Ash.Changeset.for_create(:register_guest, attrs, tenant: tenant.id)
         |> Ash.create(authorize?: false) do
      {:ok, customer} ->
        socket
        |> assign(:current_customer, customer)
        |> assign(:errors, %{})
        |> advance_to(:vehicle)
        |> noreply()

      {:error, %Ash.Error.Invalid{} = e} ->
        {:noreply, assign(socket, :errors, ash_errors_to_map(e))}

      _ ->
        {:noreply, assign(socket, :errors, %{base: "Couldn't continue as guest."})}
    end
  end

  def handle_event("submit_account_signin", %{"signin" => %{"email" => email, "password" => pw}}, socket) do
    tenant = socket.assigns.current_tenant

    case DrivewayOS.Accounts.Customer
         |> Ash.Query.for_read(
           :sign_in_with_password,
           %{email: email, password: pw},
           tenant: tenant.id
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %{__metadata__: %{token: token}} = customer} ->
        # Store the token so the customer is signed in for the rest
        # of the wizard + after the booking completes.
        socket
        |> assign(:current_customer, customer)
        |> assign(:wizard_token, token)
        |> assign(:errors, %{})
        |> advance_to(:vehicle)
        |> noreply()

      _ ->
        {:noreply, assign(socket, :errors, %{base: "Invalid email or password."})}
    end
  end

  def handle_event("submit_account_register", %{"register" => params}, socket) do
    tenant = socket.assigns.current_tenant

    attrs = %{
      email: params["email"] |> to_string() |> String.trim() |> String.downcase(),
      name: params["name"] |> to_string() |> String.trim(),
      phone: params["phone"],
      password: params["password"],
      password_confirmation: params["password"]
    }

    case DrivewayOS.Accounts.Customer
         |> Ash.Changeset.for_create(:register_with_password, attrs, tenant: tenant.id)
         |> Ash.create(authorize?: false) do
      {:ok, %{__metadata__: %{token: token}} = customer} ->
        socket
        |> assign(:current_customer, customer)
        |> assign(:wizard_token, token)
        |> assign(:errors, %{})
        |> advance_to(:vehicle)
        |> noreply()

      {:error, %Ash.Error.Invalid{} = e} ->
        {:noreply, assign(socket, :errors, ash_errors_to_map(e))}

      _ ->
        {:noreply, assign(socket, :errors, %{base: "Couldn't create account."})}
    end
  end

  # --- Step 2: vehicle ---

  def handle_event("set_vehicle_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :vehicle_mode, String.to_existing_atom(mode))}
  end

  def handle_event("submit_vehicle_picked", %{"booking" => %{"vehicle_id" => id}}, socket) do
    case Enum.find(socket.assigns.saved_vehicles, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, :errors, %{vehicle_id: "Pick a vehicle"})}

      v ->
        socket
        |> put_data(:vehicle_id, v.id)
        |> put_data(:vehicle_description, Vehicle.display_label(v))
        |> assign(:errors, %{})
        |> advance_to(:address)
        |> noreply()
    end
  end

  def handle_event("submit_vehicle_new", %{"vehicle" => params}, socket) do
    tenant = socket.assigns.current_tenant
    customer = socket.assigns.current_customer

    attrs = %{
      customer_id: customer.id,
      year: parse_int(params["year"]),
      make: params["make"],
      model: params["model"],
      color: params["color"],
      license_plate: params["license_plate"],
      nickname: params["nickname"]
    }

    if params["skip_save"] == "true" do
      # One-off vehicle: borrowed friend's car, rental, etc. We
      # don't persist a Vehicle row; the appointment carries the
      # snapshot description only.
      label = Vehicle.display_label(attrs)

      socket
      |> put_data(:vehicle_id, nil)
      |> put_data(:vehicle_description, label)
      |> assign(:errors, %{})
      |> advance_to(:address)
      |> noreply()
    else
      case Vehicle
           |> Ash.Changeset.for_create(:add, attrs, tenant: tenant.id)
           |> Ash.create(authorize?: false) do
        {:ok, v} ->
          socket
          |> assign(:saved_vehicles, [v | socket.assigns.saved_vehicles])
          |> put_data(:vehicle_id, v.id)
          |> put_data(:vehicle_description, Vehicle.display_label(v))
          |> assign(:errors, %{})
          |> advance_to(:address)
          |> noreply()

        {:error, %Ash.Error.Invalid{} = e} ->
          {:noreply, assign(socket, :errors, ash_errors_to_map(e))}

        _ ->
          {:noreply, assign(socket, :errors, %{base: "Couldn't save vehicle."})}
      end
    end
  end

  def handle_event(
        "submit_vehicle_freetext",
        %{"booking" => %{"vehicle_description" => desc}},
        socket
      ) do
    case String.trim(desc || "") do
      "" ->
        {:noreply, assign(socket, :errors, %{vehicle_description: "Describe your vehicle"})}

      trimmed ->
        socket
        |> put_data(:vehicle_id, nil)
        |> put_data(:vehicle_description, trimmed)
        |> assign(:errors, %{})
        |> advance_to(:address)
        |> noreply()
    end
  end

  # Multi-car households: add a free-text "second vehicle" inline
  # without touching saved-vehicle state. Capped at 4 extras so the
  # UI doesn't degrade and a typo doesn't run away.
  def handle_event("add_additional_vehicle", %{"additional" => %{"description" => desc}}, socket) do
    case String.trim(desc || "") do
      "" ->
        {:noreply, assign(socket, :errors, %{additional_vehicle: "Describe the extra vehicle"})}

      trimmed ->
        existing = socket.assigns.wizard_data["additional_vehicles"] || []

        if length(existing) >= 4 do
          {:noreply, assign(socket, :errors, %{additional_vehicle: "Maximum 4 extra vehicles"})}
        else
          # Customer wizard only sets descriptions; the :book action
          # fills in `price_cents = service.base_price` per entry.
          new_entry = %{"description" => trimmed}

          socket
          |> put_data(:additional_vehicles, existing ++ [new_entry])
          |> assign(:errors, %{})
          |> noreply()
        end
    end
  end

  def handle_event("remove_additional_vehicle", %{"index" => index}, socket) do
    case Integer.parse(to_string(index)) do
      {i, ""} when i >= 0 ->
        existing = socket.assigns.wizard_data["additional_vehicles"] || []

        socket
        |> put_data(:additional_vehicles, List.delete_at(existing, i))
        |> noreply()

      _ ->
        {:noreply, socket}
    end
  end

  # --- Step 3: address ---

  def handle_event("set_address_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :address_mode, String.to_existing_atom(mode))}
  end

  def handle_event("submit_address_picked", %{"booking" => %{"address_id" => id}}, socket) do
    case Enum.find(socket.assigns.saved_addresses, &(&1.id == id)) do
      nil ->
        {:noreply, assign(socket, :errors, %{address_id: "Pick an address"})}

      a ->
        socket
        |> put_data(:address_id, a.id)
        |> put_data(:service_address, Address.display_label(a))
        |> assign(:errors, %{})
        |> advance_to(after_address_step(socket))
        |> noreply()
    end
  end

  def handle_event("submit_address_new", %{"address" => params}, socket) do
    tenant = socket.assigns.current_tenant
    customer = socket.assigns.current_customer

    attrs = %{
      customer_id: customer.id,
      street_line1: params["street_line1"],
      street_line2: params["street_line2"],
      city: params["city"],
      state: params["state"],
      zip: params["zip"],
      nickname: params["nickname"],
      instructions: params["instructions"]
    }

    if params["skip_save"] == "true" do
      # One-off address: house-sitting, vacation rental, etc.
      # Snapshot the label without persisting an Address row.
      label = Address.display_label(attrs)

      socket
      |> put_data(:address_id, nil)
      |> put_data(:service_address, label)
      |> assign(:errors, %{})
      |> advance_to(after_address_step(socket))
      |> noreply()
    else
      case Address
           |> Ash.Changeset.for_create(:add, attrs, tenant: tenant.id)
           |> Ash.create(authorize?: false) do
        {:ok, a} ->
          socket
          |> assign(:saved_addresses, [a | socket.assigns.saved_addresses])
          |> put_data(:address_id, a.id)
          |> put_data(:service_address, Address.display_label(a))
          |> assign(:errors, %{})
          |> advance_to(after_address_step(socket))
          |> noreply()

        {:error, %Ash.Error.Invalid{} = e} ->
          {:noreply, assign(socket, :errors, ash_errors_to_map(e))}

        _ ->
          {:noreply, assign(socket, :errors, %{base: "Couldn't save address."})}
      end
    end
  end

  def handle_event(
        "submit_address_freetext",
        %{"booking" => %{"service_address" => addr}},
        socket
      ) do
    case String.trim(addr || "") do
      "" ->
        {:noreply, assign(socket, :errors, %{service_address: "Enter a service address"})}

      trimmed ->
        socket
        |> put_data(:address_id, nil)
        |> put_data(:service_address, trimmed)
        |> assign(:errors, %{})
        |> advance_to(after_address_step(socket))
        |> noreply()
    end
  end

  # --- Step 3.5: photos (Pro+ only) ---

  def handle_event("validate_photos", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_photo_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photos, ref)}
  end

  def handle_event("submit_photos", _params, socket) do
    # Photos stay in the upload struct until the schedule step
    # creates the appointment; only then do we commit them to disk
    # and write Photo rows. "Skip" just advances.
    {:noreply, advance_to(socket, :schedule)}
  end

  # --- Step 4: schedule + final submit ---

  def handle_event("submit", %{"booking" => params}, socket) do
    tenant = socket.assigns.current_tenant
    customer = socket.assigns.current_customer
    slots = socket.assigns[:slots] || []
    data = socket.assigns.wizard_data

    with {:ok, service} <- fetch_service(data["service_type_id"], tenant.id),
         {:ok, scheduled_at} <- resolve_scheduled_at(params, slots),
         merged <- merge_schedule_step(data, params),
         {:ok, appt} <-
           create_appointment(tenant, customer, service, scheduled_at, merged) do
      socket = consume_booking_photos(socket, tenant, customer, appt)
      clear_draft(socket)
      AppointmentBroadcaster.broadcast(tenant.id, :booked, %{id: appt.id})
      handle_post_booking(socket, tenant, customer, service, appt)
    else
      {:error, :missing_service} ->
        {:noreply,
         socket
         |> assign(:errors, %{service_type_id: "Pick a service"})
         |> advance_to(:service)}

      {:error, :bad_datetime} ->
        {:noreply, assign(socket, :errors, %{scheduled_at: "Pick a valid future date and time"})}

      {:error, %Ash.Error.Invalid{} = e} ->
        {:noreply, assign(socket, :errors, ash_errors_to_map(e))}

      _ ->
        {:noreply, assign(socket, :errors, %{base: "Could not book this appointment."})}
    end
  end

  # --- Navigation ---

  def handle_event("start_over", _, socket) do
    clear_draft(socket)

    {:noreply,
     socket
     |> assign(:wizard_step, :service)
     |> assign(:wizard_data, blank_data())
     |> assign(:errors, %{})}
  end

  def handle_event("back", _, socket) do
    case prev_step(socket.assigns.wizard_step, socket) do
      nil -> {:noreply, socket}
      step -> {:noreply, assign(socket, :wizard_step, step)}
    end
  end

  # --- Step state helpers ---

  defp after_service_step(socket) do
    if socket.assigns[:current_customer], do: :vehicle, else: :account
  end

  defp after_address_step(socket) do
    if Plans.tenant_can?(socket.assigns.current_tenant, :booking_photos),
      do: :photos,
      else: :schedule
  end

  defp advance_to(socket, step) do
    socket = assign(socket, :wizard_step, step)
    save_draft(socket)
    socket
  end

  defp put_data(socket, key, value) do
    new = Map.put(socket.assigns.wizard_data, to_string(key), value)
    assign(socket, :wizard_data, new)
  end

  defp blank_data do
    %{
      "service_type_id" => "",
      "vehicle_id" => nil,
      "vehicle_description" => "",
      "address_id" => nil,
      "service_address" => "",
      "additional_vehicles" => [],
      "notes" => "",
      "acquisition_channel" => "",
      "is_loyalty_redemption" => false
    }
  end

  # --- Draft persistence (signed-in customers only) ---

  # Returns {step, data} when the customer's referenced appointment
  # is fetchable + ownership-checked; falls back to the normal draft
  # restore path otherwise.
  defp prefill_from_appointment(_tenant_id, nil, _from), do: {:service, blank_data()}

  defp prefill_from_appointment(_tenant_id, %{guest?: true}, _from),
    do: {:service, blank_data()}

  defp prefill_from_appointment(tenant_id, customer, from) do
    case Ash.get(Appointment, from, tenant: tenant_id, authorize?: false) do
      {:ok, %{customer_id: cid} = appt} when cid == customer.id ->
        data =
          blank_data()
          |> Map.merge(%{
            "service_type_id" => appt.service_type_id,
            "vehicle_id" => appt.vehicle_id,
            "vehicle_description" => appt.vehicle_description,
            "address_id" => appt.address_id,
            "service_address" => appt.service_address
          })

        {:vehicle, data}

      _ ->
        restore_draft(tenant_id, customer)
    end
  end

  defp restore_draft(_tenant_id, nil), do: {:service, blank_data()}

  defp restore_draft(_tenant_id, %{guest?: true}), do: {:service, blank_data()}

  defp restore_draft(tenant_id, %{id: customer_id}) do
    case BookingDraft
         |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
         |> Ash.Query.set_tenant(tenant_id)
         |> Ash.read(authorize?: false) do
      {:ok, [%BookingDraft{step: step, data: data}]} ->
        {parse_step(step), Map.merge(blank_data(), data || %{})}

      _ ->
        {:service, blank_data()}
    end
  rescue
    _ -> {:service, blank_data()}
  end

  defp parse_step(step) when is_binary(step) do
    case step do
      "service" -> :service
      "account" -> :account
      "vehicle" -> :vehicle
      "address" -> :address
      "photos" -> :photos
      "schedule" -> :schedule
      _ -> :service
    end
  end

  defp parse_step(_), do: :service

  defp save_draft(%{assigns: %{current_customer: %{guest?: true}}}), do: :ok
  defp save_draft(%{assigns: %{current_customer: nil}}), do: :ok
  defp save_draft(%{assigns: %{current_customer: customer}} = socket) do
    BookingDraft
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        customer_id: customer.id,
        step: Atom.to_string(socket.assigns.wizard_step),
        data: socket.assigns.wizard_data
      },
      tenant: socket.assigns.current_tenant.id
    )
    |> Ash.create(authorize?: false)

    :ok
  rescue
    _ -> :ok
  end

  defp save_draft(_), do: :ok

  defp clear_draft(%{assigns: %{current_customer: %{guest?: true}}}), do: :ok
  defp clear_draft(%{assigns: %{current_customer: nil}}), do: :ok
  defp clear_draft(%{assigns: %{current_customer: customer}} = socket) do
    case BookingDraft
         |> Ash.Query.for_read(:for_customer, %{customer_id: customer.id})
         |> Ash.Query.set_tenant(socket.assigns.current_tenant.id)
         |> Ash.read(authorize?: false) do
      {:ok, [draft]} ->
        Ash.destroy(draft, authorize?: false, tenant: socket.assigns.current_tenant.id)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp clear_draft(_), do: :ok

  # Going back skips :account when the customer was already signed
  # in at mount (step never appeared in their timeline). Anonymous
  # customers — including ones who signed in mid-wizard — bounce
  # vehicle ↔ account so they can re-pick their account mode.
  defp prev_step(:account, _), do: :service

  defp prev_step(:vehicle, %{assigns: %{current_customer: %{guest?: true}}}),
    do: :account

  defp prev_step(:vehicle, _), do: :service
  defp prev_step(:address, _), do: :vehicle
  defp prev_step(:photos, _), do: :address

  defp prev_step(:schedule, socket) do
    if Plans.tenant_can?(socket.assigns.current_tenant, :booking_photos),
      do: :photos,
      else: :address
  end

  defp prev_step(_, _), do: nil

  defp initial_mode([]), do: :new
  defp initial_mode(_), do: :pick

  defp merge_schedule_step(data, params) do
    Map.merge(data, %{
      "notes" => params["notes"] || data["notes"] || "",
      "acquisition_channel" =>
        params["acquisition_channel"] || data["acquisition_channel"] || "",
      "is_loyalty_redemption" => params["is_loyalty_redemption"] in ["true", "on", true]
    })
  end

  # Loyalty redemption is offered when:
  #   * The tenant has loyalty configured (threshold non-nil)
  #   * The customer is signed in (so we can identify their punch
  #     count) and not a guest.
  #   * The customer's loyalty_count >= threshold.
  defp loyalty_can_redeem?(_tenant, nil), do: false

  defp loyalty_can_redeem?(_tenant, %{guest?: true}), do: false

  defp loyalty_can_redeem?(%{loyalty_threshold: threshold}, %{loyalty_count: count})
       when is_integer(threshold) and is_integer(count),
       do: count >= threshold

  defp loyalty_can_redeem?(_, _), do: false

  # Fixed list for the V1 wizard. Values are stored as the literal
  # string in `Appointment.acquisition_channel` so simple aggregate
  # queries on the operator side work without a join.
  @acquisition_channels [
    "Friend / family",
    "Google",
    "Instagram / Facebook",
    "Drove by",
    "Returning customer",
    "Other"
  ]

  defp acquisition_channels, do: @acquisition_channels

  defp presence(""), do: nil
  defp presence(nil), do: nil
  defp presence(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end
  defp presence(other), do: other

  defp noreply(socket), do: {:noreply, socket}

  # --- Loaders ---

  defp load_services(tenant_id) do
    ServiceType
    |> Ash.Query.for_read(:active)
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp load_saved_vehicles(customer_id, tenant_id) do
    Vehicle
    |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp load_saved_addresses(customer_id, tenant_id) do
    Address
    |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_service("", _), do: {:error, :missing_service}
  defp fetch_service(nil, _), do: {:error, :missing_service}

  defp fetch_service(id, tenant_id) do
    case Ash.get(ServiceType, id, tenant: tenant_id, authorize?: false) do
      {:ok, svc} -> {:ok, svc}
      _ -> {:error, :missing_service}
    end
  end

  defp resolve_scheduled_at(%{"slot_id" => slot_id}, slots)
       when is_binary(slot_id) and slot_id != "" do
    case Enum.find(slots, &(&1.block_template_id == slot_id_template(slot_id))) do
      nil -> {:error, :bad_datetime}
      slot -> {:ok, slot.scheduled_at}
    end
  end

  defp resolve_scheduled_at(%{"scheduled_at" => v}, _slots), do: parse_scheduled_at(v)
  defp resolve_scheduled_at(_, _), do: {:error, :bad_datetime}

  defp slot_id_template(slot_id) do
    case String.split(slot_id, "|", parts: 2) do
      [template_id | _] -> template_id
      _ -> nil
    end
  end

  defp parse_scheduled_at(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601("#{value}:00Z") do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :bad_datetime}
    end
  end

  defp parse_scheduled_at(_), do: {:error, :bad_datetime}

  defp create_appointment(tenant, customer, service, scheduled_at, data) do
    redemption = data["is_loyalty_redemption"] == true

    price = if redemption, do: 0, else: service.base_price_cents

    result =
      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: customer.id,
          service_type_id: service.id,
          scheduled_at: scheduled_at,
          duration_minutes: service.duration_minutes,
          price_cents: price,
          vehicle_id: data["vehicle_id"],
          vehicle_description: data["vehicle_description"] |> to_string() |> String.trim(),
          additional_vehicles: data["additional_vehicles"] || [],
          address_id: data["address_id"],
          service_address: data["service_address"] |> to_string() |> String.trim(),
          notes: data["notes"],
          acquisition_channel: data["acquisition_channel"] |> presence(),
          is_loyalty_redemption: redemption
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    # Reset loyalty_count immediately on successful redemption so a
    # double-submit can't claim two free washes from one credit.
    if redemption and match?({:ok, _}, result) do
      customer
      |> Ash.Changeset.for_update(:reset_loyalty, %{})
      |> Ash.update(authorize?: false, tenant: tenant.id)
    end

    result
  end

  defp handle_post_booking(socket, tenant, customer, service, appt) do
    # Operators want to know about new bookings regardless of which
    # post-booking branch the customer takes. Fire the alert before
    # we even hit Stripe so a Stripe outage doesn't suppress the
    # notification.
    notify_admins_of_new_booking(tenant, customer, appt, service)

    cond do
      socket.assigns[:acting_admin] ->
        # Admin walk-in path: customer pays in person / on file. Skip
        # Stripe checkout, send the customer their confirmation, and
        # land the admin back on the customer detail page.
        send_confirmation_email(tenant, customer, appt, service)
        {:noreply, push_navigate(socket, to: ~p"/admin/customers/#{customer.id}")}

      true ->
        do_post_booking(socket, tenant, customer, service, appt)
    end
  end

  defp do_post_booking(socket, tenant, customer, service, appt) do
    if tenant.stripe_account_id do
      params = checkout_params(tenant, customer, service, appt)

      case StripeClient.create_checkout_session(tenant.stripe_account_id, params) do
        {:ok, %{id: session_id, url: url}} ->
          appt
          |> Ash.Changeset.for_update(:attach_stripe_session, %{
            stripe_checkout_session_id: session_id,
            payment_status: :pending
          })
          |> Ash.update!(authorize?: false, tenant: tenant.id)

          {:noreply, redirect(socket, external: url)}

        {:error, _reason} ->
          {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
      end
    else
      send_confirmation_email(tenant, customer, appt, service)
      {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
    end
  end

  defp send_confirmation_email(tenant, customer, appt, service) do
    tenant
    |> BookingEmail.confirmation(customer, appt, service)
    |> Mailer.deliver(Mailer.for_tenant(tenant))

    maybe_send_confirmation_sms(tenant, customer, appt, service)
  rescue
    _ -> :error
  end

  # SMS is gated on the tenant's plan AND the customer having a
  # phone number. BookingSms.confirmation/4 itself short-circuits
  # via {:error, :no_phone} / {:error, :no_from_number} so we
  # don't need to re-check those here.
  defp maybe_send_confirmation_sms(tenant, customer, appt, service) do
    if Plans.tenant_can?(tenant, :sms_notifications) do
      BookingSms.confirmation(tenant, customer, appt, service)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp notify_admins_of_new_booking(tenant, customer, appt, service) do
    for admin <- DrivewayOS.Accounts.tenant_admins(tenant.id) do
      tenant
      |> BookingEmail.new_booking_alert(admin, customer, appt, service)
      |> Mailer.deliver(Mailer.for_tenant(tenant))
    end
  rescue
    _ -> :error
  end

  defp checkout_params(tenant, customer, service, appt) do
    base_url = tenant_base_url(tenant)
    fee = div(service.base_price_cents * @application_fee_bps, 10_000)

    %{
      mode: "payment",
      success_url: "#{base_url}/book/success/#{appt.id}?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "#{base_url}/book",
      customer_email: to_string(customer.email),
      application_fee_amount: fee,
      line_items: [
        %{
          quantity: 1,
          price_data: %{
            currency: "usd",
            unit_amount: service.base_price_cents,
            product_data: %{
              name: service.name,
              description: "#{tenant.display_name} · #{service.duration_minutes} min"
            }
          }
        }
      ],
      metadata: %{
        appointment_id: appt.id,
        tenant_id: tenant.id,
        customer_id: customer.id
      }
    }
  end

  defp tenant_base_url(tenant) do
    host = Application.fetch_env!(:driveway_os, :platform_host)
    http_opts = Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)[:http] || []
    port = Keyword.get(http_opts, :port)

    {scheme, port_suffix} =
      cond do
        host == "lvh.me" -> {"http", ":#{port || 4000}"}
        port in [nil, 80, 443] -> {"https", ""}
        true -> {"https", ":#{port}"}
      end

    "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}"
  end

  defp ash_errors_to_map(%Ash.Error.Invalid{errors: errors}) do
    Enum.reduce(errors, %{}, fn err, acc ->
      field = Map.get(err, :field) || :base
      message = Map.get(err, :message) || inspect(err)
      Map.put(acc, field, message)
    end)
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end
  defp parse_int(n) when is_integer(n), do: n

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp error_to_string(:too_large), do: "That file is too big — keep it under 10 MB."
  defp error_to_string(:too_many_files), do: "You can attach at most 5 photos."
  defp error_to_string(:not_accepted), do: "We can only accept image files (JPG, PNG, HEIC, WebP)."
  defp error_to_string(other), do: "Upload failed: #{inspect(other)}"

  # Steps the user actually sees in the progress bar. Anonymous
  # users with guest_checkout get :account inserted between :service
  # and :vehicle. Pro+ tenants get :photos between :address and
  # :schedule.
  defp visible_steps(assigns) do
    base =
      if assigns[:current_customer],
        do: [:service, :vehicle, :address, :schedule],
        else: [:service, :account, :vehicle, :address, :schedule]

    if Plans.tenant_can?(assigns[:current_tenant], :booking_photos) do
      List.insert_at(base, -2, :photos)
    else
      base
    end
  end

  # Consume any uploaded photo entries — copy them into permanent
  # storage and write Photo rows tying them to the appointment.
  # Silent best-effort: a failed upload doesn't block the booking
  # since the customer's already past the point of no return.
  defp consume_booking_photos(socket, tenant, customer, appt) do
    if Plans.tenant_can?(tenant, :booking_photos) and
         Map.has_key?(socket.assigns[:uploads] || %{}, :photos) do
      consume_uploaded_entries(socket, :photos, fn %{path: temp_path}, entry ->
        with {:ok, meta} <- Uploads.store_entry(tenant.id, appt.id, entry, temp_path),
             {:ok, _photo} <-
               Photo
               |> Ash.Changeset.for_create(
                 :attach,
                 %{
                   customer_id: customer.id,
                   appointment_id: appt.id,
                   kind: :pre_booking,
                   storage_path: meta.path,
                   content_type: meta.content_type,
                   byte_size: meta.byte_size
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false) do
          {:ok, meta.path}
        else
          _ -> {:postpone, :error}
        end
      end)

      socket
    else
      socket
    end
  rescue
    _ -> socket
  end

  defp service_for(socket) do
    case socket.assigns.wizard_data["service_type_id"] do
      "" -> nil
      id -> Enum.find(socket.assigns.services, &(&1.id == id))
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header>
          <a
            href="/"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
          </a>
          <div class="flex items-center justify-between gap-3 mt-2">
            <h1 class="text-3xl font-bold tracking-tight">Book a wash</h1>
            <button
              :if={@current_customer && @wizard_step != :service}
              type="button"
              phx-click="start_over"
              data-confirm="Discard this draft and start over?"
              class="btn btn-ghost btn-sm"
            >
              Start over
            </button>
          </div>
          <p :if={@current_customer && is_nil(@acting_admin)} class="text-sm text-base-content/70 mt-1">
            Welcome back, {@current_customer.name}.
          </p>
          <p :if={is_nil(@current_customer)} class="text-sm text-base-content/70 mt-1">
            No account needed — we'll email your confirmation.
          </p>
          <%!-- Admin walk-in banner — visually distinct from the
               normal welcome line so the operator can't accidentally
               book under their own account. --%>
          <div
            :if={@acting_admin}
            role="alert"
            class="mt-3 alert alert-warning text-sm"
          >
            <span class="hero-user-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
            <div>
              <div class="font-semibold">
                Booking on behalf of {@current_customer.name}
              </div>
              <div class="text-xs opacity-80">
                {to_string(@current_customer.email)} · payment will not be collected here.
              </div>
            </div>
          </div>
        </header>

        <%!-- Progress indicator. The :account step only appears in
             the timeline when the customer isn't signed in yet
             AND the tenant has guest_checkout enabled. --%>
        <ol class="flex gap-2 text-xs font-semibold uppercase tracking-wide">
          <li
            :for={{step, idx} <- Enum.with_index(visible_steps(assigns))}
            class={
              "flex-1 py-2 px-3 rounded-md border " <>
                cond do
                  step == @wizard_step ->
                    "border-primary bg-primary/10 text-primary"
                  idx < (visible_steps(assigns) |> Enum.find_index(&(&1 == @wizard_step)) || 0) ->
                    "border-success/30 bg-success/10 text-success"
                  true ->
                    "border-base-300 text-base-content/40"
                end
            }
          >
            {idx + 1}. {step}
          </li>
        </ol>

        <div :if={@errors[:base]} role="alert" class="alert alert-error">
          <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@errors[:base]}</span>
        </div>

        {render_step(assigns)}
      </div>
    </main>
    """
  end

  defp render_step(%{wizard_step: :service} = assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-6 space-y-4">
        <h2 class="card-title text-lg">Pick a service</h2>

        <%!-- Service descriptions inline so customers can compare
             before opening the dropdown. Hidden when no service has
             a description so the layout doesn't get a blank panel. --%>
        <ul
          :if={Enum.any?(@services, &(&1.description && &1.description != ""))}
          class="space-y-2 text-sm"
        >
          <li :for={svc <- @services} class="border border-base-200 rounded-md px-3 py-2">
            <div class="flex items-baseline justify-between gap-2 flex-wrap">
              <span class="font-semibold">{svc.name}</span>
              <span class="text-base-content/70">
                {fmt_price(svc.base_price_cents)} · {svc.duration_minutes} min
              </span>
            </div>
            <p :if={svc.description && svc.description != ""} class="text-base-content/70 mt-1">
              {svc.description}
            </p>
          </li>
        </ul>

        <form id="step-service-form" phx-submit="submit_service" class="space-y-4">
          <div>
            <label class="label" for="svc">
              <span class="label-text font-medium">Service</span>
            </label>
            <select
              id="svc"
              name="booking[service_type_id]"
              class="select select-bordered w-full"
              required
            >
              <option value="">— Pick a service —</option>
              <option
                :for={svc <- @services}
                value={svc.id}
                selected={@wizard_data["service_type_id"] == svc.id}
              >
                {svc.name} — {fmt_price(svc.base_price_cents)} ({svc.duration_minutes} min)
              </option>
            </select>
            <p :if={@errors[:service_type_id]} class="text-error text-xs mt-1">
              {@errors[:service_type_id]}
            </p>
          </div>

          <div class="flex justify-end">
            <button type="submit" class="btn btn-primary gap-2">
              Next
              <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
            </button>
          </div>
        </form>
      </div>
    </section>
    """
  end

  defp render_step(%{wizard_step: :account} = assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-6 space-y-4">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <h2 class="card-title text-lg">Your details</h2>

          <div class="join">
            <button
              type="button"
              phx-click="set_account_mode"
              phx-value-mode="guest"
              class={"btn btn-sm join-item " <> if @account_mode == :guest, do: "btn-primary", else: "btn-ghost"}
            >
              Guest
            </button>
            <button
              type="button"
              phx-click="set_account_mode"
              phx-value-mode="sign_in"
              class={"btn btn-sm join-item " <> if @account_mode == :sign_in, do: "btn-primary", else: "btn-ghost"}
            >
              Sign in
            </button>
            <button
              type="button"
              phx-click="set_account_mode"
              phx-value-mode="register"
              class={"btn btn-sm join-item " <> if @account_mode == :register, do: "btn-primary", else: "btn-ghost"}
            >
              Register
            </button>
          </div>
        </div>

        <p class="text-sm text-base-content/70">
          <span :if={@account_mode == :guest}>
            Just want to book once? Drop your name + email below — we'll send the confirmation there. You can claim a full account later.
          </span>
          <span :if={@account_mode == :sign_in}>
            Already have an account? Sign in to use your saved vehicles and addresses.
          </span>
          <span :if={@account_mode == :register}>
            Create an account so your vehicles + addresses save for next time.
          </span>
        </p>

        <%= cond do %>
          <% @account_mode == :guest -> %>
            {render_account_guest(assigns)}
          <% @account_mode == :sign_in -> %>
            {render_account_signin(assigns)}
          <% true -> %>
            {render_account_register(assigns)}
        <% end %>
      </div>
    </section>
    """
  end

  defp render_step(%{wizard_step: :vehicle} = assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-6 space-y-4">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <h2 class="card-title text-lg">Vehicle</h2>

          <%!-- Mode toggle: Pro+ tenants with saved vehicles see this --%>
          <div
            :if={
              Plans.tenant_can?(@current_tenant, :saved_vehicles) and @saved_vehicles != []
            }
            class="join"
          >
            <button
              type="button"
              phx-click="set_vehicle_mode"
              phx-value-mode="pick"
              class={"btn btn-sm join-item " <> if @vehicle_mode == :pick, do: "btn-primary", else: "btn-ghost"}
            >
              Saved
            </button>
            <button
              type="button"
              phx-click="set_vehicle_mode"
              phx-value-mode="new"
              class={"btn btn-sm join-item " <> if @vehicle_mode == :new, do: "btn-primary", else: "btn-ghost"}
            >
              Add new
            </button>
          </div>
        </div>

        <%= cond do %>
          <% Plans.tenant_can?(@current_tenant, :saved_vehicles) and @vehicle_mode == :pick and @saved_vehicles != [] -> %>
            {render_vehicle_picker(assigns)}
          <% Plans.tenant_can?(@current_tenant, :saved_vehicles) -> %>
            {render_vehicle_new(assigns)}
          <% true -> %>
            {render_vehicle_freetext(assigns)}
        <% end %>

        <%!-- Multi-vehicle: tack on additional cars for the same
             visit. Existing additions render as removable chips;
             a small inline form adds one more. Pricing on the
             schedule step is base × (1 + count). --%>
        <% additional = @wizard_data["additional_vehicles"] || [] %>
        <div :if={additional != []} class="border-t border-base-200 pt-3 space-y-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Also doing today
          </p>
          <ul class="flex flex-wrap gap-2">
            <li
              :for={{entry, idx} <- Enum.with_index(additional)}
              class="badge badge-lg gap-2 bg-base-200 border-base-300"
            >
              {entry["description"]}
              <button
                type="button"
                phx-click="remove_additional_vehicle"
                phx-value-index={idx}
                class="text-base-content/60 hover:text-error"
                aria-label={"Remove " <> entry["description"]}
              >
                <span class="hero-x-mark w-3 h-3" aria-hidden="true"></span>
              </button>
            </li>
          </ul>
        </div>

        <form
          id="add-additional-vehicle-form"
          phx-submit="add_additional_vehicle"
          class="border-t border-base-200 pt-3 flex items-end gap-2 flex-wrap"
        >
          <div class="flex-1 min-w-[200px]">
            <label class="label" for="add-additional-vehicle-input">
              <span class="label-text font-medium text-sm">
                Add another vehicle?
              </span>
              <span class="label-text-alt text-base-content/50">Optional</span>
            </label>
            <input
              id="add-additional-vehicle-input"
              type="text"
              name="additional[description]"
              placeholder="Red 2018 Honda Pilot"
              class="input input-bordered input-sm w-full"
            />
            <p :if={@errors[:additional_vehicle]} class="text-xs text-error mt-1">
              {@errors[:additional_vehicle]}
            </p>
          </div>
          <button type="submit" class="btn btn-ghost btn-sm gap-1">
            <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Add
          </button>
        </form>
      </div>
    </section>
    """
  end

  defp render_step(%{wizard_step: :address} = assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-6 space-y-4">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <h2 class="card-title text-lg">Service address</h2>

          <div
            :if={
              Plans.tenant_can?(@current_tenant, :saved_addresses) and @saved_addresses != []
            }
            class="join"
          >
            <button
              type="button"
              phx-click="set_address_mode"
              phx-value-mode="pick"
              class={"btn btn-sm join-item " <> if @address_mode == :pick, do: "btn-primary", else: "btn-ghost"}
            >
              Saved
            </button>
            <button
              type="button"
              phx-click="set_address_mode"
              phx-value-mode="new"
              class={"btn btn-sm join-item " <> if @address_mode == :new, do: "btn-primary", else: "btn-ghost"}
            >
              Add new
            </button>
          </div>
        </div>

        <%= cond do %>
          <% Plans.tenant_can?(@current_tenant, :saved_addresses) and @address_mode == :pick and @saved_addresses != [] -> %>
            {render_address_picker(assigns)}
          <% Plans.tenant_can?(@current_tenant, :saved_addresses) -> %>
            {render_address_new(assigns)}
          <% true -> %>
            {render_address_freetext(assigns)}
        <% end %>
      </div>
    </section>
    """
  end

  defp render_step(%{wizard_step: :photos} = assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-6">
        <h2 class="card-title text-base">Add photos (optional)</h2>
        <p class="text-sm text-base-content/70 mb-3">
          Up to 5 photos so we can size the job before we arrive.
        </p>

        <form
          id="booking-photos-form"
          phx-submit="submit_photos"
          phx-change="validate_photos"
          class="space-y-4"
        >
          <div
            class="border border-dashed border-base-300 rounded-lg p-4 text-center"
            phx-drop-target={@uploads.photos.ref}
          >
            <.live_file_input upload={@uploads.photos} class="file-input file-input-bordered w-full" />
            <p class="text-xs text-base-content/60 mt-2">
              JPG, PNG, HEIC, or WebP — up to 10 MB each.
            </p>
          </div>

          <div :if={@uploads.photos.entries != []} class="space-y-2">
            <div
              :for={entry <- @uploads.photos.entries}
              class="flex items-center justify-between text-sm border border-base-300 rounded-md px-3 py-2"
            >
              <span class="truncate">{entry.client_name}</span>
              <div class="flex items-center gap-2">
                <span class="text-base-content/60">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_photo_upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-xs"
                  aria-label="Remove photo"
                >
                  <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span>
                </button>
              </div>
            </div>
          </div>

          <div
            :for={err <- upload_errors(@uploads.photos)}
            role="alert"
            class="alert alert-error text-sm"
          >
            {error_to_string(err)}
          </div>

          <div class="flex justify-between gap-2 pt-2">
            <button type="button" phx-click="back" class="btn btn-ghost">Back</button>
            <button type="submit" class="btn btn-primary">
              {if @uploads.photos.entries == [], do: "Skip photos", else: "Continue"}
            </button>
          </div>
        </form>
      </div>
    </section>
    """
  end

  defp render_step(%{wizard_step: :schedule} = assigns) do
    assigns = assign(assigns, :selected_service, service_for(%{assigns: assigns}))

    ~H"""
    <section class="card bg-base-100 shadow-sm border border-base-300">
      <div class="card-body p-6 space-y-4">
        <h2 class="card-title text-lg">When + final review</h2>

        <% additional = @wizard_data["additional_vehicles"] || [] %>
        <% vehicle_count = 1 + length(additional) %>
        <% total_cents = if @selected_service, do: @selected_service.base_price_cents * vehicle_count, else: 0 %>

        <%!-- Inline review of selections from prior steps --%>
        <dl class="grid grid-cols-3 gap-x-3 gap-y-2 text-sm">
          <dt class="text-base-content/60">Service</dt>
          <dd class="col-span-2">
            <span :if={@selected_service}>
              {@selected_service.name} — {fmt_price(@selected_service.base_price_cents)}{if vehicle_count > 1, do: " each"}
            </span>
          </dd>

          <dt class="text-base-content/60">
            {if additional != [], do: "Vehicles", else: "Vehicle"}
          </dt>
          <dd class="col-span-2">
            <div>{@wizard_data["vehicle_description"]}</div>
            <div :for={v <- additional} class="text-base-content/80">+ {v["description"]}</div>
          </dd>

          <dt class="text-base-content/60">Address</dt>
          <dd class="col-span-2">{@wizard_data["service_address"]}</dd>

          <dt :if={vehicle_count > 1} class="text-base-content/60 font-semibold">Total</dt>
          <dd :if={vehicle_count > 1} class="col-span-2 font-semibold">
            {fmt_price(total_cents)} ({vehicle_count} vehicles)
          </dd>
        </dl>

        <form id="booking-form" phx-submit="submit" class="space-y-4 pt-2 border-t border-base-200">
          <div :if={@slots != []}>
            <label class="label" for="booking-slot">
              <span class="label-text font-medium">Available slots</span>
            </label>
            <select
              id="booking-slot"
              name="booking[slot_id]"
              class="select select-bordered w-full"
              required
            >
              <option value="">— Pick a slot —</option>
              <option
                :for={slot <- @slots}
                value={"#{slot.block_template_id}|#{DateTime.to_iso8601(slot.scheduled_at)}"}
              >
                {slot.name} — {Calendar.strftime(slot.scheduled_at, "%a %b %-d, %-I:%M %p UTC")} ({slot.duration_minutes} min)
              </option>
            </select>
            <p :if={@errors[:scheduled_at]} class="text-error text-xs mt-1">
              {@errors[:scheduled_at]}
            </p>
          </div>

          <div :if={@slots == []}>
            <label class="label" for="booking-scheduled-at">
              <span class="label-text font-medium">Date & time</span>
            </label>
            <input
              id="booking-scheduled-at"
              type="datetime-local"
              name="booking[scheduled_at]"
              class="input input-bordered w-full"
              required
            />
            <p :if={@errors[:scheduled_at]} class="text-error text-xs mt-1">
              {@errors[:scheduled_at]}
            </p>
          </div>

          <div>
            <label class="label" for="booking-notes">
              <span class="label-text font-medium">Notes</span>
              <span class="label-text-alt text-base-content/50">Optional</span>
            </label>
            <textarea
              id="booking-notes"
              name="booking[notes]"
              rows="2"
              placeholder="Gate code, special requests, etc."
              class="textarea textarea-bordered w-full"
            >{@wizard_data["notes"]}</textarea>
          </div>

          <div
            :if={@loyalty_can_redeem?}
            class="alert bg-primary/10 border border-primary/30"
          >
            <span class="hero-gift w-5 h-5 text-primary shrink-0" aria-hidden="true"></span>
            <div class="flex-1">
              <label class="cursor-pointer flex items-start gap-3">
                <input
                  type="checkbox"
                  name="booking[is_loyalty_redemption]"
                  value="true"
                  class="checkbox checkbox-primary mt-1"
                />
                <div>
                  <span class="font-semibold">Use your free wash</span>
                  <p class="text-sm text-base-content/70 mt-0.5">
                    Apply your loyalty reward to this booking — total drops to $0.
                  </p>
                </div>
              </label>
            </div>
          </div>

          <div>
            <label class="label" for="booking-acquisition">
              <span class="label-text font-medium">How did you hear about us?</span>
              <span class="label-text-alt text-base-content/50">Optional</span>
            </label>
            <select
              id="booking-acquisition"
              name="booking[acquisition_channel]"
              class="select select-bordered w-full"
            >
              <option value="">— Skip —</option>
              <option
                :for={channel <- acquisition_channels()}
                value={channel}
                selected={@wizard_data["acquisition_channel"] == channel}
              >
                {channel}
              </option>
            </select>
          </div>

          <div class="flex justify-between pt-2">
            <button type="button" phx-click="back" class="btn btn-ghost gap-1">
              <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
            </button>
            <button type="submit" class="btn btn-primary btn-lg gap-2">
              <span class="hero-sparkles w-5 h-5" aria-hidden="true"></span> Book it
            </button>
          </div>

          <p class="text-xs text-base-content/60 text-center">
            <span :if={@current_tenant.stripe_account_id}>
              Pay securely on the next page.
            </span>
            <span :if={is_nil(@current_tenant.stripe_account_id)}>
              {@current_tenant.display_name} will confirm and reach out. Payment collected on-site.
            </span>
          </p>
        </form>
      </div>
    </section>
    """
  end

  # --- Vehicle sub-renderers ---

  defp render_vehicle_picker(assigns) do
    ~H"""
    <form id="step-vehicle-pick-form" phx-submit="submit_vehicle_picked" class="space-y-4">
      <div class="space-y-2">
        <label
          :for={v <- @saved_vehicles}
          class="flex items-center gap-3 p-3 rounded-lg border border-base-300 hover:bg-base-200/60 cursor-pointer"
        >
          <input
            type="radio"
            name="booking[vehicle_id]"
            value={v.id}
            class="radio radio-primary"
            checked={@wizard_data["vehicle_id"] == v.id}
          />
          <span class="font-medium">{Vehicle.display_label(v)}</span>
        </label>
        <p :if={@errors[:vehicle_id]} class="text-error text-xs mt-1">
          {@errors[:vehicle_id]}
        </p>
      </div>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Next <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  defp render_vehicle_new(assigns) do
    ~H"""
    <form id="step-vehicle-new-form" phx-submit="submit_vehicle_new" class="space-y-3">
      <div class="grid grid-cols-2 gap-3">
        <div>
          <label class="label py-1" for="v-year">
            <span class="label-text font-medium">Year</span>
          </label>
          <input
            id="v-year"
            type="number"
            name="vehicle[year]"
            min="1900"
            max="2100"
            placeholder="2022"
            class="input input-bordered w-full"
            required
          />
        </div>
        <div>
          <label class="label py-1" for="v-color">
            <span class="label-text font-medium">Color</span>
          </label>
          <input
            id="v-color"
            type="text"
            name="vehicle[color]"
            placeholder="Blue"
            class="input input-bordered w-full"
            required
          />
        </div>
      </div>
      <div class="grid grid-cols-2 gap-3">
        <div>
          <label class="label py-1" for="v-make">
            <span class="label-text font-medium">Make</span>
          </label>
          <input
            id="v-make"
            type="text"
            name="vehicle[make]"
            placeholder="Subaru"
            class="input input-bordered w-full"
            required
          />
        </div>
        <div>
          <label class="label py-1" for="v-model">
            <span class="label-text font-medium">Model</span>
          </label>
          <input
            id="v-model"
            type="text"
            name="vehicle[model]"
            placeholder="Outback"
            class="input input-bordered w-full"
            required
          />
        </div>
      </div>
      <div>
        <label class="label py-1" for="v-plate">
          <span class="label-text font-medium">License plate</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="v-plate"
          type="text"
          name="vehicle[license_plate]"
          class="input input-bordered w-full"
        />
      </div>
      <div>
        <label class="label py-1" for="v-nick">
          <span class="label-text font-medium">Nickname</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="v-nick"
          type="text"
          name="vehicle[nickname]"
          placeholder="Work truck"
          class="input input-bordered w-full"
        />
      </div>

      <p :if={@errors[:base]} class="text-error text-xs">{@errors[:base]}</p>

      <%!-- Default behavior is "save for next time" — Pro+ tenants
           lean on the saved-vehicles list to make repeat bookings
           one tap. Customers borrowing a friend's car / driving a
           rental can opt out for this booking only. --%>
      <label class="flex items-start gap-2 text-sm cursor-pointer">
        <input
          type="checkbox"
          name="vehicle[skip_save]"
          value="true"
          class="checkbox checkbox-sm mt-0.5"
        />
        <span class="text-base-content/80">
          Don't save this for next time
          <span class="block text-xs text-base-content/50">
            One-off vehicle (rental, friend's car). We'll only use it for this booking.
          </span>
        </span>
      </label>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Save & continue <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  defp render_vehicle_freetext(assigns) do
    ~H"""
    <form id="step-vehicle-text-form" phx-submit="submit_vehicle_freetext" class="space-y-3">
      <div>
        <label class="label" for="v-desc">
          <span class="label-text font-medium">Vehicle</span>
        </label>
        <input
          id="v-desc"
          type="text"
          name="booking[vehicle_description]"
          value={@wizard_data["vehicle_description"]}
          placeholder="Year + make + model + color"
          class="input input-bordered w-full"
          required
        />
        <p :if={@errors[:vehicle_description]} class="text-error text-xs mt-1">
          {@errors[:vehicle_description]}
        </p>
      </div>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Next <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  # --- Address sub-renderers ---

  defp render_address_picker(assigns) do
    ~H"""
    <form id="step-address-pick-form" phx-submit="submit_address_picked" class="space-y-4">
      <div class="space-y-2">
        <label
          :for={a <- @saved_addresses}
          class="flex items-center gap-3 p-3 rounded-lg border border-base-300 hover:bg-base-200/60 cursor-pointer"
        >
          <input
            type="radio"
            name="booking[address_id]"
            value={a.id}
            class="radio radio-primary"
            checked={@wizard_data["address_id"] == a.id}
          />
          <span class="font-medium">{Address.display_label(a)}</span>
        </label>
        <p :if={@errors[:address_id]} class="text-error text-xs mt-1">{@errors[:address_id]}</p>
      </div>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Next <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  defp render_address_new(assigns) do
    ~H"""
    <form id="step-address-new-form" phx-submit="submit_address_new" class="space-y-3">
      <div>
        <label class="label py-1" for="a-line1">
          <span class="label-text font-medium">Street address</span>
        </label>
        <input
          id="a-line1"
          type="text"
          name="address[street_line1]"
          placeholder="123 Cedar St"
          class="input input-bordered w-full"
          required
        />
      </div>
      <div>
        <label class="label py-1" for="a-line2">
          <span class="label-text font-medium">Apt / Suite</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="a-line2"
          type="text"
          name="address[street_line2]"
          class="input input-bordered w-full"
        />
      </div>
      <div class="grid grid-cols-3 gap-3">
        <div class="col-span-2">
          <label class="label py-1" for="a-city">
            <span class="label-text font-medium">City</span>
          </label>
          <input
            id="a-city"
            type="text"
            name="address[city]"
            placeholder="San Antonio"
            class="input input-bordered w-full"
            required
          />
        </div>
        <div>
          <label class="label py-1" for="a-state">
            <span class="label-text font-medium">State</span>
          </label>
          <input
            id="a-state"
            type="text"
            name="address[state]"
            maxlength="2"
            placeholder="TX"
            class="input input-bordered w-full"
            required
          />
        </div>
      </div>
      <div>
        <label class="label py-1" for="a-zip">
          <span class="label-text font-medium">ZIP</span>
        </label>
        <input
          id="a-zip"
          type="text"
          name="address[zip]"
          placeholder="78261"
          class="input input-bordered w-full"
          required
        />
      </div>
      <div>
        <label class="label py-1" for="a-instructions">
          <span class="label-text font-medium">Gate code / instructions</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="a-instructions"
          type="text"
          name="address[instructions]"
          class="input input-bordered w-full"
        />
      </div>
      <div>
        <label class="label py-1" for="a-nick">
          <span class="label-text font-medium">Nickname</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="a-nick"
          type="text"
          name="address[nickname]"
          placeholder="Home"
          class="input input-bordered w-full"
        />
      </div>

      <p :if={@errors[:base]} class="text-error text-xs">{@errors[:base]}</p>

      <%!-- Same pattern as the new-vehicle form: default is "save"
           so the saved-addresses list grows by repeat use; opt out
           for one-off jobs (vacation rental, house-sit, etc.). --%>
      <label class="flex items-start gap-2 text-sm cursor-pointer">
        <input
          type="checkbox"
          name="address[skip_save]"
          value="true"
          class="checkbox checkbox-sm mt-0.5"
        />
        <span class="text-base-content/80">
          Don't save this for next time
          <span class="block text-xs text-base-content/50">
            One-off address (vacation rental, house-sit). We'll only use it for this booking.
          </span>
        </span>
      </label>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Save & continue <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  # --- Account sub-renderers ---

  defp render_account_guest(assigns) do
    ~H"""
    <form id="step-account-guest-form" phx-submit="submit_account_guest" class="space-y-3">
      <div>
        <label class="label py-1" for="g-name">
          <span class="label-text font-medium">Your name</span>
        </label>
        <input
          id="g-name"
          type="text"
          name="guest[name]"
          autocomplete="name"
          class="input input-bordered w-full"
          required
        />
      </div>
      <div>
        <label class="label py-1" for="g-email">
          <span class="label-text font-medium">Email</span>
        </label>
        <input
          id="g-email"
          type="email"
          name="guest[email]"
          autocomplete="email"
          class="input input-bordered w-full"
          required
        />
      </div>
      <div>
        <label class="label py-1" for="g-phone">
          <span class="label-text font-medium">Phone</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="g-phone"
          type="tel"
          name="guest[phone]"
          autocomplete="tel"
          class="input input-bordered w-full"
        />
      </div>

      <p :if={@errors[:base]} class="text-error text-xs">{@errors[:base]}</p>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Continue as guest
          <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  defp render_account_signin(assigns) do
    ~H"""
    <form id="step-account-signin-form" phx-submit="submit_account_signin" class="space-y-3">
      <div>
        <label class="label py-1" for="si-email">
          <span class="label-text font-medium">Email</span>
        </label>
        <input
          id="si-email"
          type="email"
          name="signin[email]"
          autocomplete="email"
          class="input input-bordered w-full"
          required
        />
      </div>
      <div>
        <label class="label py-1" for="si-pw">
          <span class="label-text font-medium">Password</span>
        </label>
        <input
          id="si-pw"
          type="password"
          name="signin[password]"
          autocomplete="current-password"
          class="input input-bordered w-full"
          required
        />
      </div>

      <p :if={@errors[:base]} class="text-error text-xs">{@errors[:base]}</p>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Sign in & continue
          <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  defp render_account_register(assigns) do
    ~H"""
    <form id="step-account-register-form" phx-submit="submit_account_register" class="space-y-3">
      <div>
        <label class="label py-1" for="reg-name">
          <span class="label-text font-medium">Your name</span>
        </label>
        <input
          id="reg-name"
          type="text"
          name="register[name]"
          autocomplete="name"
          class="input input-bordered w-full"
          required
        />
      </div>
      <div>
        <label class="label py-1" for="reg-email">
          <span class="label-text font-medium">Email</span>
        </label>
        <input
          id="reg-email"
          type="email"
          name="register[email]"
          autocomplete="email"
          class="input input-bordered w-full"
          required
        />
      </div>
      <div>
        <label class="label py-1" for="reg-pw">
          <span class="label-text font-medium">Password</span>
        </label>
        <input
          id="reg-pw"
          type="password"
          name="register[password]"
          autocomplete="new-password"
          class="input input-bordered w-full"
          required
        />
        <p class="text-xs text-base-content/60 mt-1">
          10+ characters · at least one upper, one lower, one digit.
        </p>
      </div>

      <p :if={@errors[:base]} class="text-error text-xs">{@errors[:base]}</p>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Create account & continue
          <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

  defp render_address_freetext(assigns) do
    ~H"""
    <form id="step-address-text-form" phx-submit="submit_address_freetext" class="space-y-3">
      <div>
        <label class="label" for="a-desc">
          <span class="label-text font-medium">Service address</span>
        </label>
        <input
          id="a-desc"
          type="text"
          name="booking[service_address]"
          value={@wizard_data["service_address"]}
          placeholder="123 Main St, San Antonio TX 78261"
          class="input input-bordered w-full"
          required
        />
        <p :if={@errors[:service_address]} class="text-error text-xs mt-1">
          {@errors[:service_address]}
        </p>
      </div>

      <div class="flex justify-between">
        <button type="button" phx-click="back" class="btn btn-ghost gap-1">
          <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
        </button>
        <button type="submit" class="btn btn-primary gap-1">
          Next <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
        </button>
      </div>
    </form>
    """
  end

end
