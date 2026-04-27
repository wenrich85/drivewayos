defmodule DrivewayOS.Platform.Tenant do
  @moduledoc """
  The Tenant anchor. Every tenant-scoped resource elsewhere in the
  app eventually carries a `tenant_id` pointing here.

  Tenant itself is NOT tenant-scoped (it IS the tenant). No
  `multitenancy` block — that would be circular.

  Lifecycle states:

      :pending_onboarding  — created, Stripe Connect not yet completed
      :active              — onboarding done, can accept bookings
      :suspended           — platform admin paused this tenant
      :archived            — soft-deleted; data retained 90 days

  V1 deliberately does not include `legacy_host` or `CustomDomain` —
  both deferred until we have a tenant who needs them.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "tenants"
    repo DrivewayOS.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :slug, :ci_string do
      allow_nil? false
      public? true
      # Kebab-case, digits allowed. 3–30 chars. Edges must be alnum
      # (no leading/trailing dash). Reserved-word blacklist is enforced
      # at the application layer in the signup flow, not here.
      constraints match: ~r/^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$/, min_length: 3, max_length: 30
    end

    attribute :display_name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :legal_name, :string do
      public? true
      constraints max_length: 200
    end

    attribute :status, :atom do
      constraints one_of: [:pending_onboarding, :active, :suspended, :archived]
      default :pending_onboarding
      allow_nil? false
      public? true
    end

    # Stripe Connect Standard account id — set when OAuth onboarding
    # completes. Unique when non-null.
    attribute :stripe_account_id, :string do
      public? true
      constraints max_length: 100
    end

    # Mirrors Stripe's `account.requirements.disabled_reason` state.
    attribute :stripe_account_status, :atom do
      constraints one_of: [:none, :pending, :restricted, :enabled]
      default :none
      allow_nil? false
      public? true
    end

    # Subdomain under the platform host. Defaults to slug if not set —
    # stored separately so a slug rename doesn't silently break routing.
    attribute :subdomain, :string do
      public? true
      constraints max_length: 30
    end

    # Branding fields (populated as tenants set them up post-signup).
    attribute :primary_color_hex, :string do
      public? true
      constraints match: ~r/^#?[0-9a-fA-F]{6}$/
    end

    attribute :logo_url, :string do
      public? true
      constraints max_length: 500
    end

    attribute :support_email, :string do
      public? true
      constraints max_length: 200
    end

    attribute :support_phone, :string do
      public? true
      constraints max_length: 30
    end

    attribute :timezone, :string do
      default "America/Chicago"
      allow_nil? false
      public? true
      constraints max_length: 60
    end

    attribute :archived_at, :utc_datetime_usec do
      public? true
    end

    # SaaS-tier feature gating. See DrivewayOS.Plans for the
    # per-tier feature matrix. `nil` is treated as `:pro` by
    # `Plans.tier_for/1` so existing tenants don't lose features
    # when this column lights up.
    attribute :plan_tier, :atom do
      constraints one_of: [:starter, :pro, :enterprise]
      public? true
    end

    # Loyalty punch card threshold. Nil = the feature is off for
    # this tenant. Otherwise, every Nth completed appointment
    # earns the customer a free wash. Operators set this from
    # /admin/branding.
    attribute :loyalty_threshold, :integer do
      public? true
      constraints min: 2, max: 50
    end

    # Stamped after the WeeklyDigestScheduler emails this tenant's
    # admins their Monday-morning recap. The scheduler skips
    # tenants stamped within the last 6 days so a sweeper that
    # runs hourly can't double-send.
    attribute :last_digest_sent_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
    identity :unique_subdomain, [:subdomain]
    identity :unique_stripe_account_id, [:stripe_account_id]
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :slug,
        :display_name,
        :legal_name,
        :subdomain,
        :stripe_account_id,
        :primary_color_hex,
        :logo_url,
        :support_email,
        :support_phone,
        :timezone,
        :plan_tier
      ]

      # Default subdomain to slug if not specified — keeps the common
      # case simple (99% of tenants' subdomain == their slug).
      change fn changeset, _ctx ->
        case Ash.Changeset.get_attribute(changeset, :subdomain) do
          nil ->
            case Ash.Changeset.get_attribute(changeset, :slug) do
              nil ->
                changeset

              slug ->
                Ash.Changeset.force_change_attribute(changeset, :subdomain, to_string(slug))
            end

          _ ->
            changeset
        end
      end
    end

    update :update do
      accept [
        :display_name,
        :legal_name,
        :stripe_account_id,
        :stripe_account_status,
        :primary_color_hex,
        :logo_url,
        :support_email,
        :support_phone,
        :timezone,
        :status,
        :plan_tier,
        :loyalty_threshold
      ]
    end

    update :archive do
      change set_attribute(:status, :archived)
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    update :mark_digest_sent do
      change set_attribute(:last_digest_sent_at, &DateTime.utc_now/0)
    end

    update :suspend do
      change set_attribute(:status, :suspended)
    end

    update :reactivate do
      change set_attribute(:status, :active)
      change set_attribute(:archived_at, nil)
    end

    read :by_slug do
      argument :slug, :ci_string, allow_nil?: false
      filter expr(slug == ^arg(:slug) and status != :archived)
    end

    read :by_stripe_account do
      argument :stripe_account_id, :string, allow_nil?: false
      filter expr(stripe_account_id == ^arg(:stripe_account_id))
    end

    read :active do
      filter expr(status == :active)
    end
  end
end
