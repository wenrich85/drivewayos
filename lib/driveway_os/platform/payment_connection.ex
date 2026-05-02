defmodule DrivewayOS.Platform.PaymentConnection do
  @moduledoc """
  Per-(tenant, payment provider) integration record. Stores OAuth
  tokens, sync settings, and last-charge metadata. Platform-tier — no
  multitenancy block; tenants don't read this directly, only the
  Square modules and the IntegrationsLive page do.

  Lifecycle:
    * `:connect` — first time tenant authorizes; populates tokens.
    * `:refresh_tokens` — periodic; replaces access/refresh tokens.
    * `:reconnect` — on OAuth re-authorize after a disconnect; updates
       tokens + merchant_id, clears disconnected_at, sets
       auto_charge_enabled true. Single atomic action — Phase 3's M1
       fix incorporated preemptively.
    * `:record_charge_success` / `:record_charge_error` — webhook updates.
    * `:pause` / `:resume` — tenant-controlled, toggles auto_charge_enabled.
    * `:disconnect` — clears tokens, sets disconnected_at, auto-pauses.

  Tokens are sensitive (Ash redacts them in logs); plaintext at rest
  in V1, matching Phase 1's `postmark_api_key` and Phase 3's
  AccountingConnection access tokens.

  V1's only `:provider` value is `:square`; Phase 5+ extends to other
  payment providers.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_payment_connections"
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
      constraints one_of: [:square]
    end

    attribute :external_merchant_id, :string, public?: true

    attribute :access_token, :string do
      sensitive? true
      public? false
    end

    attribute :refresh_token, :string do
      sensitive? true
      public? false
    end

    attribute :access_token_expires_at, :utc_datetime_usec

    attribute :auto_charge_enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :connected_at, :utc_datetime_usec
    attribute :disconnected_at, :utc_datetime_usec
    attribute :last_charge_at, :utc_datetime_usec
    attribute :last_charge_error, :string

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
      accept [:tenant_id, :provider, :external_merchant_id, :access_token,
              :refresh_token, :access_token_expires_at]
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :reconnect do
      accept [:access_token, :refresh_token, :access_token_expires_at, :external_merchant_id]
      change set_attribute(:disconnected_at, nil)
      change set_attribute(:auto_charge_enabled, true)
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :refresh_tokens do
      accept [:access_token, :refresh_token, :access_token_expires_at]
    end

    update :record_charge_success do
      change set_attribute(:last_charge_at, &DateTime.utc_now/0)
      change set_attribute(:last_charge_error, nil)
    end

    update :record_charge_error do
      accept [:last_charge_error]
    end

    update :disconnect do
      change set_attribute(:access_token, nil)
      change set_attribute(:refresh_token, nil)
      change set_attribute(:access_token_expires_at, nil)
      change set_attribute(:disconnected_at, &DateTime.utc_now/0)
      change set_attribute(:auto_charge_enabled, false)
    end

    update :pause do
      change set_attribute(:auto_charge_enabled, false)
    end

    update :resume do
      change set_attribute(:auto_charge_enabled, true)
    end
  end
end
