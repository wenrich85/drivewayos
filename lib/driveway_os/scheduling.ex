defmodule DrivewayOS.Scheduling do
  @moduledoc """
  The Scheduling domain — per-tenant catalog (ServiceType), block
  templates, appointments. V1 ships ServiceType first; AppointmentBlock
  / Appointment land in the booking-flow slice.

  Every resource is tenant-scoped via Ash's `:attribute` multitenancy.
  """
  use Ash.Domain

  require Ash.Query

  resources do
    resource DrivewayOS.Scheduling.ServiceType
    resource DrivewayOS.Scheduling.Appointment
    resource DrivewayOS.Scheduling.BlockTemplate
    resource DrivewayOS.Scheduling.Photo
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

  @doc """
  Expand the tenant's active block templates into concrete dated
  slots over the next `days` days. Slots that are already booked
  to capacity are filtered out.

  Returns a list of `%{block_template_id, scheduled_at,
  duration_minutes, name}` maps sorted by scheduled_at ascending.

  Used by the customer-facing booking form when a tenant has
  configured availability templates. With zero templates, returns
  `[]` and the booking form falls back to free-text scheduled_at.
  """
  @spec upcoming_slots(binary(), pos_integer()) :: [map()]
  def upcoming_slots(tenant_id, days) when is_binary(tenant_id) and is_integer(days) do
    {:ok, templates} =
      DrivewayOS.Scheduling.BlockTemplate
      |> Ash.Query.for_read(:active)
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, appointments} =
      DrivewayOS.Scheduling.Appointment
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read(authorize?: false)

    booked_counts =
      appointments
      |> Enum.frequencies_by(fn a -> a.scheduled_at end)

    today = Date.utc_today()

    for template <- templates,
        offset <- 0..(days - 1),
        date = Date.add(today, offset),
        Integer.mod(Date.day_of_week(date, :sunday) - 1, 7) == template.day_of_week,
        scheduled_at = combine_date_time(date, template.start_time),
        DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt,
        Map.get(booked_counts, scheduled_at, 0) < template.capacity do
      %{
        block_template_id: template.id,
        scheduled_at: scheduled_at,
        duration_minutes: template.duration_minutes,
        name: template.name
      }
    end
    |> Enum.sort_by(& &1.scheduled_at, DateTime)
  end

  defp combine_date_time(%Date{} = date, %Time{} = time) do
    {:ok, ndt} = NaiveDateTime.new(date, time)
    DateTime.from_naive!(ndt, "Etc/UTC")
  end
end
