defmodule DrivewayOS.Platform.AccountingConnection do
  @moduledoc """
  Per-(tenant, provider) accounting integration record. Stores OAuth
  tokens, sync settings, and last-sync metadata. Platform-tier — no
  multitenancy block; tenants don't read this directly, only the
  Accounting modules and the IntegrationsLive page do.

  Lifecycle:
    * `:connect` — first time tenant authorizes; populates tokens.
    * `:refresh_tokens` — periodic; replaces access/refresh tokens.
    * `:record_sync_success` / `:record_sync_error` — SyncWorker.
    * `:pause` / `:resume` — tenant-controlled, toggles auto_sync_enabled.
    * `:disconnect` — clears tokens, sets disconnected_at, auto-pauses.
       Reconnect upserts via the `:unique_tenant_provider` identity.

  Tokens are sensitive (Ash redacts them in logs); plaintext at rest
  in V1, matching Phase 1's `postmark_api_key` posture. Encryption is
  a Phase 2 hardening pass (separate from the multi-phase onboarding
  roadmap).
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_accounting_connections"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:zoho_books]
    end

    attribute :external_org_id, :string, public?: true
    attribute :region, :string, default: "com", public?: true

    attribute :access_token, :string do
      sensitive? true
      public? false
    end

    attribute :refresh_token, :string do
      sensitive? true
      public? false
    end

    attribute :access_token_expires_at, :utc_datetime_usec

    attribute :auto_sync_enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :connected_at, :utc_datetime_usec
    attribute :disconnected_at, :utc_datetime_usec
    attribute :last_sync_at, :utc_datetime_usec
    attribute :last_sync_error, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, DrivewayOS.Platform.Tenant do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_tenant_provider, [:tenant_id, :provider]
  end

  actions do
    defaults [:read, :destroy]

    create :connect do
      accept [:tenant_id, :provider, :external_org_id, :access_token,
              :refresh_token, :access_token_expires_at, :region]
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :refresh_tokens do
      accept [:access_token, :refresh_token, :access_token_expires_at]
    end

    update :record_sync_success do
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
      change set_attribute(:last_sync_error, nil)
    end

    update :record_sync_error do
      accept [:last_sync_error]
    end

    update :disconnect do
      change set_attribute(:access_token, nil)
      change set_attribute(:refresh_token, nil)
      change set_attribute(:access_token_expires_at, nil)
      change set_attribute(:disconnected_at, &DateTime.utc_now/0)
      change set_attribute(:auto_sync_enabled, false)
    end

    update :pause do
      change set_attribute(:auto_sync_enabled, false)
    end

    update :resume do
      change set_attribute(:auto_sync_enabled, true)
    end
  end
end
