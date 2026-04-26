defmodule DrivewayOS.PlansTest do
  @moduledoc """
  Feature-gating mechanism. Each tenant has a `plan_tier`
  (:starter | :pro | :enterprise) and `Plans.tenant_can?/2`
  is the load-bearing check used by LiveViews + policies.

  Plan rows live in `platform_plans` (seeded by migration). Tests
  rely on the migrator having already inserted the canonical
  starter/pro/enterprise rows.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Plans
  alias DrivewayOS.Platform.Tenant

  setup do
    Plans.flush_cache()
    :ok
  end

  describe "tenant_can?/2" do
    test "every tier gets the basics" do
      for tier <- [:starter, :pro, :enterprise] do
        t = %Tenant{plan_tier: tier}
        assert Plans.tenant_can?(t, :basic_booking)
        assert Plans.tenant_can?(t, :admin_dashboard)
        assert Plans.tenant_can?(t, :stripe_connect)
      end
    end

    test "custom_domains is pro+ only (NOT in starter)" do
      refute Plans.tenant_can?(%Tenant{plan_tier: :starter}, :custom_domains)
      assert Plans.tenant_can?(%Tenant{plan_tier: :pro}, :custom_domains)
      assert Plans.tenant_can?(%Tenant{plan_tier: :enterprise}, :custom_domains)
    end

    test "starter excludes pro features" do
      t = %Tenant{plan_tier: :starter}
      refute Plans.tenant_can?(t, :saved_vehicles)
      refute Plans.tenant_can?(t, :saved_addresses)
      refute Plans.tenant_can?(t, :booking_photos)
      refute Plans.tenant_can?(t, :sms_notifications)
      refute Plans.tenant_can?(t, :loyalty_punch_card)
    end

    test "pro includes pro features but excludes enterprise-only" do
      t = %Tenant{plan_tier: :pro}
      assert Plans.tenant_can?(t, :saved_vehicles)
      assert Plans.tenant_can?(t, :saved_addresses)
      assert Plans.tenant_can?(t, :booking_photos)
      assert Plans.tenant_can?(t, :sms_notifications)
      refute Plans.tenant_can?(t, :marketing_dashboard)
      refute Plans.tenant_can?(t, :ai_photo_analysis)
      refute Plans.tenant_can?(t, :api_access)
    end

    test "enterprise gets everything" do
      t = %Tenant{plan_tier: :enterprise}
      assert Plans.tenant_can?(t, :marketing_dashboard)
      assert Plans.tenant_can?(t, :ai_photo_analysis)
      assert Plans.tenant_can?(t, :api_access)
      assert Plans.tenant_can?(t, :saved_vehicles)
    end

    test "nil tenant returns false (fail-closed)" do
      refute Plans.tenant_can?(nil, :basic_booking)
    end

    test "nil plan_tier on tenant defaults to :pro for back-compat" do
      t = %Tenant{plan_tier: nil}
      assert Plans.tenant_can?(t, :saved_vehicles)
      refute Plans.tenant_can?(t, :marketing_dashboard)
    end

    test "unknown feature atom returns false" do
      t = %Tenant{plan_tier: :enterprise}
      refute Plans.tenant_can?(t, :totally_made_up)
    end
  end

  describe "tier_for/1" do
    test "returns the tier atom or :pro fallback" do
      assert Plans.tier_for(%Tenant{plan_tier: :starter}) == :starter
      assert Plans.tier_for(%Tenant{plan_tier: :enterprise}) == :enterprise
      assert Plans.tier_for(%Tenant{plan_tier: nil}) == :pro
      assert Plans.tier_for(nil) == nil
    end
  end

  describe "plan_for/1" do
    test "returns the plan row for a known tier" do
      plan = Plans.plan_for(:pro)
      assert plan.name == "Pro"
      assert is_integer(plan.monthly_cents)
      assert "saved_vehicles" in plan.features
    end

    test "unknown tier returns nil" do
      assert Plans.plan_for(:bogus) == nil
    end
  end

  describe "all_plans/0" do
    test "returns plans sorted by sort_order ascending" do
      plans = Plans.all_plans()
      assert length(plans) == 3
      tiers = Enum.map(plans, & &1.tier)
      assert tiers == [:starter, :pro, :enterprise]
    end
  end

  describe "limit/2" do
    test "starter has tighter limits than pro" do
      starter = %Tenant{plan_tier: :starter}
      pro = %Tenant{plan_tier: :pro}

      assert Plans.limit(starter, :services) == 3
      assert Plans.limit(pro, :services) == -1

      assert Plans.limit(starter, :technicians) == 1
      assert Plans.limit(pro, :technicians) == 5
    end

    test "unknown limit key returns nil" do
      assert Plans.limit(%Tenant{plan_tier: :pro}, :totally_bogus) == nil
    end
  end
end
