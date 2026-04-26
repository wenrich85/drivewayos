defmodule DrivewayOS.Repo.Migrations.GrantCustomerSubscriptionsToProPlus do
  @moduledoc """
  Adds `customer_subscriptions` to the features array of the
  seeded Pro and Enterprise plan rows. Idempotent — same shape
  as guest_checkout / booking_photos. Starter stays excluded so
  the recurring-revenue feature is a Pro+ upgrade incentive.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE platform_plans
    SET features = array_append(features, 'customer_subscriptions')
    WHERE tier IN ('pro', 'enterprise')
      AND NOT ('customer_subscriptions' = ANY(features))
    """)
  end

  def down do
    execute("""
    UPDATE platform_plans
    SET features = array_remove(features, 'customer_subscriptions')
    """)
  end
end
