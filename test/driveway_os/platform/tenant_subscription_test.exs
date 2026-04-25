defmodule DrivewayOS.Platform.TenantSubscriptionTest do
  @moduledoc """
  V1 Slice 1: TenantSubscription — schema-only stub for SaaS billing.

  Distinct from any (eventual) `Billing.Subscription` resource (which
  will represent a TENANT'S customer paying for monthly washes).
  TenantSubscription is OUR Stripe charging the tenant for using
  DrivewayOS.

  Phase 6 wires actual Stripe; this slice ships the table.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform.{Tenant, TenantSubscription}

  describe "create" do
    test "creates a subscription linked to a tenant" do
      {:ok, tenant} = create_tenant!()

      {:ok, sub} =
        TenantSubscription
        |> Ash.Changeset.for_create(:create, %{
          tenant_id: tenant.id,
          plan_tier: :starter,
          status: :trialing,
          stripe_subscription_id: "sub_test_#{System.unique_integer([:positive])}"
        })
        |> Ash.create(authorize?: false)

      assert sub.id
      assert sub.tenant_id == tenant.id
      assert sub.plan_tier == :starter
      assert sub.status == :trialing
    end

    test "plan_tier defaults to :starter and status to :trialing" do
      {:ok, tenant} = create_tenant!()

      {:ok, sub} =
        TenantSubscription
        |> Ash.Changeset.for_create(:create, %{tenant_id: tenant.id})
        |> Ash.create(authorize?: false)

      assert sub.plan_tier == :starter
      assert sub.status == :trialing
    end

    test "rejects invalid status atoms" do
      {:ok, tenant} = create_tenant!()

      assert {:error, %Ash.Error.Invalid{}} =
               TenantSubscription
               |> Ash.Changeset.for_create(:create, %{
                 tenant_id: tenant.id,
                 status: :bogus
               })
               |> Ash.create(authorize?: false)
    end
  end

  defp create_tenant! do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "subs-#{System.unique_integer([:positive])}",
      display_name: "Subs Test"
    })
    |> Ash.create(authorize?: false)
  end
end
