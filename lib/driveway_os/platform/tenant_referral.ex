defmodule DrivewayOS.Platform.TenantReferral do
  @moduledoc """
  Affiliate / referral funnel events for the Phase 2 onboarding
  abstraction. One row per `(tenant, provider, event)` occurrence.
  Platform-tier — no multitenancy block; tenants don't read this
  data, only DrivewayOS does.

  Event types:
    * `:click` — tenant initiated provider setup (e.g. Stripe OAuth
      redirect issued, Postmark form submitted).
    * `:provisioned` — provider successfully connected
      (`setup_complete?/1` flipped true).
    * `:revenue_attributed` — placeholder; written when a provider
      webhook reports a referral payout. No code path writes this in
      Phase 2; schema is ready for Phase 4.

  `metadata` is a freeform map. Per-event-type contracts are
  documented at the call sites in `Onboarding.Affiliate` rather than
  enforced by a typed schema (V1 — see Phase 2 design doc, "Decisions
  deferred to plan-writing").
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_tenant_referrals"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :delete
    end

    custom_indexes do
      index [:tenant_id, :provider]
      index [:provider, :event_type, :occurred_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
    end

    attribute :event_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:click, :provisioned, :revenue_attributed]
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :tenant, DrivewayOS.Platform.Tenant do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :log do
      accept [:tenant_id, :provider, :event_type, :metadata]
      change set_attribute(:occurred_at, &DateTime.utc_now/0)
    end
  end
end
