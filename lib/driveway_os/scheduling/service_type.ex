defmodule DrivewayOS.Scheduling.ServiceType do
  @moduledoc """
  Per-tenant service catalog entry — what the tenant offers
  ("Basic Wash $50", "Deep Detail $200"). Customer-facing booking
  flow renders the active ones; tenant admin CRUD's them.

  Stripe product/price IDs land here once the tenant completes
  Connect onboarding (Phase 6 in the original migration plan; we'll
  wire that in the booking slice when it's needed).

  V1 keeps it simple — flat base price, no vehicle-size matrix.
  Multi-vehicle pricing is a V2 polish item.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "service_types"
    repo DrivewayOS.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z0-9][a-z0-9-]*$/, min_length: 1, max_length: 60
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :description, :string do
      public? true
      constraints max_length: 500
    end

    attribute :base_price_cents, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :duration_minutes, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :active, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # Populated when the tenant's Stripe Connect account is set up
    # and we mint a Stripe Product + Price for this service.
    attribute :stripe_product_id, :string do
      public? true
      constraints max_length: 100
    end

    attribute :stripe_price_id, :string do
      public? true
      constraints max_length: 100
    end

    attribute :sort_order, :integer do
      default 100
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :slug,
        :name,
        :description,
        :base_price_cents,
        :duration_minutes,
        :active,
        :sort_order,
        :stripe_product_id,
        :stripe_price_id
      ]
    end

    update :update do
      primary? true

      accept [
        :slug,
        :name,
        :description,
        :base_price_cents,
        :duration_minutes,
        :active,
        :sort_order,
        :stripe_product_id,
        :stripe_price_id
      ]
    end

    read :active do
      filter expr(active == true)
      prepare build(sort: [sort_order: :asc, name: :asc])
    end

    update :archive do
      change set_attribute(:active, false)
    end

    update :reactivate do
      change set_attribute(:active, true)
    end
  end
end
