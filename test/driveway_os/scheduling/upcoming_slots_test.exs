defmodule DrivewayOS.Scheduling.UpcomingSlotsTest do
  @moduledoc """
  Expand BlockTemplates into concrete future dated slots that the
  booking form can render. Honors capacity (slot disappears once
  booked to capacity for that date).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling
  alias DrivewayOS.Scheduling.{Appointment, BlockTemplate}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "us-#{System.unique_integer([:positive])}",
        display_name: "Upcoming Slots Tenant",
        admin_email: "us-#{System.unique_integer([:positive])}@example.com",
        admin_name: "US",
        admin_password: "Password123!"
      })

    {:ok, [service | _]} =
      DrivewayOS.Scheduling.ServiceType
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

    %{tenant: tenant, customer: admin, service: service}
  end

  defp create_template!(tenant, attrs) do
    BlockTemplate
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: "Slot",
          duration_minutes: 60,
          capacity: 1
        },
        attrs
      ),
      tenant: tenant.id
    )
    |> Ash.create!(authorize?: false)
  end

  describe "upcoming_slots/2" do
    test "no templates → no slots", %{tenant: tenant} do
      assert Scheduling.upcoming_slots(tenant.id, 14) == []
    end

    # Pick a day_of_week guaranteed to be in the future regardless
    # of when the test runs — tomorrow's weekday — so the
    # "scheduled_at must be in the future" filter never trims our
    # expected first slot.
    defp tomorrow_dow do
      Integer.mod(Date.day_of_week(Date.utc_today() |> Date.add(1), :sunday) - 1, 7)
    end

    test "one weekly template → ~2 slots in a 14-day window", %{tenant: tenant} do
      _bt =
        create_template!(tenant, %{
          name: "Daily morning",
          day_of_week: tomorrow_dow(),
          start_time: ~T[09:00:00]
        })

      slots = Scheduling.upcoming_slots(tenant.id, 14)

      # Should produce 2 slots in 14 days (one each week on the
      # matching weekday).
      assert length(slots) == 2

      assert Enum.all?(slots, fn s ->
               Map.has_key?(s, :scheduled_at) and Map.has_key?(s, :duration_minutes)
             end)
    end

    test "respects capacity — slot disappears when booked-to-capacity",
         %{tenant: tenant, customer: customer, service: service} do
      _bt =
        create_template!(tenant, %{
          name: "Daily morning",
          day_of_week: tomorrow_dow(),
          start_time: ~T[09:00:00],
          capacity: 1
        })

      [_, next_slot | _] = Scheduling.upcoming_slots(tenant.id, 14)

      {:ok, _} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: customer.id,
            service_type_id: service.id,
            scheduled_at: next_slot.scheduled_at,
            duration_minutes: next_slot.duration_minutes,
            price_cents: service.base_price_cents,
            vehicle_description: "Car",
            service_address: "123 Where"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      remaining = Scheduling.upcoming_slots(tenant.id, 14)
      refute Enum.any?(remaining, &(&1.scheduled_at == next_slot.scheduled_at))
    end

    test "skips inactive templates", %{tenant: tenant} do
      bt = create_template!(tenant, %{day_of_week: 0, start_time: ~T[09:00:00]})

      bt
      |> Ash.Changeset.for_update(:update, %{active: false})
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      assert Scheduling.upcoming_slots(tenant.id, 14) == []
    end

    test "skips dates the operator has blocked", %{tenant: tenant} do
      tomorrow = Date.utc_today() |> Date.add(1)
      tomorrow_dow = (Date.day_of_week(tomorrow, :sunday) - 1) |> Integer.mod(7)

      _bt = create_template!(tenant, %{day_of_week: tomorrow_dow, start_time: ~T[09:00:00]})

      DrivewayOS.Scheduling.BlockedDate
      |> Ash.Changeset.for_create(
        :block,
        %{blocked_on: tomorrow, reason: "Vacation"},
        tenant: tenant.id
      )
      |> Ash.create!(authorize?: false)

      slots = Scheduling.upcoming_slots(tenant.id, 14)

      assert Enum.all?(slots, fn s -> DateTime.to_date(s.scheduled_at) != tomorrow end)
    end
  end
end
