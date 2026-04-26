defmodule DrivewayOSWeb.CustomerProfileLive do
  @moduledoc """
  /me — the signed-in customer's profile + saved-data hub.

  V1 read-only: profile (name / email / phone), saved vehicles,
  saved addresses, plus links into /book and /appointments. The
  edit forms (D2) flip individual rows into editable mode.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Fleet.{Address, Vehicle}

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        tenant_id = socket.assigns.current_tenant.id
        customer_id = socket.assigns.current_customer.id

        {:ok,
         socket
         |> assign(:page_title, "Profile")
         |> assign(:vehicles, load_vehicles(customer_id, tenant_id))
         |> assign(:addresses, load_addresses(customer_id, tenant_id))}
    end
  end

  defp load_vehicles(customer_id, tenant_id) do
    Vehicle
    |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp load_addresses(customer_id, tenant_id) do
    Address
    |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header class="flex justify-between items-start gap-3 flex-wrap">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Profile
            </p>
            <h1 class="text-3xl font-bold tracking-tight">{@current_customer.name}</h1>
          </div>
          <nav class="flex gap-1 flex-wrap">
            <.link navigate={~p"/appointments"} class="btn btn-ghost btn-sm gap-1">
              <span class="hero-calendar w-4 h-4" aria-hidden="true"></span> Appointments
            </.link>
            <.link navigate={~p"/book"} class="btn btn-primary btn-sm gap-1">
              <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Book a wash
            </.link>
            <a href="/auth/customer/sign-out" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-arrow-left-on-rectangle w-4 h-4" aria-hidden="true"></span>
              Sign out
            </a>
          </nav>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-base">Account</h2>
            <dl class="grid grid-cols-3 gap-x-3 gap-y-2 text-sm mt-2">
              <dt class="text-base-content/60">Name</dt>
              <dd class="col-span-2 font-medium">{@current_customer.name}</dd>

              <dt class="text-base-content/60">Email</dt>
              <dd class="col-span-2">{to_string(@current_customer.email)}</dd>

              <dt class="text-base-content/60">Phone</dt>
              <dd class="col-span-2">
                {@current_customer.phone || "—"}
              </dd>
            </dl>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-base">Saved vehicles</h2>

            <div :if={@vehicles == []} class="text-sm text-base-content/60 mt-2">
              No saved vehicles yet — add one when you book your next wash.
            </div>

            <ul :if={@vehicles != []} class="divide-y divide-base-200 mt-2">
              <li :for={v <- @vehicles} class="py-3 flex items-center gap-3">
                <span
                  class="hero-truck w-5 h-5 text-base-content/40 shrink-0"
                  aria-hidden="true"
                ></span>
                <span class="font-medium">{Vehicle.display_label(v)}</span>
              </li>
            </ul>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-base">Saved addresses</h2>

            <div :if={@addresses == []} class="text-sm text-base-content/60 mt-2">
              No saved addresses yet — add one when you book.
            </div>

            <ul :if={@addresses != []} class="divide-y divide-base-200 mt-2">
              <li :for={a <- @addresses} class="py-3 flex items-center gap-3">
                <span
                  class="hero-map-pin w-5 h-5 text-base-content/40 shrink-0"
                  aria-hidden="true"
                ></span>
                <span class="font-medium">{Address.display_label(a)}</span>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
