defmodule DrivewayOS.Onboarding.RegistryTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Registry
  alias DrivewayOS.Onboarding.Providers.StripeConnect
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "reg-#{System.unique_integer([:positive])}",
        display_name: "Registry Test",
        admin_email: "reg-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "all/0 includes the StripeConnect provider" do
    assert StripeConnect in Registry.all()
  end

  test "by_category/1 filters to providers in that category" do
    assert StripeConnect in Registry.by_category(:payment)
    assert Registry.by_category(:nonsense) == []
  end

  test "needing_setup/1 returns providers that are configured AND not yet set up", ctx do
    # Default test tenant has no stripe_account_id, and stripe_client_id
    # is set in test config → StripeConnect should appear.
    assert StripeConnect in Registry.needing_setup(ctx.tenant)
  end

  test "needing_setup/1 hides providers that are already set up for this tenant", ctx do
    {:ok, with_acct} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_x_123"})
      |> Ash.update(authorize?: false)

    refute StripeConnect in Registry.needing_setup(with_acct)
  end

  test "needing_setup/1 hides providers that aren't configured at the platform level", ctx do
    original = Application.get_env(:driveway_os, :stripe_client_id)
    Application.put_env(:driveway_os, :stripe_client_id, "")
    on_exit(fn -> Application.put_env(:driveway_os, :stripe_client_id, original) end)

    refute StripeConnect in Registry.needing_setup(ctx.tenant)
  end

  describe "fetch/1" do
    test "returns {:ok, module} for a known provider id" do
      assert {:ok, DrivewayOS.Onboarding.Providers.Postmark} = Registry.fetch(:postmark)
      assert {:ok, DrivewayOS.Onboarding.Providers.StripeConnect} = Registry.fetch(:stripe_connect)
    end

    test "returns :error for an unknown id" do
      assert :error = Registry.fetch(:totally_made_up)
    end
  end
end
