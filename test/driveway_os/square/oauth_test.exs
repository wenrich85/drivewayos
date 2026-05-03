defmodule DrivewayOS.Square.OAuthTest do
  @moduledoc """
  Pin the Square OAuth helper module: URL construction, state token
  consumption, code exchange. HTTP is Mox-stubbed via
  Square.Client.Mock.
  """
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Square.{Client, OAuth}
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PaymentConnection

  require Ash.Query

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "sqo-#{System.unique_integer([:positive])}",
        display_name: "Square OAuth Test",
        admin_email: "sqo-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  describe "configured?/0" do
    test "true when square_app_id is set" do
      assert OAuth.configured?()
    end

    test "false when square_app_id is empty/nil" do
      original = Application.get_env(:driveway_os, :square_app_id)
      Application.put_env(:driveway_os, :square_app_id, "")
      on_exit(fn -> Application.put_env(:driveway_os, :square_app_id, original) end)

      refute OAuth.configured?()
    end
  end

  describe "oauth_url_for/1" do
    test "builds the auth URL with state token bound to the tenant", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)

      assert url =~ "connect.squareup.com/oauth2/authorize"
      assert url =~ "client_id=test-square-app-id"
      assert url =~ "scope=PAYMENTS_WRITE+PAYMENTS_READ+MERCHANT_PROFILE_READ"
      assert url =~ "session=false"
      assert url =~ "state="

      [state_param] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, _} =
               DrivewayOS.Platform.OauthState
               |> Ash.Query.for_read(:by_token, %{token: state_param})
               |> Ash.read(authorize?: false)
    end
  end

  describe "verify_state/1" do
    test "consumes a valid state token (single-use)", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, tid} = OAuth.verify_state(token)
      assert tid == ctx.tenant.id
      assert {:error, :invalid_state} = OAuth.verify_state(token)
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_state} = OAuth.verify_state("nope")
    end

    test "rejects a state token with non-square purpose", ctx do
      {:ok, zoho_state} =
        DrivewayOS.Platform.OauthState
        |> Ash.Changeset.for_create(:issue, %{
          tenant_id: ctx.tenant.id,
          purpose: :zoho_books
        })
        |> Ash.create(authorize?: false)

      assert {:error, :invalid_state} = OAuth.verify_state(zoho_state.token)
    end
  end

  describe "complete_onboarding/2" do
    test "exchanges code, upserts PaymentConnection (first connect)", ctx do
      expect(Client.Mock, :exchange_oauth_code, fn code, _redirect_uri ->
        assert code == "auth-code-123"
        {:ok, %{
          access_token: "at-99",
          refresh_token: "rt-99",
          expires_in: 30 * 86_400,
          merchant_id: "MLR-99"
        }}
      end)

      assert {:ok, %PaymentConnection{} = conn} =
               OAuth.complete_onboarding(ctx.tenant, "auth-code-123")

      assert conn.tenant_id == ctx.tenant.id
      assert conn.provider == :square
      assert conn.access_token == "at-99"
      assert conn.refresh_token == "rt-99"
      assert conn.external_merchant_id == "MLR-99"
    end

    test "reconnect upserts the existing row, clears disconnected_at", ctx do
      # First connect
      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-1", refresh_token: "rt-1", expires_in: 86_400, merchant_id: "MLR-1"}}
      end)

      {:ok, conn1} = OAuth.complete_onboarding(ctx.tenant, "code-1")

      # Disconnect
      conn1
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update!(authorize?: false)

      # Reconnect
      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-2", refresh_token: "rt-2", expires_in: 86_400, merchant_id: "MLR-2"}}
      end)

      {:ok, conn2} = OAuth.complete_onboarding(ctx.tenant, "code-2")

      assert conn2.access_token == "at-2"
      assert conn2.external_merchant_id == "MLR-2"
      assert conn2.disconnected_at == nil
      assert conn2.auto_charge_enabled == true

      # Confirm only one row
      {:ok, all} = Ash.read(PaymentConnection, authorize?: false)
      assert Enum.count(all, &(&1.tenant_id == ctx.tenant.id)) == 1

      assert {:ok, _} =
               Platform.get_active_payment_connection(ctx.tenant.id, :square)
    end

    test "code-exchange failure returns error tuple, no row written", ctx do
      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:error, %{status: 400, body: %{"error" => "invalid_code"}}}
      end)

      assert {:error, %{status: 400}} =
               OAuth.complete_onboarding(ctx.tenant, "bad-code")

      assert {:error, :not_found} =
               Platform.get_payment_connection(ctx.tenant.id, :square)
    end
  end
end
