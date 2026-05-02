defmodule DrivewayOS.Onboarding.AffiliateTest do
  @moduledoc """
  Public surface for the affiliate-tracking helpers. `log_event/4`
  is exercised in a separate describe block (Task 5) once the
  Platform.TenantReferral persistence is wired up.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Affiliate

  describe "tag_url/2" do
    test "passthrough when provider has no affiliate_config implementation" do
      # Stripe Connect intentionally returns nil affiliate_config —
      # its revenue model is platform fee, not a referral link.
      assert Affiliate.tag_url("https://stripe.com/setup", :stripe_connect) ==
               "https://stripe.com/setup"
    end

    test "passthrough when ref_id env var is unset (V1 default)" do
      # Postmark.affiliate_config/0 returns %{ref_id: nil} when the
      # POSTMARK_AFFILIATE_REF_ID env var isn't set.
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, nil)
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      assert Affiliate.tag_url("https://postmarkapp.com/pricing", :postmark) ==
               "https://postmarkapp.com/pricing"
    end

    test "appends ref query param when ref_id env var is set" do
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, "drivewayos")
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      url = Affiliate.tag_url("https://postmarkapp.com/pricing", :postmark)
      assert url =~ "ref=drivewayos"
      assert String.starts_with?(url, "https://postmarkapp.com/pricing?")
    end

    test "preserves existing query params when tagging" do
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, "drivewayos")
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      url = Affiliate.tag_url("https://postmarkapp.com/pricing?utm_source=blog", :postmark)
      assert url =~ "utm_source=blog"
      assert url =~ "ref=drivewayos"
    end

    test "passthrough for unknown provider id" do
      assert Affiliate.tag_url("https://example.com", :nonexistent) ==
               "https://example.com"
    end
  end

  describe "perk_copy/1" do
    test "returns nil for V1 providers (no perks shipping in Phase 2)" do
      assert Affiliate.perk_copy(:stripe_connect) == nil
      assert Affiliate.perk_copy(:postmark) == nil
    end

    test "returns nil for unknown provider id" do
      assert Affiliate.perk_copy(:nonexistent) == nil
    end
  end

  describe "log_event/4" do
    setup do
      {:ok, %{tenant: tenant}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "aff-#{System.unique_integer([:positive])}",
          display_name: "Affiliate Log Test",
          admin_email: "aff-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant}
    end

    test "writes a TenantReferral row with the given fields", ctx do
      assert :ok = Affiliate.log_event(ctx.tenant, :postmark, :click, %{wizard_step: "email"})

      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      [row] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))

      assert row.provider == :postmark
      assert row.event_type == :click
      # jsonb roundtrip strips atom keys to strings (see Task 1).
      assert row.metadata == %{"wizard_step" => "email"}
      assert %DateTime{} = row.occurred_at
    end

    test "metadata defaults to empty map when omitted", ctx do
      assert :ok = Affiliate.log_event(ctx.tenant, :stripe_connect, :provisioned)

      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      [row] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))

      assert row.metadata == %{}
    end

    test "returns :ok and does not raise on unknown event_type", ctx do
      # Logger emits a warning; we capture-and-ignore to avoid noisy
      # test output. The contract is "always returns :ok" — the
      # internal Ash error is swallowed, not propagated.
      import ExUnit.CaptureLog

      result =
        capture_log(fn ->
          assert :ok =
                   Affiliate.log_event(
                     ctx.tenant,
                     :postmark,
                     :totally_invalid,
                     %{}
                   )
        end)

      assert result =~ "Affiliate.log_event failed"

      # No row written.
      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      assert Enum.filter(all, &(&1.tenant_id == ctx.tenant.id)) == []
    end
  end
end
