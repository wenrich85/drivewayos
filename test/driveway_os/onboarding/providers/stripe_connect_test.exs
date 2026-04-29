defmodule DrivewayOS.Onboarding.Providers.StripeConnectTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Providers.StripeConnect, as: Provider
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant, admin: _admin}} =
      Platform.provision_tenant(%{
        slug: "scprov-#{System.unique_integer([:positive])}",
        display_name: "Stripe Provider Test",
        admin_email: "scprov-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :stripe_connect" do
    assert Provider.id() == :stripe_connect
  end

  test "category/0 is :payment" do
    assert Provider.category() == :payment
  end

  test "display/0 returns title, blurb, cta_label, href" do
    d = Provider.display()
    assert is_binary(d.title)
    assert is_binary(d.blurb)
    assert is_binary(d.cta_label)
    assert d.href == "/onboarding/stripe/start"
  end

  test "configured?/0 mirrors Billing.StripeConnect.configured?/0" do
    # Test config has stripe_client_id set, so configured? is true.
    assert Provider.configured?() == DrivewayOS.Billing.StripeConnect.configured?()

    # Flipping the env flips the answer.
    original = Application.get_env(:driveway_os, :stripe_client_id)
    Application.put_env(:driveway_os, :stripe_client_id, "")
    on_exit(fn -> Application.put_env(:driveway_os, :stripe_client_id, original) end)

    refute Provider.configured?()
  end

  test "setup_complete?/1 reflects whether the tenant has a stripe_account_id", ctx do
    refute Provider.setup_complete?(ctx.tenant)

    {:ok, with_acct} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_test_123"})
      |> Ash.update(authorize?: false)

    assert Provider.setup_complete?(with_acct)
  end
end
