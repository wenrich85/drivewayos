defmodule DrivewayOS.Platform.CustomDomain do
  @moduledoc """
  A tenant-owned hostname that resolves to a tenant's branded shop —
  e.g. `book.acmewash.com` → the Acme Wash tenant.

  Lifecycle:

      created → DNS not verified yet (`verified_at` is nil)
        ↓ tenant adds CNAME / TXT record at their DNS provider
      verified → routing now resolves this hostname to the tenant
        ↓ (V2) ACME cert provisioning
      ssl_issued → fully self-served HTTPS

  V1 ships routing only. SSL termination is the tenant's
  responsibility (Cloudflare, Fastly, their own LB). The
  `ssl_status` enum is here so the cert-automation feature can
  light up later without a migration.

  Hostnames are globally unique — only one tenant can claim
  `book.acmewash.com`. The tenant boundary on this resource is
  `tenant_id` (a regular FK), not Ash multitenancy: this resource
  lives in the Platform domain because the routing plug needs to
  resolve `host → tenant` BEFORE any tenant context exists.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_custom_domains"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :hostname, :string do
      allow_nil? false
      public? true
      # RFC-1035-ish; conservative. Case-insensitive regex because
      # the lowercasing change runs after attribute-constraint checks.
      constraints match:
                    ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i,
                  min_length: 4,
                  max_length: 253
    end

    attribute :verification_token, :string do
      allow_nil? false
      public? true
      constraints min_length: 16, max_length: 64
    end

    attribute :verified_at, :utc_datetime_usec do
      public? true
    end

    attribute :ssl_status, :atom do
      constraints one_of: [:none, :pending, :issued, :failed]
      default :none
      allow_nil? false
      public? true
    end

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
    identity :unique_hostname, [:hostname]
  end

  actions do
    defaults [:read]

    create :create do
      accept [:hostname, :tenant_id]

      change fn changeset, _ctx ->
        changeset
        |> normalize_hostname()
        |> ensure_verification_token()
      end
    end

    update :verify do
      change set_attribute(:verified_at, &DateTime.utc_now/0)
    end

    update :unverify do
      change set_attribute(:verified_at, nil)
    end

    update :update_ssl_status do
      accept [:ssl_status]
    end

    read :verified_for_hostname do
      argument :hostname, :string, allow_nil?: false

      filter expr(hostname == ^arg(:hostname) and not is_nil(verified_at))
    end
  end

  # --- Private changes ---

  defp normalize_hostname(changeset) do
    case Ash.Changeset.get_attribute(changeset, :hostname) do
      hostname when is_binary(hostname) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :hostname,
          hostname |> String.trim() |> String.downcase()
        )

      _ ->
        changeset
    end
  end

  defp ensure_verification_token(changeset) do
    case Ash.Changeset.get_attribute(changeset, :verification_token) do
      nil ->
        token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        Ash.Changeset.force_change_attribute(changeset, :verification_token, token)

      _ ->
        changeset
    end
  end
end
