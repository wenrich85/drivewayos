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

        {:noreply, load_tenants(socket)}

      _ ->
        {:noreply, socket}
    end
  end

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
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-5xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Tenants</h1>
            <p class="text-base-content/70 text-sm">
              {length(@tenants)} total · welcome, {@current_platform_user.name}
            </p>
          </div>
          <div class="flex gap-2">
            <a href="/metrics" class="btn btn-ghost btn-sm">Metrics</a>
            <a href="/auth/platform/sign-out" class="btn btn-ghost btn-sm">Sign out</a>
          </div>
        </div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <div :if={@tenants == []} class="text-center py-6 text-base-content/60">
              No tenants yet.
            </div>

            <div :if={@tenants != []} class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th>Slug</th>
                    <th>Name</th>
                    <th>Status</th>
                    <th>Stripe</th>
                    <th>Joined</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={t <- @tenants}>
                    <td class="font-mono text-sm">{to_string(t.slug)}</td>
                    <td class="font-semibold">{t.display_name}</td>
                    <td>
                      <span class={"badge badge-sm #{status_badge(t.status)}"}>
                        {t.status}
                      </span>
                    </td>
                    <td>
                      <span :if={t.stripe_account_id} class="badge badge-success badge-sm">
                        Connected
                      </span>
                      <span :if={is_nil(t.stripe_account_id)} class="badge badge-ghost badge-sm">
                        —
                      </span>
                    </td>
                    <td class="text-xs text-base-content/60">
                      {Calendar.strftime(t.inserted_at, "%b %-d, %Y")}
                    </td>
                    <td class="text-right space-x-1">
                      <a
                        :if={t.status != :archived}
                        href={"/platform/impersonate/#{t.id}"}
                        class="btn btn-ghost btn-xs"
                      >
                        Impersonate
                      </a>
                      <button
                        :if={t.status in [:active, :pending_onboarding]}
                        phx-click="suspend_tenant"
                        phx-value-id={t.id}
                        data-confirm={"Suspend #{t.display_name}?"}
                        class="btn btn-error btn-xs"
                      >
                        Suspend
                      </button>
                      <button
                        :if={t.status == :suspended}
                        phx-click="reactivate_tenant"
                        phx-value-id={t.id}
                        class="btn btn-success btn-xs"
                      >
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
