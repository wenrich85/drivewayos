defmodule DrivewayOSWeb.Admin.DashboardLive do
  @moduledoc """
  Tenant-admin dashboard at `{slug}.lvh.me/admin`. Shows the
  operator a summary of their shop: pending bookings to confirm,
  customer count, today's schedule.

  V1 keeps it lean — three cards + a "pending appointments" list
  with confirm/cancel actions inline. V2 adds dispatch kanban,
  customer detail pages, marketing rollups, etc.

  Auth + authorization at mount: must be a Customer (loaded by
  LoadCustomerHook) AND `role == :admin`. Non-admins bounce to /
  (the customer-facing landing).
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
        {:ok, load_dashboard(socket)}
    end
  end

  @impl true
  def handle_event("confirm_appointment", %{"id" => id}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(Appointment, id, tenant: tenant_id, authorize?: false) do
      {:ok, appt} ->
        appt
        |> Ash.Changeset.for_update(:confirm, %{})
        |> Ash.update!(authorize?: false, tenant: tenant_id)

        {:noreply, load_dashboard(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_appointment", %{"id" => id}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(Appointment, id, tenant: tenant_id, authorize?: false) do
      {:ok, appt} ->
        appt
        |> Ash.Changeset.for_update(:cancel, %{cancellation_reason: "Cancelled by admin"})
        |> Ash.update!(authorize?: false, tenant: tenant_id)

        {:noreply, load_dashboard(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # --- Private ---

  defp load_dashboard(socket) do
    tenant_id = socket.assigns.current_tenant.id

    appointments =
      Appointment
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read!(authorize?: false)

    customers =
      Customer
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read!(authorize?: false)

    service_ids = appointments |> Enum.map(& &1.service_type_id) |> Enum.uniq()

    service_map =
      if service_ids == [] do
        %{}
      else
        ServiceType
        |> Ash.Query.filter(id in ^service_ids)
        |> Ash.Query.set_tenant(tenant_id)
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.id, &1})
      end

    customer_map = Map.new(customers, &{&1.id, &1})

    pending = Enum.filter(appointments, &(&1.status == :pending))
    upcoming = Enum.filter(appointments, &(&1.status in [:pending, :confirmed]))

    socket
    |> assign(:page_title, "Admin · #{socket.assigns.current_tenant.display_name}")
    |> assign(:pending, Enum.sort_by(pending, & &1.scheduled_at, DateTime))
    |> assign(:pending_count, length(pending))
    |> assign(:upcoming_count, length(upcoming))
    |> assign(:customer_count, length(customers))
    |> assign(:service_map, service_map)
    |> assign(:customer_map, customer_map)
  end

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp fmt_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a %b %-d · %-I:%M %p")
  end

  defp service_name(map, id), do: get_in(map, [id, Access.key(:name)]) || "Service"

  defp customer_name(map, id), do: get_in(map, [id, Access.key(:name)]) || "Customer"

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-5xl mx-auto space-y-6">
        <div class="flex justify-between items-start flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Admin · {@current_tenant.display_name}</h1>
            <p class="text-base-content/70 text-sm">
              Welcome back, {@current_customer.name}.
            </p>
          </div>
          <div class="flex gap-2">
            <a href="/admin/domains" class="btn btn-ghost btn-sm">Domains</a>
            <a href="/auth/customer/sign-out" class="btn btn-ghost btn-sm">Sign out</a>
          </div>
        </div>

        <div
          :if={is_nil(@current_tenant.stripe_account_id)}
          class="alert alert-warning shadow"
        >
          <div class="flex-1">
            <div class="font-semibold">Stripe not connected yet</div>
            <div class="text-sm">
              Connect your Stripe account to start collecting payment for bookings.
            </div>
          </div>
          <a href="/onboarding/stripe/start" class="btn btn-primary btn-sm">Connect Stripe</a>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Pending</div>
            <div class="stat-value text-warning">{@pending_count}</div>
            <div class="stat-desc">Awaiting your confirmation</div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Upcoming</div>
            <div class="stat-value text-info">{@upcoming_count}</div>
            <div class="stat-desc">Pending + confirmed</div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Customers</div>
            <div class="stat-value">{@customer_count}</div>
            <div class="stat-desc">All time</div>
          </div>
        </div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">Pending appointments</h2>

            <div :if={@pending == []} class="text-center py-8 text-base-content/60">
              Nothing pending. New bookings will show up here.
            </div>

            <ul :if={@pending != []} class="divide-y divide-base-200">
              <li :for={a <- @pending} class="py-3 flex items-center justify-between gap-3 flex-wrap">
                <div class="flex-1 min-w-0">
                  <div class="font-semibold">
                    {service_name(@service_map, a.service_type_id)}
                    <span class="text-base-content/50">·</span>
                    <span class="text-sm text-base-content/70">
                      {customer_name(@customer_map, a.customer_id)}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    {fmt_when(a.scheduled_at)} · {a.vehicle_description}
                  </div>
                  <div class="text-xs text-base-content/60 truncate">
                    {a.service_address}
                  </div>
                </div>

                <div class="flex items-center gap-2">
                  <span class="font-semibold text-sm">
                    {fmt_price(a.price_cents)}
                  </span>
                  <button
                    phx-click="confirm_appointment"
                    phx-value-id={a.id}
                    class="btn btn-success btn-sm"
                  >
                    Confirm
                  </button>
                  <button
                    phx-click="cancel_appointment"
                    phx-value-id={a.id}
                    data-confirm="Cancel this appointment?"
                    class="btn btn-ghost btn-sm text-error"
                  >
                    Cancel
                  </button>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
