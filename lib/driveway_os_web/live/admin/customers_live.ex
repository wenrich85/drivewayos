defmodule DrivewayOSWeb.Admin.CustomersLive do
  @moduledoc """
  Tenant admin → customer list at `{slug}.lvh.me/admin/customers`.

  V1 keeps it read-only: a sortable table of every customer in
  this tenant with their basic contact info + appointment count.
  Admins use the existing booking flow if they need to create one
  on behalf of a customer (V2 adds a "create customer" form).
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Scheduling.Appointment

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
         |> assign(:page_title, "Customers")
         |> load_customers()}
    end
  end

  defp load_customers(socket) do
    tenant_id = socket.assigns.current_tenant.id

    customers =
      Customer
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)

    {:ok, appointments} =
      Appointment
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read(authorize?: false)

    appt_counts = Enum.frequencies_by(appointments, & &1.customer_id)

    socket
    |> assign(:customers, customers)
    |> assign(:appt_counts, appt_counts)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-4xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Customers</h1>
            <p class="text-base-content/70 text-sm">
              Everyone who's signed up at {@current_tenant.display_name}.
            </p>
          </div>
          <a href="/admin" class="btn btn-ghost btn-sm">← Dashboard</a>
        </div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <div :if={@customers == []} class="text-center py-6 text-base-content/60">
              No customers yet.
            </div>

            <div :if={@customers != []} class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Email</th>
                    <th>Role</th>
                    <th>Bookings</th>
                    <th>Joined</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={c <- @customers}>
                    <td class="font-semibold">{c.name}</td>
                    <td>{to_string(c.email)}</td>
                    <td>
                      <span :if={c.role == :admin} class="badge badge-primary badge-sm">Admin</span>
                      <span :if={c.role != :admin} class="badge badge-ghost badge-sm">Customer</span>
                    </td>
                    <td>{Map.get(@appt_counts, c.id, 0)}</td>
                    <td class="text-xs text-base-content/60">
                      {Calendar.strftime(c.inserted_at, "%b %-d, %Y")}
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
