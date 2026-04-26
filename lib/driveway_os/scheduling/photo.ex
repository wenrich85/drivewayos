defmodule DrivewayOS.Scheduling.Photo do
  @moduledoc """
  An image attached to an Appointment. Customers add `:pre_booking`
  photos in the wizard so the operator can quote / route / pre-stage;
  techs in the field add `:before` / `:after` / `:damage` shots from
  the dispatch screen.

  Tenant-scoped. Both `customer_id` and `appointment_id` get
  cross-tenant FK validation in the `:attach` action — defense in
  depth on top of Ash's multitenancy filter.

  Storage strategy: `storage_path` is the relative path under the
  app's uploads root (`priv/uploads/...` in dev, S3/R2 in prod).
  This resource only knows the path; the upload layer (LiveView
  Upload + a small writer module) owns where the bytes live.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "appointment_photos"
    repo DrivewayOS.Repo

    references do
      reference :customer, on_delete: :delete
      reference :appointment, on_delete: :delete
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

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:pre_booking, :before, :after, :damage]
      default :pre_booking
    end

    attribute :storage_path, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :content_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :byte_size, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :caption, :string do
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

    belongs_to :appointment, DrivewayOS.Scheduling.Appointment do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :attach do
      primary? true

      accept [
        :customer_id,
        :appointment_id,
        :kind,
        :storage_path,
        :content_type,
        :byte_size,
        :caption
      ]

      validate fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :content_type) do
          nil -> :ok
          ct when is_binary(ct) ->
            if String.starts_with?(ct, "image/"),
              do: :ok,
              else: {:error, field: :content_type, message: "must be an image/* MIME type"}
        end
      end

      validate fn changeset, _ ->
        validate_belongs_to_tenant(changeset, :customer_id, DrivewayOS.Accounts.Customer)
      end

      validate fn changeset, _ ->
        validate_belongs_to_tenant(
          changeset,
          :appointment_id,
          DrivewayOS.Scheduling.Appointment
        )
      end
    end

    read :for_appointment do
      argument :appointment_id, :uuid, allow_nil?: false
      filter expr(appointment_id == ^arg(:appointment_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

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
