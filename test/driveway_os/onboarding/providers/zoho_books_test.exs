defmodule DrivewayOS.Onboarding.Providers.ZohoBooksTest do
  @moduledoc """
  Pin the Provider behaviour conformance for the Zoho Books adapter.
  The adapter is thin — `Accounting.OAuth.configured?/0` and
  `Platform.get_accounting_connection/2` do the heavy lifting.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Providers.ZohoBooks, as: Provider
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ozb-#{System.unique_integer([:positive])}",
        display_name: "Zoho Adapter Test",
        admin_email: "ozb-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :zoho_books" do
    assert Provider.id() == :zoho_books
  end

  test "category/0 is :accounting" do
    assert Provider.category() == :accounting
  end

  test "display/0 returns the canonical card copy" do
    d = Provider.display()
    assert d.title == "Sync to Zoho Books"
    assert d.cta_label == "Connect Zoho"
    assert d.href == "/onboarding/zoho/start"
  end

  test "configured?/0 mirrors the OAuth helper" do
    assert Provider.configured?()
  end

  test "setup_complete?/1 false when no AccountingConnection exists", ctx do
    refute Provider.setup_complete?(ctx.tenant)
  end

  test "setup_complete?/1 true when an AccountingConnection has tokens", ctx do
    {:ok, _} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :zoho_books,
        external_org_id: "999",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        region: "com"
      })
      |> Ash.create(authorize?: false)

    assert Provider.setup_complete?(ctx.tenant)
  end

  test "provision/2 returns {:error, :hosted_required} (Zoho is OAuth-redirect)", ctx do
    assert {:error, :hosted_required} = Provider.provision(ctx.tenant, %{})
  end

  describe "affiliate_config/0" do
    test "ref_id from app env" do
      original = Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
      Application.put_env(:driveway_os, :zoho_affiliate_ref_id, "drivewayos-affil")
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: "drivewayos-affil"} = Provider.affiliate_config()
    end

    test "ref_id nil when env unset" do
      original = Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
      Application.put_env(:driveway_os, :zoho_affiliate_ref_id, nil)
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: nil} = Provider.affiliate_config()
    end
  end

  test "tenant_perk/0 returns nil — no perk shipping in V1" do
    assert Provider.tenant_perk() == nil
  end
end
