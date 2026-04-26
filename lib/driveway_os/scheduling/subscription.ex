defmodule DrivewayOS.Scheduling.Subscription do
  @moduledoc """
  Recurring booking. The customer says "wash my car every two
  weeks"; an hourly scheduler creates Appointment rows ahead of
  each due date and advances `next_run_at` so the same row drives
  the next iteration.

  Status state machine:
      :active <-> :paused
      :active|:paused -> :cancelled (terminal)

  Frequencies are fixed atoms in V1 (:weekly | :biweekly |
  :monthly). V2 may add custom day-counts; the day-count math
  lives in `:advance_next_run` so adding a new frequency is one
  case-arm.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  @frequencies [:weekly, :biweekly, :monthly]

  postgres do
    table "subscriptions"
    repo DrivewayOS.Repo

    references do
      reference :customer, on_delete: :delete
      reference :service_type, on_delete: :restrict
      reference :vehicle, on_delete: :nilify
      reference :address, on_delete: :nilify
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

    attribute :frequency, :atom do
      allow_nil? false
      public? true
      constraints one_of: @frequencies
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:active, :paused, :cancelled]
      default :active
    end

    attribute :starts_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :next_run_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_run_at, :utc_datetime_usec do
      public? true
    end

    # Snapshot strings — set at subscribe time so the scheduler can
    # build appointments without joining vehicle/address. Updated if
    # the customer changes their saved row but not load-bearing.
    attribute :vehicle_description, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :service_address, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 300
    end

    attribute :notes, :string do
      public? true
      constraints max_length: 1000
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :customer, DrivewayOS.Accounts.Customer do
      allow_nil? false
      public? true
    end

    belongs_to :service_type, DrivewayOS.Scheduling.ServiceType do
      allow_nil? false
      public? true
    end

    belongs_to :vehicle, DrivewayOS.Fleet.Vehicle do
      allow_nil? true
      public? true
    end

    belongs_to :address, DrivewayOS.Fleet.Address do
      allow_nil? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :subscribe do
      primary? true

      accept [
        :customer_id,
        :service_type_id,
        :vehicle_id,
        :address_id,
        :frequency,
        :starts_at,
        :vehicle_description,
        :service_address,
        :notes
      ]

      change fn changeset, _ctx ->
        starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)
        Ash.Changeset.force_change_attribute(changeset, :next_run_at, starts_at)
      end

      validate fn changeset, _ ->
        validate_belongs_to_tenant(changeset, :customer_id, DrivewayOS.Accounts.Customer)
      end

      validate fn changeset, _ ->
        validate_belongs_to_tenant(changeset, :service_type_id, DrivewayOS.Scheduling.ServiceType)
      end

      validate fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :vehicle_id) do
          nil -> :ok
          _ -> validate_belongs_to_tenant(changeset, :vehicle_id, DrivewayOS.Fleet.Vehicle)
        end
      end

      validate fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :address_id) do
          nil -> :ok
          _ -> validate_belongs_to_tenant(changeset, :address_id, DrivewayOS.Fleet.Address)
        end
      end
    end

    update :pause do
      require_atomic? false

      validate fn changeset, _ ->
        case changeset.data.status do
          :active -> :ok
          _ -> {:error, field: :status, message: "can only pause an active subscription"}
        end
      end

      change set_attribute(:status, :paused)
    end

    update :resume do
      require_atomic? false

      validate fn changeset, _ ->
        case changeset.data.status do
          :paused -> :ok
          _ -> {:error, field: :status, message: "can only resume a paused subscription"}
        end
      end

      change set_attribute(:status, :active)
    end

    update :cancel do
      require_atomic? false

      validate fn changeset, _ ->
        case changeset.data.status do
          :cancelled ->
            {:error, field: :status, message: "subscription is already cancelled"}

          _ ->
            :ok
        end
      end

      change set_attribute(:status, :cancelled)
    end

    update :advance_next_run do
      require_atomic? false

      argument :ran_at, :utc_datetime_usec, allow_nil?: false

      change fn changeset, _ctx ->
        ran_at = Ash.Changeset.get_argument(changeset, :ran_at)
        freq = changeset.data.frequency

        next =
          case freq do
            :weekly -> DateTime.add(changeset.data.next_run_at, 7 * 86_400, :second)
            :biweekly -> DateTime.add(changeset.data.next_run_at, 14 * 86_400, :second)
            :monthly -> DateTime.add(changeset.data.next_run_at, 30 * 86_400, :second)
          end

        changeset
        |> Ash.Changeset.force_change_attribute(:last_run_at, ran_at)
        |> Ash.Changeset.force_change_attribute(:next_run_at, next)
      end
    end

    read :due do
      argument :window_start, :utc_datetime_usec, allow_nil?: false
      argument :window_end, :utc_datetime_usec, allow_nil?: false

      filter expr(
               status == :active and
                 next_run_at >= ^arg(:window_start) and
                 next_run_at <= ^arg(:window_end)
             )
    end

    read :for_customer do
      argument :customer_id, :uuid, allow_nil?: false

      filter expr(customer_id == ^arg(:customer_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  @doc "List of all known frequency atoms."
  @spec frequencies() :: [atom()]
  def frequencies, do: @frequencies

  defp validate_belongs_to_tenant(changeset, field, resource) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        :ok

      id ->
        case Ash.get(resource, id, tenant: changeset.tenant, authorize?: false) do
          {:ok, _} -> :ok
          _ -> {:error, field: field, message: "must belong to the current tenant"}
        end
    end
  end
end
