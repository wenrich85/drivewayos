defmodule DrivewayOSWeb.Admin.AppointmentsLive do
  @moduledoc """
  Tenant admin → all appointments at `{slug}.lvh.me/admin/appointments`.

  Table view of every appointment in this tenant. Confirm/cancel
  actions are inline. Filters land in V2 (status, date range,
  service type).
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Appointments")
         |> load_data()}
    end
  end

  @impl true
  def handle_event("confirm_appointment", %{"id" => id}, socket) do
    update_appt(socket, id, fn appt ->
      Ash.Changeset.for_update(appt, :confirm, %{})
    end)
  end

  def handle_event("cancel_appointment", %{"id" => id}, socket) do
    update_appt(socket, id, fn appt ->
      Ash.Changeset.for_update(appt, :cancel, %{cancellation_reason: "Cancelled by admin"})
    end)
  end

  defp update_appt(socket, id, build_changeset) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(Appointment, id, tenant: tenant_id, authorize?: false) do
      {:ok, appt} ->
        appt
        |> build_changeset.()
        |> Ash.update!(authorize?: false, tenant: tenant_id)

        {:noreply, load_data(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp load_data(socket) do
    tenant_id = socket.assigns.current_tenant.id

    appointments =
      Appointment
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.Query.sort(scheduled_at: :desc)
      |> Ash.read!(authorize?: false)

    {:ok, customers} =
      Customer |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false)

    {:ok, services} =
      ServiceType |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false)

    socket
    |> assign(:appointments, appointments)
    |> assign(:customer_map, Map.new(customers, &{&1.id, &1}))
    |> assign(:service_map, Map.new(services, &{&1.id, &1}))
  end

  defp fmt_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d %-I:%M %p")

  defp status_badge(status) do
    case status do
      :pending -> "badge-warning"
      :confirmed -> "badge-info"
      :in_progress -> "badge-primary"
      :completed -> "badge-success"
      :cancelled -> "badge-ghost"
      _ -> "badge"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-5xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Appointments</h1>
            <p class="text-base-content/70 text-sm">
              All bookings, newest first.
            </p>
          </div>
          <a href="/admin" class="btn btn-ghost btn-sm">← Dashboard</a>
        </div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <div :if={@appointments == []} class="text-center py-6 text-base-content/60">
              No appointments yet.
            </div>

            <div :if={@appointments != []} class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>When</th>
                    <th>Customer</th>
                    <th>Service</th>
                    <th>Vehicle</th>
                    <th>Status</th>
                    <th>Payment</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={a <- @appointments}>
                    <td class="text-sm">
                      <.link navigate={~p"/appointments/#{a.id}"} class="link link-hover">
                        {fmt_when(a.scheduled_at)}
                      </.link>
                    </td>
                    <td>{(@customer_map[a.customer_id] || %{name: "—"}).name}</td>
                    <td>{(@service_map[a.service_type_id] || %{name: "—"}).name}</td>
                    <td class="text-xs text-base-content/70">{a.vehicle_description}</td>
                    <td>
                      <span class={"badge badge-sm #{status_badge(a.status)}"}>
                        {a.status}
                      </span>
                    </td>
                    <td>
                      <span :if={a.payment_status == :paid} class="badge badge-success badge-sm">
                        Paid
                      </span>
                      <span :if={a.payment_status == :pending} class="badge badge-warning badge-sm">
                        Pending
                      </span>
                      <span :if={a.payment_status == :unpaid} class="badge badge-ghost badge-sm">
                        Unpaid
                      </span>
                    </td>
                    <td class="text-right space-x-1">
                      <button
                        :if={a.status == :pending}
                        phx-click="confirm_appointment"
                        phx-value-id={a.id}
                        class="btn btn-success btn-xs"
                      >
                        Confirm
                      </button>
                      <button
                        :if={a.status in [:pending, :confirmed]}
                        phx-click="cancel_appointment"
                        phx-value-id={a.id}
                        data-confirm="Cancel this appointment?"
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Cancel
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
