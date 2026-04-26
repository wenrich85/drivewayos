defmodule DrivewayOSWeb.BookingLive do
  @moduledoc """
  Customer booking form. Lives at `{slug}.lvh.me/book`.

  Requires an authenticated Customer in the current tenant; bounces
  to `/sign-in` otherwise. Loads the tenant's active services + lets
  the customer pick one + a future scheduled_at + vehicle + address.
  Submits via `Appointment.book/1` and redirects to a confirmation
  page.

  V1 has no payment integration here — Stripe Connect lands in a
  follow-up slice. Customers leave the form with a pending
  appointment; admin confirms it manually until billing is wired up.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Billing.StripeClient
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  # Platform's cut on every booking, in basis points (e.g. 1000 =
  # 10%). Hardcoded for V1; per-tenant overrides land with
  # TenantSubscription.
  @application_fee_bps 1000

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        tenant_id = socket.assigns.current_tenant.id
        services = load_services(tenant_id)
        slots = DrivewayOS.Scheduling.upcoming_slots(tenant_id, 14)

        {:ok,
         socket
         |> assign(:page_title, "Book a wash")
         |> assign(:services, services)
         |> assign(:slots, slots)
         |> assign(:errors, %{})
         |> assign(:form, blank_form())}
    end
  end

  @impl true
  def handle_event("submit", %{"booking" => params}, socket) do
    tenant = socket.assigns.current_tenant
    customer = socket.assigns.current_customer
    slots = socket.assigns[:slots] || []

    with {:ok, service} <- fetch_service(params["service_type_id"], tenant.id),
         {:ok, scheduled_at} <- resolve_scheduled_at(params, slots),
         {:ok, appt} <-
           create_appointment(tenant, customer, service, scheduled_at, params) do
      handle_post_booking(socket, tenant, customer, service, appt)
    else
      {:error, :missing_service} ->
        {:noreply,
         socket
         |> assign(:errors, %{service_type_id: "Pick a service"})
         |> assign(:form, params)}

      {:error, :bad_datetime} ->
        {:noreply,
         socket
         |> assign(:errors, %{scheduled_at: "Pick a valid future date and time"})
         |> assign(:form, params)}

      {:error, %Ash.Error.Invalid{} = e} ->
        {:noreply,
         socket
         |> assign(:errors, ash_errors_to_map(e))
         |> assign(:form, params)}

      _ ->
        {:noreply,
         socket
         |> assign(:errors, %{base: "Could not book this appointment."})
         |> assign(:form, params)}
    end
  end

  # --- Private ---

  defp blank_form do
    %{
      "service_type_id" => "",
      "scheduled_at" => "",
      "vehicle_description" => "",
      "service_address" => "",
      "notes" => ""
    }
  end

  defp load_services(tenant_id) do
    ServiceType
    |> Ash.Query.for_read(:active)
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_service("", _tenant_id), do: {:error, :missing_service}
  defp fetch_service(nil, _tenant_id), do: {:error, :missing_service}

  defp fetch_service(id, tenant_id) do
    case Ash.get(ServiceType, id, tenant: tenant_id, authorize?: false) do
      {:ok, svc} -> {:ok, svc}
      _ -> {:error, :missing_service}
    end
  end

  # When templates exist, the form sends slot_id; resolve it to the
  # slot's scheduled_at. Otherwise fall back to free-text parsing.
  defp resolve_scheduled_at(%{"slot_id" => slot_id}, slots)
       when is_binary(slot_id) and slot_id != "" do
    case Enum.find(slots, &(&1.block_template_id == slot_id_template(slot_id))) do
      nil -> {:error, :bad_datetime}
      slot -> {:ok, slot.scheduled_at}
    end
  end

  defp resolve_scheduled_at(%{"scheduled_at" => v}, _slots), do: parse_scheduled_at(v)
  defp resolve_scheduled_at(_, _), do: {:error, :bad_datetime}

  # slot_id format: "<template_id>|<iso8601>" so a slot is uniquely
  # identified by template + date.
  defp slot_id_template(slot_id) do
    case String.split(slot_id, "|", parts: 2) do
      [template_id | _] -> template_id
      _ -> nil
    end
  end

  defp parse_scheduled_at(value) when is_binary(value) and value != "" do
    # HTML datetime-local inputs return "YYYY-MM-DDTHH:MM"; append
    # seconds + Z so we can parse as ISO8601 UTC. Treating the
    # browser's local-time-shaped string as UTC is fine for V1; V2
    # adds proper timezone handling once we have tenant timezone wired
    # to the form.
    case DateTime.from_iso8601("#{value}:00Z") do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, :bad_datetime}
    end
  end

  defp parse_scheduled_at(_), do: {:error, :bad_datetime}

  defp create_appointment(tenant, customer, service, scheduled_at, params) do
    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: customer.id,
        service_type_id: service.id,
        scheduled_at: scheduled_at,
        duration_minutes: service.duration_minutes,
        price_cents: service.base_price_cents,
        vehicle_description: params["vehicle_description"] |> to_string() |> String.trim(),
        service_address: params["service_address"] |> to_string() |> String.trim(),
        notes: params["notes"]
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  # Decide what happens after the appointment is created.
  #
  # If the tenant has Stripe Connect onboarded, we mint a Stripe
  # Checkout Session, attach its id to the appointment, and redirect
  # the customer to Stripe's hosted page. Stripe will redirect them
  # back to /book/success/:id once they pay.
  #
  # Otherwise (tenant hasn't connected Stripe yet), we fall back to
  # the V0.5 path: appointment exists in :unpaid state, customer
  # lands on the confirmation page, payment is collected on-site.
  defp handle_post_booking(socket, tenant, customer, service, appt) do
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
          # Stripe failed — keep the appointment as-is and send the
          # customer to the confirmation page. Better than losing the
          # booking entirely; admin can reach out to collect payment.
          {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
      end
    else
      # Non-Stripe path: payment is collected on-site. Send the
      # confirmation email immediately since there's no webhook to
      # wait on.
      send_confirmation_email(tenant, customer, appt, service)
      {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
    end
  end

  defp send_confirmation_email(tenant, customer, appt, service) do
    tenant
    |> BookingEmail.confirmation(customer, appt, service)
    |> Mailer.deliver()
  rescue
    # Don't crash the booking just because email failed.
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

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-12">
      <div class="max-w-2xl mx-auto card bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-2xl">Book a wash</h1>
          <p class="text-base-content/70 mb-2">
            Welcome back, {@current_customer.name}. Pick a service and a time.
          </p>

          <div :if={@errors[:base]} class="alert alert-error text-sm">{@errors[:base]}</div>

          <form id="booking-form" phx-submit="submit" class="space-y-4">
            <div>
              <label class="label" for="booking-service">
                <span class="label-text">Service</span>
              </label>
              <select
                id="booking-service"
                name="booking[service_type_id]"
                class="select select-bordered w-full"
                required
              >
                <option value="">— Pick a service —</option>
                <option
                  :for={svc <- @services}
                  value={svc.id}
                  selected={@form["service_type_id"] == svc.id}
                >
                  {svc.name} — {fmt_price(svc.base_price_cents)} ({svc.duration_minutes} min)
                </option>
              </select>
              <p :if={@errors[:service_type_id]} class="text-error text-sm mt-1">
                {@errors[:service_type_id]}
              </p>
            </div>

            <div :if={@slots != []}>
              <label class="label" for="booking-slot">
                <span class="label-text">Available slots</span>
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
              <p :if={@errors[:scheduled_at]} class="text-error text-sm mt-1">
                {@errors[:scheduled_at]}
              </p>
            </div>

            <div :if={@slots == []}>
              <label class="label" for="booking-scheduled-at">
                <span class="label-text">Date & time</span>
              </label>
              <input
                id="booking-scheduled-at"
                type="datetime-local"
                name="booking[scheduled_at]"
                value={@form["scheduled_at"]}
                class="input input-bordered w-full"
                required
              />
              <p :if={@errors[:scheduled_at]} class="text-error text-sm mt-1">
                {@errors[:scheduled_at]}
              </p>
            </div>

            <div>
              <label class="label" for="booking-vehicle">
                <span class="label-text">Vehicle</span>
              </label>
              <input
                id="booking-vehicle"
                type="text"
                name="booking[vehicle_description]"
                value={@form["vehicle_description"]}
                placeholder="Year + make + model + color"
                class="input input-bordered w-full"
                required
              />
            </div>

            <div>
              <label class="label" for="booking-address">
                <span class="label-text">Service address</span>
              </label>
              <input
                id="booking-address"
                type="text"
                name="booking[service_address]"
                value={@form["service_address"]}
                placeholder="123 Main St, San Antonio TX 78261"
                class="input input-bordered w-full"
                required
              />
            </div>

            <div>
              <label class="label" for="booking-notes">
                <span class="label-text">Notes (optional)</span>
              </label>
              <textarea
                id="booking-notes"
                name="booking[notes]"
                rows="2"
                placeholder="Gate code, special requests, etc."
                class="textarea textarea-bordered w-full"
              >{@form["notes"]}</textarea>
            </div>

            <button type="submit" class="btn btn-primary w-full">Book it</button>

            <p class="text-xs text-base-content/60 text-center">
              {@current_tenant.display_name} will confirm and reach out to schedule. Payment is collected on-site for now.
            </p>
          </form>
        </div>
      </div>
    </main>
    """
  end
end
