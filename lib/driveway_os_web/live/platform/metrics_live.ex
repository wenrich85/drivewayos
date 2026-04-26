defmodule DrivewayOSWeb.Platform.MetricsLive do
  @moduledoc """
  Platform admin → cross-tenant SaaS metrics at admin.lvh.me/metrics.

  Aggregate snapshots only; per-tenant detail lives at /tenants.
  Reads the appointments table via raw Repo.aggregate so we don't
  need to thread `tenant:` through Ash for a cross-tenant rollup.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadPlatformUserHook

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Repo

  import Ecto.Query

  # Same fee basis points as BookingLive — keep in sync.
  @application_fee_bps 1000

  @impl true
  def mount(_params, _session, socket) do
    cond do
      socket.assigns[:tenant_context] != :platform_admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_platform_user]) ->
        {:ok, push_navigate(socket, to: ~p"/platform-sign-in")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Metrics")
         |> load_metrics()}
    end
  end

  defp load_metrics(socket) do
    tenants =
      Tenant
      |> Repo.all()

    by_status = Enum.frequencies_by(tenants, & &1.status)

    connected = Enum.count(tenants, & &1.stripe_account_id)

    gmv_cents =
      Repo.one(
        from a in "appointments",
          where: a.payment_status == "paid",
          select: type(coalesce(sum(a.price_cents), 0), :integer)
      ) || 0

    paid_count =
      Repo.one(
        from a in "appointments",
          where: a.payment_status == "paid",
          select: count("*")
      ) || 0

    fee_cents = div(gmv_cents * @application_fee_bps, 10_000)

    socket
    |> assign(:tenant_count, length(tenants))
    |> assign(:active_count, Map.get(by_status, :active, 0))
    |> assign(:pending_onboarding_count, Map.get(by_status, :pending_onboarding, 0))
    |> assign(:suspended_count, Map.get(by_status, :suspended, 0))
    |> assign(:archived_count, Map.get(by_status, :archived, 0))
    |> assign(:connected_count, connected)
    |> assign(:gmv_cents, gmv_cents)
    |> assign(:platform_fee_cents, fee_cents)
    |> assign(:paid_appointments, paid_count)
  end

  defp fmt_cents(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-6xl mx-auto space-y-6">
        <header class="flex justify-between items-start flex-wrap gap-3">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Platform
            </p>
            <h1 class="text-3xl font-bold tracking-tight">Metrics</h1>
            <p class="text-sm text-base-content/70 mt-1">
              SaaS-wide rollup · welcome, {@current_platform_user.name}
            </p>
          </div>
          <nav class="flex gap-1 flex-wrap">
            <a href="/tenants" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-building-office-2 w-4 h-4" aria-hidden="true"></span> Tenants
            </a>
            <a href="/metrics" class="btn btn-primary btn-sm gap-1">
              <span class="hero-chart-bar w-4 h-4" aria-hidden="true"></span> Metrics
            </a>
            <a href="/auth/platform/sign-out" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-arrow-left-on-rectangle w-4 h-4" aria-hidden="true"></span>
              Sign out
            </a>
          </nav>
        </header>

        <section class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Tenants
            </div>
            <div class="stat-value text-3xl font-bold">{@tenant_count}</div>
            <div class="stat-desc text-xs text-base-content/60">
              {@active_count} active · {@pending_onboarding_count} pending · {@suspended_count} suspended
            </div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Stripe-connected
            </div>
            <div class="stat-value text-3xl font-bold text-info">{@connected_count}</div>
            <div class="stat-desc text-xs text-base-content/60">of {@tenant_count} tenants</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Paid bookings
            </div>
            <div class="stat-value text-3xl font-bold">{@paid_appointments}</div>
            <div class="stat-desc text-xs text-base-content/60">all time</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              GMV
            </div>
            <div class="stat-value text-3xl font-bold text-success">{fmt_cents(@gmv_cents)}</div>
            <div class="stat-desc text-xs text-base-content/60">all paid bookings, all tenants</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300 md:col-span-2">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Platform fee earned
            </div>
            <div class="stat-value text-3xl font-bold text-primary">
              {fmt_cents(@platform_fee_cents)}
            </div>
            <div class="stat-desc text-xs text-base-content/60">10% of GMV</div>
          </article>
        </section>
      </div>
    </main>
    """
  end
end
