defmodule DrivewayOSWeb.Admin.IntegrationsLive do
  @moduledoc """
  Tenant admin → integrations page at `/admin/integrations`.

  Lists every connection row for the current tenant — both
  AccountingConnection (Phase 3) and PaymentConnection (Phase 4) —
  in a unified table on desktop and a card-per-row stack on mobile.
  Pause / Resume / Disconnect buttons per row dispatch to the
  resource module identified by the row's `resource` field.

  Phase 4 also aligns borders to MASTER design system
  (`border-slate-200`), adds `min-h-[44px]` touch targets to action
  buttons, `aria-label` to disambiguate same-text buttons across
  rows, and `aria-live="polite"` on the table for screen-reader
  announcement of status changes after pause/resume/disconnect.

  Auth: Customer with role `:admin` in the current tenant.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Platform.{AccountingConnection, PaymentConnection}

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
        {:ok, load_rows(socket)}
    end
  end

  @impl true
  def handle_event("pause", %{"resource" => resource, "id" => id}, socket) do
    with_owned_connection(socket, resource_module(resource), id, fn conn ->
      Ash.Changeset.for_update(conn, :pause, %{})
    end)
  end

  def handle_event("resume", %{"resource" => resource, "id" => id}, socket) do
    with_owned_connection(socket, resource_module(resource), id, fn conn ->
      Ash.Changeset.for_update(conn, :resume, %{})
    end)
  end

  def handle_event("disconnect", %{"resource" => resource, "id" => id}, socket) do
    with_owned_connection(socket, resource_module(resource), id, fn conn ->
      Ash.Changeset.for_update(conn, :disconnect, %{})
    end)
  end

  defp resource_module("payment"), do: PaymentConnection
  defp resource_module("accounting"), do: AccountingConnection

  defp with_owned_connection(socket, resource, id, changeset_fn) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{tenant_id: ^tenant_id} = conn} ->
        conn |> changeset_fn.() |> Ash.update!(authorize?: false)
        {:noreply, load_rows(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp load_rows(socket) do
    tenant_id = socket.assigns.current_tenant.id

    {:ok, accounting_conns} =
      AccountingConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, payment_conns} =
      PaymentConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    rows =
      Enum.map(accounting_conns, &row_from_accounting/1) ++
        Enum.map(payment_conns, &row_from_payment/1)

    Phoenix.Component.assign(socket, :rows, rows)
  end

  defp row_from_accounting(%AccountingConnection{} = c) do
    %{
      id: c.id,
      resource: "accounting",
      provider: c.provider,
      category: "Accounting",
      status: status_text(c, :sync),
      connected_at: c.connected_at,
      last_activity_at: c.last_sync_at,
      last_error: c.last_sync_error,
      auto_enabled: c.auto_sync_enabled,
      disconnected_at: c.disconnected_at
    }
  end

  defp row_from_payment(%PaymentConnection{} = c) do
    %{
      id: c.id,
      resource: "payment",
      provider: c.provider,
      category: "Payment",
      status: status_text(c, :charge),
      connected_at: c.connected_at,
      last_activity_at: c.last_charge_at,
      last_error: c.last_charge_error,
      auto_enabled: c.auto_charge_enabled,
      disconnected_at: c.disconnected_at
    }
  end

  defp status_text(%{disconnected_at: dt}, _) when not is_nil(dt), do: "Disconnected"
  defp status_text(%AccountingConnection{auto_sync_enabled: false}, _), do: "Paused"
  defp status_text(%PaymentConnection{auto_charge_enabled: false}, _), do: "Paused"
  defp status_text(%{last_sync_error: err}, _) when is_binary(err), do: "Error"
  defp status_text(%{last_charge_error: err}, _) when is_binary(err), do: "Error"
  defp status_text(_, _), do: "Active"

  defp status_badge_class("Active"), do: "badge badge-success"
  defp status_badge_class("Paused"), do: "badge badge-warning"
  defp status_badge_class("Disconnected"), do: "badge badge-ghost"
  defp status_badge_class("Error"), do: "badge badge-error"
  defp status_badge_class(_), do: "badge"

  defp provider_label(:zoho_books), do: "Zoho Books"
  defp provider_label(:square), do: "Square"
  defp provider_label(p), do: p |> Atom.to_string() |> String.capitalize()

  defp format_date(nil), do: ""
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-slate-900 mb-4">Integrations</h1>

      <%= if @rows == [] do %>
        <div class="bg-slate-50 rounded-lg p-8 text-center text-slate-600">
          <p>No integrations connected yet.</p>
          <p class="text-sm mt-2">
            Connect from the dashboard checklist on
            <.link navigate={~p"/admin"} class="link link-primary">/admin</.link>.
          </p>
        </div>
      <% else %>
        <div class="hidden md:block overflow-x-auto" aria-live="polite">
          <table class="table">
            <thead>
              <tr>
                <th scope="col">Provider</th>
                <th scope="col">Category</th>
                <th scope="col">Status</th>
                <th scope="col">Connected</th>
                <th scope="col">Last activity</th>
                <th scope="col">Last error</th>
                <th scope="col">Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for row <- @rows do %>
                <tr>
                  <td class="font-medium">{provider_label(row.provider)}</td>
                  <td class="text-slate-600">{row.category}</td>
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td class="text-sm text-slate-600">{format_date(row.connected_at)}</td>
                  <td class="text-sm text-slate-600">{format_datetime(row.last_activity_at)}</td>
                  <td class="text-sm text-error truncate max-w-xs">{row.last_error}</td>
                  <td>
                    <.action_buttons row={row} context="table" />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <div class="md:hidden space-y-3" aria-live="polite">
          <%= for row <- @rows do %>
            <div class="card bg-base-100 shadow-md border border-slate-200">
              <div class="card-body p-4 space-y-2">
                <div class="flex justify-between items-start gap-2">
                  <div>
                    <h3 class="font-semibold text-slate-900">{provider_label(row.provider)}</h3>
                    <p class="text-xs text-slate-600">{row.category}</p>
                  </div>
                  <span class={status_badge_class(row.status)}>{row.status}</span>
                </div>
                <div class="text-xs text-slate-600">
                  Connected {format_date(row.connected_at)}
                  <%= if row.last_activity_at do %>
                    · Last activity {format_datetime(row.last_activity_at)}
                  <% end %>
                </div>
                <p :if={row.last_error} class="text-xs text-error">{row.last_error}</p>
                <div class="flex gap-2 flex-wrap pt-2">
                  <.action_buttons row={row} context="card" />
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :context, :string, required: true

  defp action_buttons(assigns) do
    ~H"""
    <%= if @row.auto_enabled do %>
      <button
        id={"#{@context}-pause-#{@row.id}"}
        phx-click="pause"
        phx-value-resource={@row.resource}
        phx-value-id={@row.id}
        class="btn btn-sm min-h-[44px]"
        aria-label={"Pause #{provider_label(@row.provider)} integration"}
      >Pause</button>
    <% else %>
      <%= if is_nil(@row.disconnected_at) do %>
        <button
          id={"#{@context}-resume-#{@row.id}"}
          phx-click="resume"
          phx-value-resource={@row.resource}
          phx-value-id={@row.id}
          class="btn btn-sm btn-primary min-h-[44px]"
          aria-label={"Resume #{provider_label(@row.provider)} integration"}
        >Resume</button>
      <% end %>
    <% end %>
    <%= if is_nil(@row.disconnected_at) do %>
      <button
        id={"#{@context}-disconnect-#{@row.id}"}
        phx-click="disconnect"
        phx-value-resource={@row.resource}
        phx-value-id={@row.id}
        class="btn btn-sm btn-error min-h-[44px]"
        aria-label={"Disconnect #{provider_label(@row.provider)} integration"}
      >Disconnect</button>
    <% end %>
    """
  end
end
