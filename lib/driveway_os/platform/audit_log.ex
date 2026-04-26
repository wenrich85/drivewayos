defmodule DrivewayOS.Platform.AuditLog do
  @moduledoc """
  Append-only ledger of platform-side admin actions.

  Captures things you'd later want to investigate after the fact:
  who suspended that tenant? who issued that refund? who
  impersonated whom and for how long?

  Constraints:
    * Insert-only — no `:update` or `:destroy` actions exposed.
      The whole point is that entries can't be doctored.
    * `tenant_id` nullable so platform-level events
      (e.g. operator sign-in) can still be recorded.
    * `platform_user_id` nullable so tenant-side actions
      (admin issuing a refund themselves) can also live here.
    * `action` is a closed enum. Adding a new event type means
      editing this resource — keeps the action vocabulary
      auditable.

  See `DrivewayOS.Platform.log_audit/1` for the high-level
  insert helper used by everywhere that fires events.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  @actions [
    # Platform-tier
    :platform_user_signed_in,
    :platform_user_signed_out,
    # Tenant lifecycle (initiated by platform admin)
    :tenant_suspended,
    :tenant_reactivated,
    :tenant_archived,
    :tenant_impersonated,
    # Tenant-side (initiated by tenant admin)
    :appointment_refunded,
    :appointment_confirmed,
    :appointment_cancelled,
    :tenant_branding_updated,
    :custom_domain_added,
    :custom_domain_verified,
    :custom_domain_removed,
    # Platform plan edits (SaaS-tier matrix changes)
    :platform_plan_updated
  ]

  postgres do
    table "platform_audit_log"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :nilify
      reference :platform_user, on_delete: :nilify
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :action, :atom do
      constraints one_of: @actions
      allow_nil? false
      public? true
    end

    attribute :target_type, :string do
      public? true
      constraints max_length: 60
    end

    attribute :target_id, :string do
      public? true
      constraints max_length: 64
    end

    attribute :payload, :map do
      public? true
      default %{}
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :tenant, DrivewayOS.Platform.Tenant do
      allow_nil? true
      attribute_writable? true
      public? true
    end

    belongs_to :platform_user, DrivewayOS.Platform.PlatformUser do
      allow_nil? true
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read]

    create :log do
      accept [:action, :target_type, :target_id, :payload, :tenant_id, :platform_user_id]
    end

    read :recent_for_tenant do
      argument :tenant_id, :uuid, allow_nil?: false
      argument :limit, :integer, default: 50

      filter expr(tenant_id == ^arg(:tenant_id))
      prepare build(sort: [inserted_at: :desc], limit: arg(:limit))
    end
  end

  @doc "List of every recognized action atom."
  @spec actions() :: [atom()]
  def actions, do: @actions
end
