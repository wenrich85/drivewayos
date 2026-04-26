defmodule DrivewayOS.Scheduling.BookingDraft do
  @moduledoc """
  Server-side stash of an in-progress booking-wizard run, so a
  signed-in customer can close the tab and resume later.

  One row per (tenant, customer) — `:upsert` overwrites on conflict.
  Step is stored as a free-form string (the atom name) so adding a
  new step doesn't need a data migration. `data` is the wizard's
  full accumulated map.

  V1 doesn't support guest drafts: the cookie/session-identity
  problem that makes guest checkouts ephemeral applies the same way
  to drafts. When V2 ships abandoned-cart emails for guests, that
  flow will set its own draft_token cookie and read here.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "booking_drafts"
    repo DrivewayOS.Repo

    references do
      reference :customer, on_delete: :delete
    end
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

    attribute :step, :string do
      allow_nil? false
      public? true
      constraints max_length: 30
    end

    attribute :data, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :customer, DrivewayOS.Accounts.Customer do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_per_customer, [:customer_id]
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:customer_id, :step, :data]

      upsert? true
      upsert_identity :unique_per_customer
      upsert_fields [:step, :data, :updated_at]
    end

    read :for_customer do
      argument :customer_id, :uuid, allow_nil?: false
      filter expr(customer_id == ^arg(:customer_id))
    end
  end
end
