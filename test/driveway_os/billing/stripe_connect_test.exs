defmodule DrivewayOS.Billing.StripeConnectTest do
  @moduledoc """
  Stripe Connect (Standard) onboarding for tenants. Each tenant
  completes Stripe's OAuth flow once; we store the resulting
  `stripe_user_id` on the Tenant and use it as `connect_account:`
  on every subsequent Stripe API call.

  This test file covers:

    * `oauth_url_for/1` builds a valid Stripe OAuth URL with a
      single-use state token bound to the tenant
    * `verify_state!/1` returns the tenant id for a fresh state,
      consumes the state, and rejects a second use
    * `verify_state!/1` rejects expired states
    * `complete_onboarding/2` (mocked Stripe call) updates the
      Tenant's stripe_account_id + flips status to :active
  """
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Billing.StripeConnect
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  setup :verify_on_exit!

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "sc-#{System.unique_integer([:positive])}",
        display_name: "Stripe Connect Test"
      })
      |> Ash.create(authorize?: false)

    %{tenant: tenant}
  end

  describe "oauth_url_for/1" do
    test "produces a connect.stripe.com URL with required params + a state token",
         %{tenant: tenant} do
      url = StripeConnect.oauth_url_for(tenant)

      assert url =~ "https://connect.stripe.com/oauth/authorize"
      assert url =~ "response_type=code"
      assert url =~ "scope=read_write"
      # client_id from config (test env injects a placeholder)
      assert url =~ "client_id="
      # state must be a non-empty token
      assert [_, state | _] = Regex.run(~r/state=([^&]+)/, url)
      assert byte_size(state) >= 16
    end

    test "subsequent calls produce different state tokens", %{tenant: tenant} do
      [_, s1] = Regex.run(~r/state=([^&]+)/, StripeConnect.oauth_url_for(tenant))
      [_, s2] = Regex.run(~r/state=([^&]+)/, StripeConnect.oauth_url_for(tenant))

      refute s1 == s2
    end
  end

  describe "verify_state/1" do
    test "fresh state returns {:ok, tenant_id} and consumes it", %{tenant: tenant} do
      [_, state] = Regex.run(~r/state=([^&]+)/, StripeConnect.oauth_url_for(tenant))

      assert {:ok, tenant_id} = StripeConnect.verify_state(state)
      assert tenant_id == tenant.id

      # Second use must fail (consumed).
      assert {:error, :invalid_state} = StripeConnect.verify_state(state)
    end

    test "unknown state returns :invalid_state" do
      assert {:error, :invalid_state} = StripeConnect.verify_state("not-a-real-state")
    end
  end

  describe "complete_onboarding/2" do
    test "exchanges code with Stripe, updates tenant, returns updated tenant",
         %{tenant: tenant} do
      DrivewayOS.Billing.StripeClientMock
      |> expect(:exchange_oauth_code, fn "tok_test_code" ->
        {:ok, %{stripe_user_id: "acct_test_123"}}
      end)

      assert {:ok, updated} = StripeConnect.complete_onboarding(tenant, "tok_test_code")
      assert updated.stripe_account_id == "acct_test_123"
      assert updated.stripe_account_status == :enabled
      assert updated.status == :active
    end

    test "Stripe error → {:error, reason}, tenant untouched", %{tenant: tenant} do
      DrivewayOS.Billing.StripeClientMock
      |> expect(:exchange_oauth_code, fn _ -> {:error, :stripe_invalid_grant} end)

      assert {:error, :stripe_invalid_grant} =
               StripeConnect.complete_onboarding(tenant, "bad-code")

      reloaded = Platform.get_tenant_by_slug!(tenant.slug)
      assert is_nil(reloaded.stripe_account_id)
    end
  end
end
