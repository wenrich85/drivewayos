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

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Scheduling.Appointment

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if is_nil(socket.assigns[:current_tenant]) do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      load_appointment(socket, id)
    end
  end

  # Two paths land here:
  #
  #   1. Signed-in customer who just booked — owns the appointment via
  #      `customer_id == current_customer.id`.
  #   2. Anonymous guest who completed the wizard — `current_customer`
  #      is nil because guests get no session token. We allow the
  #      view as long as the appointment's customer is flagged
  #      `guest?: true`. The id is a UUID, so possessing the URL is
  #      proof of being the booker (same model as a Stripe receipt).
  defp load_appointment(socket, id) do
    tenant_id = socket.assigns.current_tenant.id
    me = socket.assigns[:current_customer]

    with {:ok, appt} <- Ash.get(Appointment, id, tenant: tenant_id, authorize?: false),
         {:ok, booker} <- Ash.get(Customer, appt.customer_id, tenant: tenant_id, authorize?: false),
         true <- can_view?(booker, me) do
      {:ok,
       socket
       |> assign(:page_title, "Booking confirmed")
       |> assign(:appointment, appt)
       |> assign(:booker, booker)}
    else
      _ -> {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp can_view?(%Customer{id: id}, %Customer{id: id}), do: true
  defp can_view?(%Customer{guest?: true}, _), do: true
  defp can_view?(_, _), do: false

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp fmt_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%A, %B %-d, %Y at %-I:%M %p")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-8 text-center space-y-4">
            <div
              class="mx-auto h-16 w-16 rounded-full bg-success/15 text-success flex items-center justify-center"
              aria-hidden="true"
            >
              <span class="hero-check w-8 h-8"></span>
            </div>
            <h1 class="text-2xl font-bold">Your booking is in</h1>
            <p class="text-base-content/70 max-w-md mx-auto">
              <span class="font-semibold">{@current_tenant.display_name}</span>
              will be in touch to confirm and reach out the day of.
            </p>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-4">
            <h2 class="card-title text-base">Appointment summary</h2>

            <dl class="grid grid-cols-3 gap-3 text-sm">
              <dt class="text-base-content/60 col-span-1">When</dt>
              <dd class="font-medium col-span-2">{fmt_when(@appointment.scheduled_at)}</dd>

              <dt class="text-base-content/60 col-span-1">Vehicle</dt>
              <dd class="col-span-2">{@appointment.vehicle_description}</dd>

              <dt class="text-base-content/60 col-span-1">Address</dt>
              <dd class="col-span-2">{@appointment.service_address}</dd>

              <dt class="text-base-content/60 col-span-1">Total</dt>
              <dd class="col-span-2 font-semibold">{fmt_price(@appointment.price_cents)}</dd>

              <%= if @appointment.notes && @appointment.notes != "" do %>
                <dt class="text-base-content/60 col-span-1">Notes</dt>
                <dd class="col-span-2 text-base-content/80">{@appointment.notes}</dd>
              <% end %>
            </dl>
          </div>
        </section>

        <div class="flex justify-end gap-2">
          <.link
            :if={@current_customer && not @booker.guest?}
            navigate={~p"/appointments"}
            class="btn btn-ghost btn-sm"
          >
            My appointments
          </.link>
          <.link
            :if={@booker.guest?}
            navigate={~p"/register"}
            class="btn btn-ghost btn-sm"
          >
            Create account
          </.link>
          <.link navigate={~p"/book"} class="btn btn-primary btn-sm gap-2">
            <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Book another
          </.link>
        </div>
      </div>
    </main>
    """
  end
end
