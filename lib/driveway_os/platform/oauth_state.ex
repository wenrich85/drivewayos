defmodule DrivewayOS.Platform.OauthState do
  @moduledoc """
  Single-use state token issued when a tenant kicks off Stripe
  Connect OAuth. Stripe echoes the token back on its callback so we
  can prove the callback wasn't forged.

  Lifecycle: created on `oauth_url_for/1`, deleted on
  `verify_state/1` (success), expires after 10 minutes.

  This resource lives in the Platform domain because it's not
  tenant-scoped per-row — the row IS scoped to a tenant via
  `tenant_id`, but it doesn't go through Ash multitenancy (the
  callback handler doesn't know which tenant to scope to until it's
  resolved the state).
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  @ttl_seconds 600

  postgres do
    table "platform_oauth_states"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token, :string do
      allow_nil? false
      public? true
      constraints min_length: 16, max_length: 128
    end

    attribute :purpose, :atom do
      constraints one_of: [:stripe_connect, :zoho_books]
      default :stripe_connect
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
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

  identities do
    identity :unique_token, [:token]
  end

  actions do
    defaults [:read, :destroy]

    create :issue do
      accept [:tenant_id, :purpose]

      change fn changeset, _ctx ->
        token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        expires_at = DateTime.utc_now() |> DateTime.add(@ttl_seconds, :second)

        changeset
        |> Ash.Changeset.force_change_attribute(:token, token)
        |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
      end
    end

    read :by_token do
      argument :token, :string, allow_nil?: false

      filter expr(token == ^arg(:token) and expires_at > now())
    end
  end
end
