defmodule DrivewayOSWeb.LoadTenantHook do
  @moduledoc """
  LiveView `on_mount` hook that mirrors the `LoadTenant` plug into
  the LV socket.

  Reads `tenant_id` from session (stamped by the plug), loads the
  tenant, assigns it to the socket. Sets `tenant_context` from the
  presence/absence of a tenant. Halts with a 404-equivalent
  `push_navigate` to the marketing site if the session points at an
  archived tenant (defensive — the plug already 404s archived
  subdomains, but a stale session shouldn't escalate).

  Public marketing LiveViews don't use this hook — they're fine
  with `current_tenant = nil`.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias DrivewayOS.Platform

  def on_mount(:default, _params, session, socket) do
    case Map.get(session, "tenant_id") do
      nil ->
        {:cont,
         socket
         |> assign(:current_tenant, nil)
         |> assign(:tenant_context, :marketing)}

      id ->
        case Ash.get(Platform.Tenant, id, authorize?: false) do
          {:ok, %{status: :archived}} ->
            {:halt, redirect(socket, external: external_marketing_url())}

          {:ok, tenant} ->
            {:cont,
             socket
             |> assign(:current_tenant, tenant)
             |> assign(:tenant_context, :tenant)}

          _ ->
            {:halt, redirect(socket, external: external_marketing_url())}
        end
    end
  end

  defp external_marketing_url do
    "https://" <> Application.get_env(:driveway_os, :platform_host, "drivewayos.com")
  end
end
