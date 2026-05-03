defmodule DrivewayOS.Platform.EmailConnection do
  @moduledoc """
  Per-(tenant, email provider) integration record. Stores api_key
  + lifecycle state for API-first email providers. Platform-tier —
  no multitenancy block; tenants don't read this directly, only the
  Resend modules and the IntegrationsLive page do.

  Lifecycle:
    * `:connect` — first time tenant authorizes; populates api_key.
    * `:reconnect` — on re-authorize after a disconnect; replaces
       api_key + external_key_id, clears disconnected_at, sets
       auto_send_enabled true. Single atomic action — Phase 3's M1
       fix incorporated preemptively.
    * `:record_send_success` / `:record_send_error` — Mailer updates.
    * `:pause` / `:resume` — tenant-controlled, toggles auto_send_enabled.
    * `:disconnect` — clears api_key, sets disconnected_at, auto-pauses.

  api_key is sensitive (Ash redacts in logs); plaintext at rest in
  V1, matching Phase 1's `postmark_api_key` and Phase 4's
  PaymentConnection access tokens.

  V1's only `:provider` value is `:resend`; Phase 5+ extends.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_email_connections"
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
      constraints one_of: [:resend]
    end

    attribute :external_key_id, :string, public?: true

    attribute :api_key, :string do
      sensitive? true
      public? false
    end

    attribute :auto_send_enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :connected_at, :utc_datetime_usec
    attribute :disconnected_at, :utc_datetime_usec
    attribute :last_send_at, :utc_datetime_usec
    attribute :last_send_error, :string

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
      accept [:tenant_id, :provider, :external_key_id, :api_key]
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :reconnect do
      accept [:external_key_id, :api_key]
      change set_attribute(:disconnected_at, nil)
      change set_attribute(:auto_send_enabled, true)
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :record_send_success do
      change set_attribute(:last_send_at, &DateTime.utc_now/0)
      change set_attribute(:last_send_error, nil)
    end

    update :record_send_error do
      accept [:last_send_error]
    end

    update :disconnect do
      change set_attribute(:api_key, nil)
      change set_attribute(:external_key_id, nil)
      change set_attribute(:disconnected_at, &DateTime.utc_now/0)
      change set_attribute(:auto_send_enabled, false)
    end

    update :pause do
      change set_attribute(:auto_send_enabled, false)
    end

    update :resume do
      change set_attribute(:auto_send_enabled, true)
    end
  end
end
