defmodule DrivewayOS.Scheduling.BlockedDate do
  @moduledoc """
  Operator-flagged dates that are unavailable for booking
  (vacation, weather, off day). The customer-facing booking
  wizard's slot picker filters these out via
  `Scheduling.upcoming_slots/2`.

  Tenant-scoped + unique per (tenant, date) — one row per
  blocked day. Storing as `Date` rather than a datetime range
  because shops typically block whole days at a time; if a
  partial-day exception lands as a real need, V2 adds a
  start/end pair.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "blocked_dates"
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

    attribute :blocked_on, :date do
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      public? true
      constraints max_length: 200
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_blocked_date, [:blocked_on]
  end

  actions do
    defaults [:read, :destroy]

    create :block do
      primary? true
      accept [:blocked_on, :reason]

      upsert? true
      upsert_identity :unique_blocked_date
    end

    read :upcoming do
      filter expr(blocked_on >= ^Date.utc_today())
      prepare build(sort: [blocked_on: :asc])
    end
  end
end
