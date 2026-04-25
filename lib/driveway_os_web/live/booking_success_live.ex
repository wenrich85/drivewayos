defmodule DrivewayOSWeb.BookingSuccessLive do
  @moduledoc """
  Confirmation page after a successful booking. Shows the appointment
  summary and a link back to the tenant's home page.

  V2 will turn this into a richer "My Appointments" hub with status
  updates, cancellation, etc. — for V1 it's the smallest possible
  "yes, your booking is on file" landing.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Scheduling.Appointment

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        case Ash.get(Appointment, id, tenant: socket.assigns.current_tenant.id, authorize?: false) do
          {:ok, %{customer_id: cid} = appt}
          when cid == socket.assigns.current_customer.id ->
            {:ok,
             socket
             |> assign(:page_title, "Booking confirmed")
             |> assign(:appointment, appt)}

          _ ->
            # Either the appointment doesn't exist in this tenant, or
            # it belongs to a different customer in this tenant. Both
            # cases get the same not-found redirect — never leak
            # which one happened.
            {:ok, push_navigate(socket, to: ~p"/")}
        end
    end
  end

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp fmt_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%A, %B %-d, %Y at %-I:%M %p")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-12">
      <div class="max-w-2xl mx-auto card bg-base-100 shadow-lg">
        <div class="card-body text-center space-y-3">
          <div class="text-4xl">✓</div>
          <h1 class="card-title text-2xl justify-center">Your booking is in</h1>
          <p class="text-base-content/70">
            {@current_tenant.display_name} will be in touch to confirm.
          </p>

          <div class="divider"></div>

          <dl class="text-left space-y-2">
            <div>
              <dt class="text-sm text-base-content/60">When</dt>
              <dd class="font-medium">{fmt_when(@appointment.scheduled_at)}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Vehicle</dt>
              <dd>{@appointment.vehicle_description}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Address</dt>
              <dd>{@appointment.service_address}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Total</dt>
              <dd class="font-semibold">{fmt_price(@appointment.price_cents)}</dd>
            </div>
            <div :if={@appointment.notes && @appointment.notes != ""}>
              <dt class="text-sm text-base-content/60">Notes</dt>
              <dd class="text-sm">{@appointment.notes}</dd>
            </div>
          </dl>

          <div class="flex justify-center gap-2 pt-4">
            <.link navigate={~p"/"} class="btn btn-ghost">Back to home</.link>
            <.link navigate={~p"/book"} class="btn btn-primary">Book another</.link>
          </div>
        </div>
      </div>
    </main>
    """
  end
end
