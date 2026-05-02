defmodule DrivewayOSWeb.Admin.IntegrationsLive do
  @moduledoc """
  Tenant admin → integrations page at `/admin/integrations`.

  Lists every AccountingConnection row for the current tenant with
  status badge + pause/resume/disconnect buttons. V1 only has Zoho
  Books rows; Phase 4 adds QuickBooks rows automatically once its
  provider lands.

  Auth: Customer with role `:admin` in the current tenant.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Platform.AccountingConnection

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
        {:ok, load_connections(socket)}
    end
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket) do
    {:ok, conn} = Ash.get(AccountingConnection, id, authorize?: false)
    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)
    {:noreply, load_connections(socket)}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    {:ok, conn} = Ash.get(AccountingConnection, id, authorize?: false)
    conn |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update!(authorize?: false)
    {:noreply, load_connections(socket)}
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    {:ok, conn} = Ash.get(AccountingConnection, id, authorize?: false)
    conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)
    {:noreply, load_connections(socket)}
  end

  defp load_connections(socket) do
    tenant_id = socket.assigns.current_tenant.id

    {:ok, connections} =
      AccountingConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    Phoenix.Component.assign(socket, :connections, connections)
  end

  defp status(%AccountingConnection{disconnected_at: dt}) when not is_nil(dt), do: "Disconnected"
  defp status(%AccountingConnection{auto_sync_enabled: false}), do: "Paused"
  defp status(%AccountingConnection{last_sync_error: err}) when is_binary(err), do: "Error"
  defp status(_), do: "Active"

  defp provider_label(:zoho_books), do: "Zoho Books"
  defp provider_label(p), do: p |> Atom.to_string() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold mb-4">Integrations</h1>

      <%= if @connections == [] do %>
        <div class="bg-base-200 rounded-lg p-8 text-center text-base-content/70">
          <p>No integrations connected yet.</p>
          <p class="text-sm mt-2">
            Connect from the dashboard checklist on
            <.link navigate={~p"/admin"} class="link link-primary">/admin</.link>.
          </p>
        </div>
      <% else %>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Provider</th>
                <th>Status</th>
                <th>Connected</th>
                <th>Last sync</th>
                <th>Last error</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for conn <- @connections do %>
                <tr>
                  <td>{provider_label(conn.provider)}</td>
                  <td>{status(conn)}</td>
                  <td>{conn.connected_at && Calendar.strftime(conn.connected_at, "%Y-%m-%d")}</td>
                  <td>{conn.last_sync_at && Calendar.strftime(conn.last_sync_at, "%Y-%m-%d %H:%M")}</td>
                  <td class="text-error text-sm">{conn.last_sync_error}</td>
                  <td class="flex gap-2">
                    <%= if conn.auto_sync_enabled do %>
                      <button phx-click="pause" phx-value-id={conn.id} class="btn btn-sm">
                        Pause
                      </button>
                    <% else %>
                      <%= if is_nil(conn.disconnected_at) do %>
                        <button
                          phx-click="resume"
                          phx-value-id={conn.id}
                          class="btn btn-sm btn-primary"
                        >
                          Resume
                        </button>
                      <% end %>
                    <% end %>
                    <button phx-click="disconnect" phx-value-id={conn.id} class="btn btn-sm btn-error">
                      Disconnect
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end
end
