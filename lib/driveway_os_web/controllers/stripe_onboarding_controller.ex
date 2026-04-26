defmodule DrivewayOSWeb.StripeOnboardingController do
  @moduledoc """
  Stripe Connect onboarding endpoints.

      GET /onboarding/stripe/start    — admin-only, redirects to Stripe OAuth
      GET /onboarding/stripe/callback — Stripe redirects here after auth

  The callback runs on the marketing host (where Stripe sends them
  back), not the tenant subdomain — we resolve which tenant this is
  for by consuming the `state` token.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Billing.StripeConnect
  alias DrivewayOS.Platform

  def start(conn, _params) do
    cond do
      is_nil(conn.assigns[:current_tenant]) ->
        conn |> redirect(to: ~p"/") |> halt()

      is_nil(conn.assigns[:current_customer]) ->
        conn |> redirect(to: ~p"/sign-in") |> halt()

      conn.assigns.current_customer.role != :admin ->
        conn |> redirect(to: ~p"/") |> halt()

      true ->
        url = StripeConnect.oauth_url_for(conn.assigns.current_tenant)
        redirect(conn, external: url)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, tenant_id} <- StripeConnect.verify_state(state),
         tenant when not is_nil(tenant) <- Ash.get!(Platform.Tenant, tenant_id),
         {:ok, updated} <- StripeConnect.complete_onboarding(tenant, code) do
      redirect(conn, external: tenant_admin_url(updated))
    else
      _ -> send_resp(conn, 400, "Stripe onboarding failed.")
    end
  end

  def callback(conn, _params), do: send_resp(conn, 400, "Missing code/state.")

  # --- Helpers ---

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
