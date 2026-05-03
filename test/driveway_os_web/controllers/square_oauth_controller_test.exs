defmodule DrivewayOSWeb.SquareOauthControllerTest do
  @moduledoc """
  Pin the Square OAuth controller's contract: start logs :click +
  redirects (with affiliate ref tag when configured), callback
  exchanges code + creates PaymentConnection + logs :provisioned,
  errors return 400.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Square.Client
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.TenantReferral

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sqc-#{System.unique_integer([:positive])}",
        display_name: "Square Controller Test",
        admin_email: "sqc-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)

    %{conn: conn, tenant: tenant, admin: admin}
  end

  describe "GET /onboarding/square/start" do
    test "redirects to Square OAuth and logs :click", ctx do
      conn = get(ctx.conn, "/onboarding/square/start")
      url = redirected_to(conn, 302)

      assert url =~ "connect.squareup.com/oauth2/authorize"
      assert url =~ "state="

      {:ok, all} = Ash.read(TenantReferral, authorize?: false)
      [event] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
      assert event.provider == :square
      assert event.event_type == :click
    end

    test "appends affiliate ref when SQUARE_AFFILIATE_REF_ID is set", ctx do
      original = Application.get_env(:driveway_os, :square_affiliate_ref_id)
      Application.put_env(:driveway_os, :square_affiliate_ref_id, "myref")
      on_exit(fn -> Application.put_env(:driveway_os, :square_affiliate_ref_id, original) end)

      conn = get(ctx.conn, "/onboarding/square/start")
      url = redirected_to(conn, 302)
      assert url =~ "ref=myref"
    end
  end

  describe "GET /onboarding/square/callback" do
    test "exchanges code, creates PaymentConnection, logs :provisioned", ctx do
      url = DrivewayOS.Square.OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok,
         %{
           access_token: "at-cb",
           refresh_token: "rt-cb",
           expires_in: 30 * 86_400,
           merchant_id: "MLR-CB"
         }}
      end)

      callback_conn =
        build_conn()
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/square/callback?code=auth-code&state=#{token}")

      assert redirected_to(callback_conn, 302) =~ "/admin/integrations"

      {:ok, conn_row} = Platform.get_payment_connection(ctx.tenant.id, :square)
      assert conn_row.access_token == "at-cb"
      assert conn_row.external_merchant_id == "MLR-CB"

      {:ok, all_events} = Ash.read(TenantReferral, authorize?: false)

      provisioned =
        Enum.filter(
          all_events,
          &(&1.tenant_id == ctx.tenant.id and &1.event_type == :provisioned)
        )

      assert [_] = provisioned
    end

    test "returns 400 on invalid state", _ctx do
      callback_conn =
        build_conn()
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/square/callback?code=x&state=not-a-real-token")

      assert response(callback_conn, 400) =~ "Square onboarding failed"
    end

    test "returns 400 on missing params", _ctx do
      callback_conn =
        build_conn()
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/square/callback")

      assert response(callback_conn, 400) =~ "Missing"
    end
  end

  # Helper — copied from zoho_oauth_controller_test.exs.
  # Adapts the JWT-cookie + put_host pattern so the conn lands on
  # the tenant subdomain with an authenticated admin session.
  defp sign_in_admin_for_tenant(conn, tenant, admin) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

    conn
    |> Plug.Test.init_test_session(%{customer_token: token})
    |> Map.put(:host, "#{tenant.slug}.lvh.me")
  end
end
