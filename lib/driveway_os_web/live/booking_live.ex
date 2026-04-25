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

  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        services = load_services(socket.assigns.current_tenant.id)

        {:ok,
         socket
         |> assign(:page_title, "Book a wash")
         |> assign(:services, services)
         |> assign(:errors, %{})
         |> assign(:form, blank_form())}
    end
  end

  @impl true
  def handle_event("submit", %{"booking" => params}, socket) do
    tenant = socket.assigns.current_tenant
    customer = socket.assigns.current_customer

    with {:ok, service} <- fetch_service(params["service_type_id"], tenant.id),
         {:ok, scheduled_at} <- parse_scheduled_at(params["scheduled_at"]),
         {:ok, appt} <-
           create_appointment(tenant, customer, service, scheduled_at, params) do
      {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
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

            <div>
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
