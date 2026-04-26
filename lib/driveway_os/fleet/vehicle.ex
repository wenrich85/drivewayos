defmodule DrivewayOS.Fleet.Vehicle do
  @moduledoc """
  A customer's saved vehicle. Tenant-scoped; cross-tenant FK
  validation in the `:add` action ensures `customer_id` belongs
  to the current tenant — defense in depth on top of Ash's
  multitenancy filter.

  Booking flow lets the customer pick from `:for_customer` or
  add a new one inline. Once an Appointment is created, its
  `vehicle_description` field captures a snapshot of the
  display_label so historical bookings stay readable even if the
  customer later edits or deletes the vehicle.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Fleet,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "vehicles"
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

    attribute :year, :integer do
      allow_nil? false
      public? true
      # 1900 floor catches obvious typos; +2 future-year buffer for
      # next-year's models that ship in late summer.
      constraints min: 1900, max: 2100
    end

    attribute :make, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60
    end

    attribute :model, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60
    end

    attribute :color, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 30
    end

    attribute :license_plate, :string do
      public? true
      constraints max_length: 15
    end

    attribute :nickname, :string do
      public? true
      constraints max_length: 60
    end

    attribute :notes, :string do
      public? true
      constraints max_length: 500
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

  actions do
    defaults [:read, :destroy]

    create :add do
      primary? true
      accept [:customer_id, :year, :make, :model, :color, :license_plate, :nickname, :notes]

      validate fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :customer_id) do
          nil ->
            :ok

          customer_id ->
            tenant = changeset.tenant

            case Ash.get(DrivewayOS.Accounts.Customer, customer_id,
                   tenant: tenant,
                   authorize?: false
                 ) do
              {:ok, _} -> :ok
              _ -> {:error, field: :customer_id, message: "must belong to the current tenant"}
            end
        end
      end
    end

    update :update do
      primary? true
      accept [:year, :make, :model, :color, :license_plate, :nickname, :notes]
    end

    read :for_customer do
      argument :customer_id, :uuid, allow_nil?: false
      filter expr(customer_id == ^arg(:customer_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  @doc """
  Human-friendly summary used in select boxes + appointment
  snapshots. Falls back to the bare YEAR MAKE MODEL (COLOR) shape
  when no nickname is set.
  """
  @spec display_label(t()) :: String.t()
  def display_label(%{nickname: n} = v) when is_binary(n) and n != "",
    do: "#{n} — #{base_label(v)}"

  def display_label(v), do: base_label(v)

  defp base_label(%{year: y, make: m, model: mo, color: c}),
    do: "#{y} #{m} #{mo} (#{c})"
end
