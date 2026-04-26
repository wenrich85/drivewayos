defmodule DrivewayOS.Scheduling.BlockTemplate do
  @moduledoc """
  Tenant-scoped weekly recurring availability slot.

  An operator says "I work Wednesdays 9am-12pm; one car at a time"
  by inserting a row with `day_of_week: 3, start_time: ~T[09:00:00],
  duration_minutes: 180, capacity: 1`.

  The booking form expands these into concrete dated slots over the
  next ~14 days, hiding any that are already at capacity.

  V1 keeps the model intentionally narrow — see the test file's
  moduledoc for what's deliberately deferred.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "block_templates"
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

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    # 0 = Sunday, 6 = Saturday (matches Date.day_of_week with
    # :sunday as the start, which is also what most JS pickers use).
    attribute :day_of_week, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 6
    end

    attribute :start_time, :time do
      allow_nil? false
      public? true
    end

    attribute :duration_minutes, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 24 * 60
    end

    attribute :capacity, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :day_of_week, :start_time, :duration_minutes, :capacity, :active]
    end

    update :update do
      primary? true
      accept [:name, :day_of_week, :start_time, :duration_minutes, :capacity, :active]
    end

    read :active do
      filter expr(active == true)
    end
  end
end
