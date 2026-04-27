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

  # True when the tenant has loyalty configured AND this customer
  # has hit the threshold. Hidden when the tenant hasn't enabled
  # loyalty so the badge column doesn't accidentally render for
  # everyone with loyalty_count > 0 (default 0 means the badge
  # never shows, but loyalty_threshold being nil is the load-bearing
  # gate).
  defp loyalty_earned?(%{loyalty_threshold: t}, %{loyalty_count: c})
       when is_integer(t) and is_integer(c),
       do: c >= t

  defp loyalty_earned?(_, _), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-5xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Dashboard
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">Customers</h1>
          <p class="text-sm text-base-content/70 mt-1">
            Everyone who's signed up at <span class="font-semibold">{@current_tenant.display_name}</span>.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div :if={@customers == []} class="text-center py-12 px-4">
              <span
                class="hero-user-group w-12 h-12 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60">No customers yet.</p>
            </div>

            <div :if={@customers != []} class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Name
                    </th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Email
                    </th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Role
                    </th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Bookings
                    </th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Joined
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={c <- @customers} class="hover:bg-base-200/50 cursor-pointer">
                    <td class="font-semibold">
                      <div class="flex items-center gap-2 flex-wrap">
                        <.link navigate={~p"/admin/customers/#{c.id}"} class="link link-hover">
                          {c.name}
                        </.link>
                        <span
                          :if={loyalty_earned?(@current_tenant, c)}
                          class="badge badge-success badge-sm gap-1"
                          title="Has earned a free wash"
                        >
                          <span class="hero-gift w-3 h-3" aria-hidden="true"></span> Free wash
                        </span>
                      </div>
                    </td>
                    <td class="text-sm">{to_string(c.email)}</td>
                    <td>
                      <span :if={c.role == :admin} class="badge badge-primary badge-sm">Admin</span>
                      <span :if={c.role != :admin} class="badge badge-ghost badge-sm">Customer</span>
                    </td>
                    <td class="text-sm">{Map.get(@appt_counts, c.id, 0)}</td>
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
