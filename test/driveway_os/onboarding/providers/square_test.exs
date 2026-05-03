defmodule DrivewayOS.Onboarding.Providers.SquareTest do
  @moduledoc """
  Pin the Provider behaviour conformance for the Square adapter.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Providers.Square, as: Provider
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PaymentConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "osq-#{System.unique_integer([:positive])}",
        display_name: "Square Adapter Test",
        admin_email: "osq-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :square" do
    assert Provider.id() == :square
  end

  test "category/0 is :payment" do
    assert Provider.category() == :payment
  end

  test "display/0 returns the canonical card copy" do
    d = Provider.display()
    assert d.title == "Take card payments via Square"
    assert d.cta_label == "Connect Square"
    assert d.href == "/onboarding/square/start"
  end

  test "configured?/0 mirrors the OAuth helper" do
    assert Provider.configured?()
  end

  test "setup_complete?/1 false when no PaymentConnection exists", ctx do
    refute Provider.setup_complete?(ctx.tenant)
  end

  test "setup_complete?/1 true when PaymentConnection has tokens", ctx do
    {:ok, _} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :square,
        external_merchant_id: "MLR-1",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)

    assert Provider.setup_complete?(ctx.tenant)
  end

  test "provision/2 returns {:error, :hosted_required} (Square is OAuth-redirect)", ctx do
    assert {:error, :hosted_required} = Provider.provision(ctx.tenant, %{})
  end

  describe "affiliate_config/0" do
    test "ref_id from app env" do
      original = Application.get_env(:driveway_os, :square_affiliate_ref_id)
      Application.put_env(:driveway_os, :square_affiliate_ref_id, "drivewayos-square")
      on_exit(fn -> Application.put_env(:driveway_os, :square_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: "drivewayos-square"} = Provider.affiliate_config()
    end

    test "ref_id nil when env unset" do
      original = Application.get_env(:driveway_os, :square_affiliate_ref_id)
      Application.put_env(:driveway_os, :square_affiliate_ref_id, nil)
      on_exit(fn -> Application.put_env(:driveway_os, :square_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: nil} = Provider.affiliate_config()
    end
  end

  test "tenant_perk/0 returns nil — no perk shipping in V1" do
    assert Provider.tenant_perk() == nil
  end
end
