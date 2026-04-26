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
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-5xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Metrics</h1>
            <p class="text-base-content/70 text-sm">
              SaaS-wide rollup. Hello, {@current_platform_user.name}.
            </p>
          </div>
          <div class="flex gap-2">
            <a href="/tenants" class="btn btn-ghost btn-sm">Tenants</a>
            <a href="/auth/platform/sign-out" class="btn btn-ghost btn-sm">Sign out</a>
          </div>
        </div>

        <section class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Tenants</div>
            <div class="stat-value">{@tenant_count}</div>
            <div class="stat-desc">{@active_count} active · {@pending_onboarding_count} pending · {@suspended_count} suspended</div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Stripe-connected</div>
            <div class="stat-value text-info">{@connected_count}</div>
            <div class="stat-desc">of {@tenant_count} tenants</div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Paid bookings</div>
            <div class="stat-value">{@paid_appointments}</div>
            <div class="stat-desc">all time</div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">GMV</div>
            <div class="stat-value text-success">{fmt_cents(@gmv_cents)}</div>
            <div class="stat-desc">all paid bookings, all tenants</div>
          </div>
          <div class="stat bg-base-100 rounded-lg shadow">
            <div class="stat-title">Platform fee earned</div>
            <div class="stat-value text-primary">{fmt_cents(@platform_fee_cents)}</div>
            <div class="stat-desc">10% of GMV</div>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
