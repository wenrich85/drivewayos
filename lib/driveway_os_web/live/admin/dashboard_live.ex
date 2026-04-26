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
  alias DrivewayOS.Platform.CustomDomain
  alias DrivewayOS.Scheduling.{Appointment, BlockTemplate, ServiceType}

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

    {:ok, blocks} =
      BlockTemplate |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false)

    {:ok, custom_domains} =
      CustomDomain
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    checklist = build_checklist(socket.assigns.current_tenant, blocks, custom_domains)

    socket
    |> assign(:page_title, "Admin · #{socket.assigns.current_tenant.display_name}")
    |> assign(:pending, Enum.sort_by(pending, & &1.scheduled_at, DateTime))
    |> assign(:pending_count, length(pending))
    |> assign(:upcoming_count, length(upcoming))
    |> assign(:customer_count, length(customers))
    |> assign(:service_map, service_map)
    |> assign(:customer_map, customer_map)
    |> assign(:checklist, checklist)
  end

  # Returns a list of `{title, blurb, href}` for the open onboarding
  # items only — completed ones drop out, so when everything's done
  # the checklist is just `[]` and the card hides itself.
  defp build_checklist(tenant, blocks, custom_domains) do
    [
      is_nil(tenant.stripe_account_id) &&
        {"Connect Stripe", "Take payment for bookings.", "/onboarding/stripe/start"},
      Enum.empty?(blocks) &&
        {"Define your availability",
         "Customers see concrete time slots once you've added at least one weekly block.",
         "/admin/schedule"},
      missing_branding?(tenant) &&
        {"Customize your branding",
         "Upload a logo, set your support email, pick a brand color.",
         "/admin/branding"},
      Enum.empty?(custom_domains) &&
        {"(Optional) Run on your own domain",
         "Point a hostname like book.yourshop.com at DrivewayOS.",
         "/admin/domains"}
    ]
    |> Enum.filter(& &1)
  end

  # Onboarding-time defaults like "no logo" + "no support email"
  # mean the operator hasn't customized branding yet.
  defp missing_branding?(tenant) do
    is_nil(tenant.support_email) and is_nil(tenant.logo_url)
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
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-6xl mx-auto space-y-6">
        <header class="flex justify-between items-start flex-wrap gap-3">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Admin</p>
            <h1 class="text-3xl font-bold tracking-tight">{@current_tenant.display_name}</h1>
            <p class="text-sm text-base-content/70 mt-1">
              Welcome back, {@current_customer.name}.
            </p>
          </div>
          <nav class="flex gap-1 flex-wrap" aria-label="Admin sections">
            <.nav_link href="/admin/appointments" icon="hero-calendar">Appointments</.nav_link>
            <.nav_link href="/admin/customers" icon="hero-user-group">Customers</.nav_link>
            <.nav_link href="/admin/services" icon="hero-rectangle-stack">Services</.nav_link>
            <.nav_link href="/admin/schedule" icon="hero-clock">Schedule</.nav_link>
            <.nav_link href="/admin/branding" icon="hero-paint-brush">Branding</.nav_link>
            <.nav_link href="/admin/domains" icon="hero-globe-alt">Domains</.nav_link>
            <a href="/auth/customer/sign-out" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-arrow-left-on-rectangle w-4 h-4" aria-hidden="true"></span>
              Sign out
            </a>
          </nav>
        </header>

        <section
          :if={@checklist != []}
          class="card bg-warning/10 border border-warning/30 shadow-sm"
        >
          <div class="card-body p-6">
            <div class="flex items-start gap-3">
              <span class="hero-rocket-launch w-6 h-6 text-warning shrink-0 mt-0.5" aria-hidden="true"></span>
              <div>
                <h2 class="card-title text-lg">Get set up</h2>
                <p class="text-sm text-base-content/70">
                  A few things to take care of before you're ready for real customers.
                </p>
              </div>
            </div>

            <ul class="space-y-3 mt-3">
              <li
                :for={{title, blurb, href} <- @checklist}
                class="flex gap-3 items-start bg-base-100 border border-base-300 rounded-lg p-4"
              >
                <span class="hero-arrow-right-circle w-5 h-5 text-warning shrink-0 mt-0.5" aria-hidden="true"></span>
                <div class="flex-1">
                  <div class="font-semibold">{title}</div>
                  <div class="text-sm text-base-content/70">{blurb}</div>
                </div>
                <a href={href} class="btn btn-primary btn-sm">Do it</a>
              </li>
            </ul>
          </div>
        </section>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Pending
            </div>
            <div class="stat-value text-3xl font-bold text-warning">{@pending_count}</div>
            <div class="stat-desc text-xs text-base-content/60">Awaiting your confirmation</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Upcoming
            </div>
            <div class="stat-value text-3xl font-bold text-info">{@upcoming_count}</div>
            <div class="stat-desc text-xs text-base-content/60">Pending + confirmed</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Customers
            </div>
            <div class="stat-value text-3xl font-bold">{@customer_count}</div>
            <div class="stat-desc text-xs text-base-content/60">All time</div>
          </article>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h2 class="card-title text-lg">Pending appointments</h2>
              <a
                :if={@pending != []}
                href="/admin/appointments"
                class="btn btn-ghost btn-sm gap-1"
              >
                View all
                <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
              </a>
            </div>

            <div :if={@pending == []} class="text-center py-12 px-4">
              <span class="hero-inbox w-12 h-12 mx-auto text-base-content/30" aria-hidden="true"></span>
              <h3 class="mt-4 text-lg font-semibold">All caught up</h3>
              <p class="mt-1 text-sm text-base-content/60 max-w-sm mx-auto">
                Nothing pending right now. New bookings show up here automatically.
              </p>
            </div>

            <ul :if={@pending != []} class="divide-y divide-base-200 mt-2">
              <li
                :for={a <- @pending}
                class="py-4 flex items-start justify-between gap-3 flex-wrap"
              >
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <.link
                      navigate={~p"/appointments/#{a.id}"}
                      class="font-semibold link link-hover"
                    >
                      {service_name(@service_map, a.service_type_id)}
                    </.link>
                    <span class="text-base-content/40">·</span>
                    <span class="text-sm text-base-content/70">
                      {customer_name(@customer_map, a.customer_id)}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70 mt-1 flex items-center gap-1">
                    <span class="hero-clock w-4 h-4" aria-hidden="true"></span>
                    {fmt_when(a.scheduled_at)}
                    <span class="text-base-content/40 mx-1">·</span>
                    {a.vehicle_description}
                  </div>
                  <div class="text-xs text-base-content/60 truncate mt-1 flex items-center gap-1">
                    <span class="hero-map-pin w-3 h-3 shrink-0" aria-hidden="true"></span>
                    {a.service_address}
                  </div>
                </div>

                <div class="flex items-center gap-2">
                  <span class="font-semibold">{fmt_price(a.price_cents)}</span>
                  <button
                    phx-click="confirm_appointment"
                    phx-value-id={a.id}
                    class="btn btn-success btn-sm gap-1"
                  >
                    <span class="hero-check w-4 h-4" aria-hidden="true"></span> Confirm
                  </button>
                  <button
                    phx-click="cancel_appointment"
                    phx-value-id={a.id}
                    data-confirm="Cancel this appointment?"
                    class="btn btn-ghost btn-sm text-error"
                    aria-label="Cancel"
                  >
                    <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span>
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

  attr :href, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <a href={@href} class="btn btn-ghost btn-sm gap-1">
      <span class={"#{@icon} w-4 h-4"} aria-hidden="true"></span>
      {render_slot(@inner_block)}
    </a>
    """
  end
end
