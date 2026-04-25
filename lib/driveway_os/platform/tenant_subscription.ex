defmodule DrivewayOS.Platform.TenantSubscription do
  @moduledoc """
  SaaS billing record — OUR Stripe charging the tenant for using
  DrivewayOS. Distinct from any tenant-side `Subscription` resource
  (which represents the tenant charging THEIR end customers for
  monthly wash plans).

  V1 ships the schema + basic CRUD. Stripe wiring lands when we
  build the SaaS-billing handler against `/webhooks/stripe/platform`.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tenant_subscriptions"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    # Placeholder tier names — locking these down waits on the SaaS
    # pricing model decision. Easy to extend with another atom once
    # we know what the tiers actually look like.
    attribute :plan_tier, :atom do
      constraints one_of: [:starter, :growth, :scale]
      default :starter
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:trialing, :active, :past_due, :cancelled, :unpaid]
      default :trialing
      allow_nil? false
      public? true
    end

    attribute :stripe_subscription_id, :string do
      public? true
      constraints max_length: 100
    end

    attribute :current_period_start, :date do
      public? true
    end

    attribute :current_period_end, :date do
      public? true
    end

    attribute :trial_ends_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, DrivewayOS.Platform.Tenant do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_stripe_subscription_id, [:stripe_subscription_id]
  end

  actions do
    defaults [:read, create: :*, update: :*]

    update :cancel do
      change set_attribute(:status, :cancelled)
    end
  end
end
