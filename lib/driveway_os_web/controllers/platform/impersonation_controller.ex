defmodule DrivewayOSWeb.Platform.ImpersonationController do
  @moduledoc """
  Lets a signed-in PlatformUser impersonate a tenant by minting a
  customer JWT for that tenant's first admin Customer + flagging
  the session as impersonated.

  Audit-logged via Logger (V1). V2 adds an immutable AuditLog
  resource so we have a queryable record of every impersonation.

  Auth: only PlatformUsers signed in on `admin.<platform_host>`
  can hit this. The 403/redirect dance below makes both invariants
  load-bearing.
  """
  use DrivewayOSWeb, :controller

  require Ash.Query
  require Logger

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  def start(conn, %{"id" => tenant_id}) do
    cond do
      conn.assigns[:tenant_context] != :platform_admin ->
        conn |> send_resp(403, "Not allowed.") |> halt()

      is_nil(conn.assigns[:current_platform_user]) ->
        conn |> redirect(to: ~p"/platform-sign-in") |> halt()

      true ->
        do_start(conn, tenant_id)
    end
  end

  defp do_start(conn, tenant_id) do
    with {:ok, tenant} <- Ash.get(Tenant, tenant_id, authorize?: false),
         {:ok, target_admin} <- find_admin(tenant),
         {:ok, token, _} <- AshAuthentication.Jwt.token_for_user(target_admin) do
      Logger.info(
        "[impersonation start] platform_user=#{conn.assigns.current_platform_user.id} " <>
          "tenant=#{tenant.slug} target_customer=#{target_admin.id}"
      )

      :ok =
        Platform.log_audit!(%{
          action: :tenant_impersonated,
          tenant_id: tenant.id,
          platform_user_id: conn.assigns.current_platform_user.id,
          target_type: "Customer",
          target_id: target_admin.id,
          payload: %{"target_customer_email" => to_string(target_admin.email)}
        })

      conn
      |> put_session(:customer_token, token)
      |> put_session(:impersonated_by, conn.assigns.current_platform_user.id)
      |> redirect(external: tenant_admin_url(tenant))
    else
      _ -> send_resp(conn, 404, "Tenant not found.")
    end
  end

  defp find_admin(tenant) do
    case Customer
         |> Ash.Query.filter(role == :admin)
         |> Ash.Query.set_tenant(tenant.id)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [admin | _]} -> {:ok, admin}
      _ -> :error
    end
  end

  defp tenant_admin_url(tenant) do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        {"http", ":#{endpoint_port() || 4000}"}
      else
        {"https", ""}
      end

    "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}/admin"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
