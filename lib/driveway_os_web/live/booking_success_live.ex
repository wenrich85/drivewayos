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
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Plans
  alias DrivewayOS.Scheduling.{Appointment, ServiceType, Subscription}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if is_nil(socket.assigns[:current_tenant]) do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      load_appointment(socket, id)
    end
  end

  # --- Self-serve subscribe ---

  @impl true
  def handle_event("show_subscribe_form", _, socket) do
    {:noreply, assign(socket, :subscribe_state, :form)}
  end

  def handle_event("hide_subscribe_form", _, socket) do
    {:noreply, assign(socket, :subscribe_state, :idle)}
  end

  def handle_event("subscribe", %{"sub" => %{"frequency" => freq}}, socket) do
    appt = socket.assigns.appointment
    me = socket.assigns.current_customer
    tenant = socket.assigns.current_tenant

    # Don't double-book the just-booked appointment — start the
    # recurring schedule one cycle after the current one.
    starts_at = next_run_after(appt.scheduled_at, freq)

    attrs = %{
      customer_id: me.id,
      service_type_id: appt.service_type_id,
      frequency: String.to_existing_atom(freq),
      starts_at: starts_at,
      vehicle_id: appt.vehicle_id,
      vehicle_description: appt.vehicle_description,
      address_id: appt.address_id,
      service_address: appt.service_address
    }

    case Subscription
         |> Ash.Changeset.for_create(:subscribe, attrs, tenant: tenant.id)
         |> Ash.create(authorize?: false) do
      {:ok, sub} ->
        send_subscription_confirmation(tenant, me, sub)
        {:noreply, assign(socket, :subscribe_state, :done)}

      _ ->
        {:noreply, assign(socket, :subscribe_state, :error)}
    end
  end

  defp send_subscription_confirmation(tenant, customer, sub) do
    case Ash.get(ServiceType, sub.service_type_id, tenant: tenant.id, authorize?: false) do
      {:ok, service} ->
        tenant
        |> BookingEmail.subscription_confirmed(customer, sub, service)
        |> Mailer.deliver(Mailer.for_tenant(tenant))

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp next_run_after(scheduled_at, "weekly"), do: DateTime.add(scheduled_at, 7 * 86_400, :second)
  defp next_run_after(scheduled_at, "biweekly"), do: DateTime.add(scheduled_at, 14 * 86_400, :second)
  defp next_run_after(scheduled_at, "monthly"), do: DateTime.add(scheduled_at, 30 * 86_400, :second)
  defp next_run_after(scheduled_at, _), do: DateTime.add(scheduled_at, 14 * 86_400, :second)

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
         true <- can_view?(booker, me),
         {:ok, service} <-
           Ash.get(ServiceType, appt.service_type_id, tenant: tenant_id, authorize?: false) do
      {:ok,
       socket
       |> assign(:page_title, "Booking confirmed")
       |> assign(:appointment, appt)
       |> assign(:booker, booker)
       |> assign(:service, service)
       |> assign(:subscribe_state, :idle)}
    else
      _ -> {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  # Self-serve subscribe is gated to:
  #   * tenant is on a plan that includes :customer_subscriptions
  #     (Starter is excluded; Pro+ have it via data migration)
  #   * signed-in (we need a real account to attach)
  #   * non-guest (guest accounts are ephemeral; H5 doesn't apply)
  #   * the customer who booked this appointment (admins use H4
  #     on /admin/customers/:id, not this page)
  defp can_subscribe?(%{
         current_tenant: tenant,
         current_customer: %Customer{id: id},
         booker: %Customer{id: id, guest?: false}
       }) do
    Plans.tenant_can?(tenant, :customer_subscriptions)
  end

  defp can_subscribe?(_), do: false

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
              <dt class="text-base-content/60 col-span-1">Service</dt>
              <dd class="col-span-2">
                <div class="font-semibold">{@service.name}</div>
                <div
                  :if={@service.description && @service.description != ""}
                  class="text-xs text-base-content/60 mt-0.5"
                >
                  {@service.description}
                </div>
              </dd>

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

        <section
          :if={can_subscribe?(assigns)}
          class="card bg-base-100 shadow-sm border border-base-300"
        >
          <div class="card-body p-6">
            <%= if @subscribe_state == :done do %>
              <div class="flex items-center gap-3">
                <span class="hero-check-circle w-6 h-6 text-success" aria-hidden="true"></span>
                <div>
                  <p class="font-semibold">You're set up for recurring.</p>
                  <p class="text-sm text-base-content/70 mt-1">
                    We'll auto-book the next one — manage anytime from your profile.
                  </p>
                </div>
              </div>
            <% else %>
              <div class="flex items-start gap-3 flex-wrap">
                <span class="hero-arrow-path w-6 h-6 text-primary mt-1 shrink-0" aria-hidden="true"></span>
                <div class="flex-1 min-w-0">
                  <p class="font-semibold">Make it recurring?</p>
                  <p class="text-sm text-base-content/70 mt-1">
                    Auto-book the same wash on a schedule. Pause or cancel from your profile anytime.
                  </p>

                  <button
                    :if={@subscribe_state == :idle}
                    phx-click="show_subscribe_form"
                    class="btn btn-primary btn-sm mt-3 gap-1"
                  >
                    <span class="hero-arrow-path w-4 h-4" aria-hidden="true"></span>
                    Set up recurring
                  </button>

                  <form
                    :if={@subscribe_state == :form}
                    id="subscribe-form"
                    phx-submit="subscribe"
                    class="mt-3 space-y-3"
                  >
                    <div class="flex flex-wrap gap-2">
                      <label
                        :for={
                          {value, label} <-
                            [
                              {"weekly", "Weekly"},
                              {"biweekly", "Every 2 weeks"},
                              {"monthly", "Monthly"}
                            ]
                        }
                        class="cursor-pointer"
                      >
                        <input
                          type="radio"
                          name="sub[frequency]"
                          value={value}
                          class="peer hidden"
                          checked={value == "biweekly"}
                          required
                        />
                        <span class="btn btn-sm btn-ghost peer-checked:btn-primary">
                          {label}
                        </span>
                      </label>
                    </div>
                    <div class="flex gap-2">
                      <button
                        type="button"
                        phx-click="hide_subscribe_form"
                        class="btn btn-ghost btn-sm"
                      >
                        Cancel
                      </button>
                      <button type="submit" class="btn btn-primary btn-sm">Subscribe</button>
                    </div>
                  </form>

                  <div
                    :if={@subscribe_state == :error}
                    role="alert"
                    class="alert alert-error mt-3 text-sm"
                  >
                    Couldn't set up recurring. Try again from your profile.
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </section>

        <div class="flex justify-end gap-2 flex-wrap">
          <a
            href={~p"/appointments/#{@appointment.id}/calendar.ics"}
            class="btn btn-ghost btn-sm gap-1"
          >
            <span class="hero-calendar w-4 h-4" aria-hidden="true"></span>
            Add to calendar
          </a>
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
