defmodule DrivewayOSWeb.StripeOnboardingControllerTest do
  @moduledoc """
  /onboarding/stripe/start  — admin signs in, clicks "Connect Stripe",
                              we redirect them to Stripe's OAuth page
  /onboarding/stripe/callback — Stripe sends them back; we exchange
                                code, store stripe_account_id, redirect
                                to /admin

  Auth: only authenticated tenant admins can hit /start. The
  /callback endpoint takes a state token (not a session) so it
  works on the marketing host where the admin's tenant session
  doesn't exist.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sob-#{System.unique_integer([:positive])}",
        display_name: "Stripe Onboarding Shop",
        admin_email: "owner-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  describe "GET /onboarding/stripe/start" do
    test "admin gets redirected to Stripe", %{conn: conn, tenant: tenant, admin: admin} do
      {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

      conn =
        conn
        |> Plug.Test.init_test_session(%{customer_token: token})
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> get("/onboarding/stripe/start")

      assert redirected_to(conn, 302) =~ "https://connect.stripe.com/oauth/authorize"
    end

    test "stripe client_id unset: bounces back to /admin with a clear flash",
         %{conn: conn, tenant: tenant, admin: admin} do
      # Temporarily blank the client_id so configured?/0 returns false.
      original = Application.get_env(:driveway_os, :stripe_client_id)
      Application.put_env(:driveway_os, :stripe_client_id, "")
      on_exit(fn -> Application.put_env(:driveway_os, :stripe_client_id, original) end)

      {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

      conn =
        conn
        |> Plug.Test.init_test_session(%{customer_token: token})
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> get("/onboarding/stripe/start")

      assert redirected_to(conn, 302) == "/admin"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Stripe Connect isn't configured"
    end

    test "non-admin customer is bounced", %{conn: conn, tenant: tenant} do
      {:ok, customer} =
        DrivewayOS.Accounts.Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "non-admin-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Non Admin"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)

      conn =
        conn
        |> Plug.Test.init_test_session(%{customer_token: token})
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> get("/onboarding/stripe/start")

      assert redirected_to(conn, 302) == "/"
    end
  end

  describe "GET /onboarding/stripe/callback" do
    test "valid state + code: stores account_id + redirects to admin",
         %{conn: conn, tenant: tenant} do
      # Mint a real state token by calling oauth_url_for
      [_, state_token] =
        Regex.run(
          ~r/state=([^&]+)/,
          DrivewayOS.Billing.StripeConnect.oauth_url_for(tenant)
        )

      DrivewayOS.Billing.StripeClientMock
      |> expect(:exchange_oauth_code, fn "stripe-code" ->
        {:ok, %{stripe_user_id: "acct_123callback"}}
      end)

      conn =
        conn
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/stripe/callback?code=stripe-code&state=#{state_token}")

      # Lands on the tenant's admin dashboard.
      assert redirected_to(conn, 302) =~ "#{tenant.slug}.lvh.me"
      assert redirected_to(conn, 302) =~ "/admin"

      # Tenant got the account id.
      reloaded = Platform.get_tenant_by_slug!(tenant.slug)
      assert reloaded.stripe_account_id == "acct_123callback"
    end

    test "bogus state → 400", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, "lvh.me")
        |> get("/onboarding/stripe/callback?code=stripe-code&state=garbage")

      assert conn.status == 400
    end
  end
end
