defmodule DrivewayOS.Accounting.OAuthTest do
  @moduledoc """
  Pin the Zoho OAuth helper module: URL construction, state token
  consumption, code exchange. HTTP is Mox-stubbed.
  """
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Accounting.{OAuth, ZohoClient}
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  require Ash.Query

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "oa-#{System.unique_integer([:positive])}",
        display_name: "OAuth Test",
        admin_email: "oa-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  describe "configured?/0" do
    test "true when zoho_client_id is set" do
      assert OAuth.configured?()
    end

    test "false when zoho_client_id is empty/nil" do
      original = Application.get_env(:driveway_os, :zoho_client_id)
      Application.put_env(:driveway_os, :zoho_client_id, "")
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_client_id, original) end)

      refute OAuth.configured?()
    end
  end

  describe "oauth_url_for/1" do
    test "builds the auth URL with state token bound to the tenant", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)

      assert url =~ "accounts.zoho.com/oauth/v2/auth"
      assert url =~ "client_id=test-zoho-client-id"
      assert url =~ "scope=ZohoBooks.fullaccess.all"
      assert url =~ "access_type=offline"
      assert url =~ "state="

      # State token persisted with :zoho_books purpose
      [state_param] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, _} =
               DrivewayOS.Platform.OauthState
               |> Ash.Query.for_read(:by_token, %{token: state_param})
               |> Ash.read(authorize?: false)
    end
  end

  describe "verify_state/1" do
    test "consumes a valid state token and returns the tenant_id", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, tid} = OAuth.verify_state(token)
      assert tid == ctx.tenant.id

      # Single-use: a second verify fails
      assert {:error, :invalid_state} = OAuth.verify_state(token)
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_state} = OAuth.verify_state("nope-not-a-real-token")
    end
  end

  describe "complete_onboarding/2" do
    test "exchanges code, probes orgs, upserts AccountingConnection", ctx do
      expect(ZohoClient.Mock, :exchange_oauth_code, fn code, _redirect_uri ->
        assert code == "auth-code-123"
        {:ok, %{access_token: "at-99", refresh_token: "rt-99", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _at, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "999"}]}}
      end)

      assert {:ok, %AccountingConnection{} = conn} =
               OAuth.complete_onboarding(ctx.tenant, "auth-code-123")

      assert conn.tenant_id == ctx.tenant.id
      assert conn.provider == :zoho_books
      assert conn.access_token == "at-99"
      assert conn.refresh_token == "rt-99"
      assert conn.external_org_id == "999"
    end

    test "reconnect upserts the existing row instead of creating a duplicate", ctx do
      # First connect
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-1", refresh_token: "rt-1", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "999"}]}}
      end)

      {:ok, _} = OAuth.complete_onboarding(ctx.tenant, "code-1")

      # Reconnect — fresh tokens, same row.
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-2", refresh_token: "rt-2", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "999"}]}}
      end)

      {:ok, conn2} = OAuth.complete_onboarding(ctx.tenant, "code-2")
      assert conn2.access_token == "at-2"
      assert conn2.refresh_token == "rt-2"

      # Confirm only one row exists.
      {:ok, all} = Ash.read(AccountingConnection, authorize?: false)
      assert Enum.count(all, &(&1.tenant_id == ctx.tenant.id)) == 1
    end

    test "disconnect → reconnect clears disconnected_at and restores active state", ctx do
      # First connect
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-1", refresh_token: "rt-1", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "999"}]}}
      end)

      {:ok, conn1} = OAuth.complete_onboarding(ctx.tenant, "code-1")

      # Disconnect
      {:ok, disconnected} =
        conn1 |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update(authorize?: false)

      assert %DateTime{} = disconnected.disconnected_at

      # Reconnect — possibly to a different org
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-2", refresh_token: "rt-2", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "different-456"}]}}
      end)

      {:ok, conn2} = OAuth.complete_onboarding(ctx.tenant, "code-2")

      # All three reconnect-fix invariants:
      assert conn2.disconnected_at == nil
      assert conn2.auto_sync_enabled == true
      assert conn2.external_org_id == "different-456"
      assert conn2.access_token == "at-2"

      # And get_active_accounting_connection/2 should now succeed —
      # this is the silent-failure path that motivated the fix.
      assert {:ok, _} =
               DrivewayOS.Platform.get_active_accounting_connection(ctx.tenant.id, :zoho_books)
    end

    test "code-exchange failure returns error tuple, no row written", ctx do
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:error, %{status: 400, body: %{"error" => "invalid_code"}}}
      end)

      assert {:error, %{status: 400}} =
               OAuth.complete_onboarding(ctx.tenant, "bad-code")

      assert {:error, :not_found} =
               Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    end
  end
end
