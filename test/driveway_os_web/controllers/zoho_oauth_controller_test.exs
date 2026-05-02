defmodule DrivewayOSWeb.ZohoOauthControllerTest do
  @moduledoc """
  Pin the Zoho OAuth controller's contract: start logs :click +
  redirects (with affiliate ref tag when configured), callback
  exchanges code + creates AccountingConnection + logs :provisioned,
  errors return 400.

  Mirrors `stripe_onboarding_controller_test.exs` setup pattern —
  JWT-tokened admin session on the tenant subdomain.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.TenantReferral

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "zo-#{System.unique_integer([:positive])}",
        display_name: "Zoho Controller Test",
        admin_email: "zo-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)

    %{conn: conn, tenant: tenant, admin: admin}
  end

  describe "GET /onboarding/zoho/start" do
    test "redirects to Zoho OAuth and logs :click", ctx do
      conn = get(ctx.conn, "/onboarding/zoho/start")

      url = redirected_to(conn, 302)
      assert url =~ "accounts.zoho.com/oauth/v2/auth"
      assert url =~ "state="

      {:ok, all} = Ash.read(TenantReferral, authorize?: false)
      [event] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
      assert event.provider == :zoho_books
      assert event.event_type == :click
    end

    test "appends affiliate ref when ZOHO_AFFILIATE_REF_ID is set", ctx do
      original = Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
      Application.put_env(:driveway_os, :zoho_affiliate_ref_id, "myref")
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_affiliate_ref_id, original) end)

      conn = get(ctx.conn, "/onboarding/zoho/start")
      url = redirected_to(conn, 302)
      assert url =~ "ref=myref"
    end
  end

  describe "GET /onboarding/zoho/callback" do
    test "exchanges code, creates AccountingConnection, logs :provisioned, redirects to /admin/integrations",
         ctx do
      # Issue a state token via OAuth.oauth_url_for/1 first to get a
      # valid token paired with this tenant.
      url = DrivewayOS.Accounting.OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-cb", refresh_token: "rt-cb", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "12345"}]}}
      end)

      # Callback runs on the marketing host (no tenant subdomain).
      callback_conn =
        build_conn()
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/zoho/callback?code=auth-code&state=#{token}")

      assert redirected_to(callback_conn, 302) =~ "/admin/integrations"

      {:ok, conn_row} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
      assert conn_row.access_token == "at-cb"
      assert conn_row.external_org_id == "12345"

      {:ok, all_events} = Ash.read(TenantReferral, authorize?: false)

      provisioned =
        all_events
        |> Enum.filter(&(&1.tenant_id == ctx.tenant.id and &1.event_type == :provisioned))

      assert [_event] = provisioned
    end

    test "returns 400 on invalid state", _ctx do
      callback_conn =
        build_conn()
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/zoho/callback?code=x&state=not-a-real-token")

      assert response(callback_conn, 400) =~ "Zoho onboarding failed"
    end

    test "returns 400 on missing params", _ctx do
      callback_conn =
        build_conn()
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/zoho/callback")

      assert response(callback_conn, 400) =~ "Missing"
    end
  end

  # Helper — copied from stripe_onboarding_controller_test.exs.
  # Adapts the JWT-cookie + put_host pattern so the conn lands on
  # the tenant subdomain with an authenticated admin session.
  defp sign_in_admin_for_tenant(conn, tenant, admin) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

    conn
    |> Plug.Test.init_test_session(%{customer_token: token})
    |> Map.put(:host, "#{tenant.slug}.lvh.me")
  end
end
