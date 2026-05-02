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
end
