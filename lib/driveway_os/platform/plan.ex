defmodule DrivewayOS.Platform.Plan do
  @moduledoc """
  SaaS-tier definition. Stored in the DB (not hardcoded in a module
  attribute) so a platform admin can adjust which features each
  tier exposes without a code deploy.

  One row per tier (`:starter` / `:pro` / `:enterprise`). The
  `features` array is the source of truth for `Plans.tenant_can?/2`
  — add an atom string to that array and every gated code path
  unlocks for that tier.

  Seeded by a Repo.insert! in
  `priv/repo/migrations/.._seed_default_plans.exs` so a fresh DB
  comes up with sensible defaults; admins edit from there.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_plans"
    repo DrivewayOS.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :tier, :atom do
      constraints one_of: [:starter, :pro, :enterprise]
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60
    end

    attribute :monthly_cents, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :blurb, :string do
      public? true
      constraints max_length: 240
    end

    # Stored as text array so Postgres can index + filter; the
    # canonical feature names are atoms in code, serialized as
    # plain strings on the way in and out.
    attribute :features, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    # Numeric limits per tier. -1 = unlimited.
    attribute :limit_services, :integer, default: -1, public?: true
    attribute :limit_block_templates, :integer, default: -1, public?: true
    attribute :limit_bookings_per_month, :integer, default: -1, public?: true
    attribute :limit_technicians, :integer, default: -1, public?: true

    # Display order on the pricing page (cheapest = lowest number).
    attribute :sort_order, :integer, default: 100, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_tier, [:tier]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :tier,
        :name,
        :monthly_cents,
        :blurb,
        :features,
        :limit_services,
        :limit_block_templates,
        :limit_bookings_per_month,
        :limit_technicians,
        :sort_order
      ]
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :name,
        :monthly_cents,
        :blurb,
        :features,
        :limit_services,
        :limit_block_templates,
        :limit_bookings_per_month,
        :limit_technicians,
        :sort_order
      ]
    end

    read :for_tier do
      argument :tier, :atom, allow_nil?: false
      filter expr(tier == ^arg(:tier))
    end

    read :ordered do
      prepare build(sort: [sort_order: :asc])
    end
  end
end
