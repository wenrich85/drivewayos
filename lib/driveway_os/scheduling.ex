defmodule DrivewayOS.Scheduling do
  @moduledoc """
  The Scheduling domain — per-tenant catalog (ServiceType), block
  templates, appointments. V1 ships ServiceType first; AppointmentBlock
  / Appointment land in the booking-flow slice.

  Every resource is tenant-scoped via Ash's `:attribute` multitenancy.
  """
  use Ash.Domain

  resources do
    resource DrivewayOS.Scheduling.ServiceType
  end

  @default_service_types [
    %{
      slug: "basic-wash",
      name: "Basic Wash",
      description:
        "Exterior hand wash, tires, windows, towel dry. The everyday maintenance wash.",
      base_price_cents: 5_000,
      duration_minutes: 45,
      sort_order: 10
    },
    %{
      slug: "deep-clean",
      name: "Deep Clean & Detail",
      description:
        "Full interior + exterior detail: clay bar, wax, carpet shampoo, leather conditioning.",
      base_price_cents: 20_000,
      duration_minutes: 120,
      sort_order: 20
    }
  ]

  @doc """
  Seed the canonical pair of services for a freshly-provisioned
  tenant. Called from `Platform.provision_tenant/1` inside the same
  transaction. Returns `:ok` on success or `{:error, reason}` so the
  caller can roll back.
  """
  @spec seed_default_service_types(binary()) :: :ok | {:error, term()}
  def seed_default_service_types(tenant_id) when is_binary(tenant_id) do
    Enum.reduce_while(@default_service_types, :ok, fn attrs, :ok ->
      case DrivewayOS.Scheduling.ServiceType
           |> Ash.Changeset.for_create(:create, attrs, tenant: tenant_id)
           |> Ash.create(authorize?: false) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
