defmodule DrivewayOS.Repo.Migrations.SeedDefaultPlans do
  @moduledoc """
  Insert the canonical Starter / Pro / Enterprise rows into
  `platform_plans` so a fresh DB has working SaaS-tier feature
  gates without manual setup.

  Idempotent: skips any tier that already exists.
  Platform admins edit these from `admin.<host>/plans` after the
  fact — this migration just ensures sensible defaults.
  """
  use Ecto.Migration

  @plans [
    %{
      tier: "starter",
      name: "Starter",
      monthly_cents: 0,
      blurb: "The basics — pay only for the bookings you take.",
      features: [
        "basic_booking",
        "my_appointments",
        "admin_dashboard",
        "stripe_connect",
        "branding",
        "appointment_email_confirmations"
      ],
      limit_services: 3,
      limit_block_templates: 5,
      limit_bookings_per_month: 50,
      limit_technicians: 1,
      sort_order: 10
    },
    %{
      tier: "pro",
      name: "Pro",
      monthly_cents: 4900,
      blurb: "Built for shops with repeat customers + multiple techs.",
      features: [
        "basic_booking",
        "my_appointments",
        "admin_dashboard",
        "stripe_connect",
        "branding",
        "appointment_email_confirmations",
        "custom_domains",
        "saved_vehicles",
        "saved_addresses",
        "booking_photos",
        "sms_notifications",
        "push_notifications",
        "loyalty_punch_card",
        "multi_tech_dispatch",
        "route_optimization",
        "customer_subscriptions"
      ],
      limit_services: -1,
      limit_block_templates: -1,
      limit_bookings_per_month: 500,
      limit_technicians: 5,
      sort_order: 20
    },
    %{
      tier: "enterprise",
      name: "Enterprise",
      monthly_cents: 19_900,
      blurb: "For multi-location shops + franchise operators.",
      features: [
        "basic_booking",
        "my_appointments",
        "admin_dashboard",
        "stripe_connect",
        "branding",
        "appointment_email_confirmations",
        "custom_domains",
        "saved_vehicles",
        "saved_addresses",
        "booking_photos",
        "sms_notifications",
        "push_notifications",
        "loyalty_punch_card",
        "multi_tech_dispatch",
        "route_optimization",
        "customer_subscriptions",
        "marketing_dashboard",
        "ai_photo_analysis",
        "api_access",
        "accounting_integrations",
        "sso",
        "priority_support"
      ],
      limit_services: -1,
      limit_block_templates: -1,
      limit_bookings_per_month: -1,
      limit_technicians: -1,
      sort_order: 30
    }
  ]

  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for plan <- @plans do
      execute(fn ->
        repo().query!(
          """
          INSERT INTO platform_plans
            (id, tier, name, monthly_cents, blurb, features,
             limit_services, limit_block_templates, limit_bookings_per_month,
             limit_technicians, sort_order, inserted_at, updated_at)
          VALUES
            ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
          ON CONFLICT (tier) DO NOTHING
          """,
          [
            Ecto.UUID.bingenerate(),
            plan.tier,
            plan.name,
            plan.monthly_cents,
            plan.blurb,
            plan.features,
            plan.limit_services,
            plan.limit_block_templates,
            plan.limit_bookings_per_month,
            plan.limit_technicians,
            plan.sort_order,
            now,
            now
          ]
        )
      end)
    end
  end

  def down do
    execute("DELETE FROM platform_plans WHERE tier IN ('starter', 'pro', 'enterprise')")
  end
end
