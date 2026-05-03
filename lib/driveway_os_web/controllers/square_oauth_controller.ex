defmodule DrivewayOSWeb.SquareOauthController do
  @moduledoc """
  Square OAuth endpoints. Mirrors `ZohoOauthController`.

      GET /onboarding/square/start    — admin-only, redirects to Square OAuth
      GET /onboarding/square/callback — Square redirects here after auth

  Callback runs on the marketing host. We resolve which tenant via
  the state token.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Square.OAuth
  alias DrivewayOS.Onboarding.Affiliate
  alias DrivewayOS.Platform

  plug DrivewayOSWeb.Plugs.RequireAdminCustomer when action in [:start]

  def start(conn, _params) do
    cond do
      not OAuth.configured?() ->
        conn
        |> put_flash(
          :error,
          "Square isn't configured on this server yet. " <>
            "Ask the platform admin to set SQUARE_APP_ID."
        )
        |> redirect(to: ~p"/admin")
        |> halt()

      true ->
        url =
          conn.assigns.current_tenant
          |> OAuth.oauth_url_for()
          |> Affiliate.tag_url(:square)

        :ok =
          Affiliate.log_event(
            conn.assigns.current_tenant,
            :square,
            :click,
            %{wizard_step: "payment"}
          )

        redirect(conn, external: url)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, tenant_id} <- OAuth.verify_state(state),
         {:ok, tenant} <- Ash.get(Platform.Tenant, tenant_id, authorize?: false),
         {:ok, payment_conn} <- OAuth.complete_onboarding(tenant, code) do
      :ok =
        Affiliate.log_event(
          tenant,
          :square,
          :provisioned,
          %{external_merchant_id: payment_conn.external_merchant_id}
        )

      redirect(conn, external: tenant_integrations_url(tenant))
    else
      _ -> send_resp(conn, 400, "Square onboarding failed.")
    end
  end

  def callback(conn, _params), do: send_resp(conn, 400, "Missing code/state.")

  # --- Helpers ---

  defp tenant_integrations_url(tenant) do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        port = endpoint_port() || 4000
        {"http", ":#{port}"}
      else
        {"https", ""}
      end

    "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}/admin/integrations"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
