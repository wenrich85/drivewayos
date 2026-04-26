defmodule DrivewayOSWeb.Platform.TenantsLive do
  @moduledoc """
  Platform admin → list of every tenant on DrivewayOS at
  admin.lvh.me/tenants. Lets the operator suspend / reactivate
  tenants.

  Reads are unscoped (Tenant is the anchor — not tenant-scoped)
  so this is the rare LV that legitimately doesn't pass `tenant:`.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadPlatformUserHook

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  require Ash.Query

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
         |> assign(:page_title, "Tenants")
         |> load_tenants()}
    end
  end

  @impl true
  def handle_event("suspend_tenant", %{"id" => id}, socket) do
    update_tenant(socket, id, :suspend)
  end

  def handle_event("reactivate_tenant", %{"id" => id}, socket) do
    update_tenant(socket, id, :reactivate)
  end

  defp update_tenant(socket, id, action) do
    case Ash.get(Tenant, id, authorize?: false) do
      {:ok, tenant} ->
        tenant
        |> Ash.Changeset.for_update(action, %{})
        |> Ash.update!(authorize?: false)

        Platform.log_audit!(%{
          action: audit_action_for(action),
          tenant_id: tenant.id,
          platform_user_id: socket.assigns.current_platform_user.id,
          target_type: "Tenant",
          target_id: tenant.id,
          payload: %{"slug" => to_string(tenant.slug)}
        })

        {:noreply, load_tenants(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp audit_action_for(:suspend), do: :tenant_suspended
  defp audit_action_for(:reactivate), do: :tenant_reactivated
  defp audit_action_for(:archive), do: :tenant_archived
  defp audit_action_for(_), do: :tenant_suspended

  defp load_tenants(socket) do
    tenants =
      Tenant
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)

    assign(socket, :tenants, tenants)
  end

  defp status_badge(:active), do: "badge-success"
  defp status_badge(:pending_onboarding), do: "badge-warning"
  defp status_badge(:suspended), do: "badge-error"
  defp status_badge(:archived), do: "badge-ghost"

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
            <h1 class="text-3xl font-bold tracking-tight">Tenants</h1>
            <p class="text-sm text-base-content/70 mt-1">
              {length(@tenants)} total · welcome, {@current_platform_user.name}
            </p>
          </div>
          <nav class="flex gap-1 flex-wrap">
            <a href="/tenants" class="btn btn-primary btn-sm gap-1">
              <span class="hero-building-office-2 w-4 h-4" aria-hidden="true"></span> Tenants
            </a>
            <a href="/metrics" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-chart-bar w-4 h-4" aria-hidden="true"></span> Metrics
            </a>
            <a href="/auth/platform/sign-out" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-arrow-left-on-rectangle w-4 h-4" aria-hidden="true"></span>
              Sign out
            </a>
          </nav>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div :if={@tenants == []} class="text-center py-12 px-4">
              <span
                class="hero-building-office-2 w-12 h-12 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60">No tenants yet.</p>
            </div>

            <div :if={@tenants != []} class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Slug</th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Name</th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Status</th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Stripe</th>
                    <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Joined</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={t <- @tenants} class="hover:bg-base-200/50">
                    <td class="font-mono text-sm">{to_string(t.slug)}</td>
                    <td class="font-semibold">{t.display_name}</td>
                    <td>
                      <span class={"badge badge-sm " <> status_badge(t.status)}>{t.status}</span>
                    </td>
                    <td>
                      <span :if={t.stripe_account_id} class="badge badge-success badge-sm gap-1">
                        <span class="hero-check w-3 h-3" aria-hidden="true"></span> Connected
                      </span>
                      <span :if={is_nil(t.stripe_account_id)} class="badge badge-ghost badge-sm">—</span>
                    </td>
                    <td class="text-xs text-base-content/60">
                      {Calendar.strftime(t.inserted_at, "%b %-d, %Y")}
                    </td>
                    <td class="text-right space-x-1 whitespace-nowrap">
                      <a
                        :if={t.status != :archived}
                        href={"/platform/impersonate/#{t.id}"}
                        class="btn btn-ghost btn-xs gap-1"
                        title="Sign in as this tenant's admin"
                      >
                        <span class="hero-finger-print w-3 h-3" aria-hidden="true"></span>
                        Impersonate
                      </a>
                      <button
                        :if={t.status in [:active, :pending_onboarding]}
                        phx-click="suspend_tenant"
                        phx-value-id={t.id}
                        data-confirm={"Suspend #{t.display_name}?"}
                        class="btn btn-error btn-xs gap-1"
                      >
                        <span class="hero-pause w-3 h-3" aria-hidden="true"></span>
                        Suspend
                      </button>
                      <button
                        :if={t.status == :suspended}
                        phx-click="reactivate_tenant"
                        phx-value-id={t.id}
                        class="btn btn-success btn-xs gap-1"
                      >
                        <span class="hero-play w-3 h-3" aria-hidden="true"></span>
                        Reactivate
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
