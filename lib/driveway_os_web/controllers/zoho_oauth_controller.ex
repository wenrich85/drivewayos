defmodule DrivewayOSWeb.ZohoOauthController do
  @moduledoc """
  Zoho Books OAuth endpoints. Mirrors `StripeOnboardingController`.

      GET /onboarding/zoho/start    — admin-only, redirects to Zoho OAuth
      GET /onboarding/zoho/callback — Zoho redirects here after auth

  The callback runs on the marketing host (where Zoho sends them
  back), not the tenant subdomain — we resolve which tenant via
  the state token.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Accounting.OAuth
  alias DrivewayOS.Onboarding.Affiliate
  alias DrivewayOS.Platform

  def start(conn, _params) do
    cond do
      is_nil(conn.assigns[:current_tenant]) ->
        conn |> redirect(to: ~p"/") |> halt()

      is_nil(conn.assigns[:current_customer]) ->
        conn |> redirect(to: ~p"/sign-in") |> halt()

      conn.assigns.current_customer.role != :admin ->
        conn |> redirect(to: ~p"/") |> halt()

      not OAuth.configured?() ->
        conn
        |> put_flash(
          :error,
          "Zoho Books isn't configured on this server yet. " <>
            "Ask the platform admin to set ZOHO_CLIENT_ID."
        )
        |> redirect(to: ~p"/admin")
        |> halt()

      true ->
        url =
          conn.assigns.current_tenant
          |> OAuth.oauth_url_for()
          |> Affiliate.tag_url(:zoho_books)

        :ok =
          Affiliate.log_event(
            conn.assigns.current_tenant,
            :zoho_books,
            :click,
            %{wizard_step: "accounting"}
          )

        redirect(conn, external: url)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, tenant_id} <- OAuth.verify_state(state),
         {:ok, tenant} <- Ash.get(Platform.Tenant, tenant_id, authorize?: false),
         {:ok, accounting_conn} <- OAuth.complete_onboarding(tenant, code) do
      :ok =
        Affiliate.log_event(
          tenant,
          :zoho_books,
          :provisioned,
          %{external_org_id: accounting_conn.external_org_id}
        )

      redirect(conn, external: tenant_integrations_url(tenant))
    else
      _ -> send_resp(conn, 400, "Zoho onboarding failed.")
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
