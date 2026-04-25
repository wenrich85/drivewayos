defmodule DrivewayOS.Scheduling.Appointment do
  @moduledoc """
  Tenant-scoped appointment — a customer's booking for a specific
  service at a specific time.

  V1 keeps the model simple:

    * `vehicle_description` and `service_address` are flat strings on
      the appointment (no separate Vehicle / Address resources yet).
      V2 splits them out so customers can save vehicles + addresses
      and reuse them across bookings.
    * No block templates / time slots — customers pick any future
      time. V2 adds operator-defined block templates + a route
      optimizer.
    * Stripe payment integration lands in Slice 7. For now an
      appointment can be created without a payment.

  Status lifecycle:

      pending → confirmed → in_progress → completed
                  ↓
                cancelled
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "appointments"
    repo DrivewayOS.Repo

    references do
      reference :customer, on_delete: :restrict
      reference :service_type, on_delete: :restrict
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

    attribute :scheduled_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :duration_minutes, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :confirmed, :in_progress, :completed, :cancelled]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :price_cents, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

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

    attribute :cancellation_reason, :string do
      public? true
      constraints max_length: 300
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
  end

  actions do
    defaults [:read, :destroy]

    create :book do
      primary? true

      accept [
        :customer_id,
        :service_type_id,
        :scheduled_at,
        :duration_minutes,
        :price_cents,
        :vehicle_description,
        :service_address,
        :notes
      ]

      validate compare(:scheduled_at, greater_than: &DateTime.utc_now/0),
        message: "must be in the future"

      # Defense-in-depth: confirm customer_id + service_type_id both
      # exist IN THE CURRENT TENANT'S DATA SLICE. Without this, a
      # caller could insert an appointment with a customer_id from a
      # different tenant (the simple FK only checks the row exists,
      # not that it's in our tenant). Phase 5 of the original
      # migration plan calls for composite FKs at the DB layer for
      # this — until then, this validation closes the gap.
      validate fn changeset, _ ->
        tenant = changeset.tenant

        with :ok <-
               check_in_tenant(
                 DrivewayOS.Accounts.Customer,
                 Ash.Changeset.get_attribute(changeset, :customer_id),
                 tenant,
                 :customer_id
               ),
             :ok <-
               check_in_tenant(
                 DrivewayOS.Scheduling.ServiceType,
                 Ash.Changeset.get_attribute(changeset, :service_type_id),
                 tenant,
                 :service_type_id
               ) do
          :ok
        end
      end
    end

    update :update do
      primary? true

      accept [:scheduled_at, :duration_minutes, :notes]
    end

    update :confirm do
      change set_attribute(:status, :confirmed)
    end

    update :start_wash do
      change set_attribute(:status, :in_progress)
    end

    update :complete do
      change set_attribute(:status, :completed)
    end

    update :cancel do
      argument :cancellation_reason, :string

      change set_attribute(:status, :cancelled)
      change set_attribute(:cancellation_reason, arg(:cancellation_reason))
    end

    read :upcoming do
      filter expr(scheduled_at > ^DateTime.utc_now() and status in [:pending, :confirmed])
      prepare build(sort: [scheduled_at: :asc])
    end

    read :for_customer do
      argument :customer_id, :uuid, allow_nil?: false
      filter expr(customer_id == ^arg(:customer_id))
      prepare build(sort: [scheduled_at: :desc])
    end
  end

  # Helper for the cross-tenant FK validation above. Verifies the
  # given id belongs to a row in the current tenant's data slice.
  defp check_in_tenant(_resource, nil, _tenant, _field), do: :ok

  defp check_in_tenant(resource, id, tenant, field) do
    case Ash.get(resource, id, tenant: tenant, authorize?: false) do
      {:ok, _} -> :ok
      _ -> {:error, field: field, message: "must belong to the current tenant"}
    end
  end
end
