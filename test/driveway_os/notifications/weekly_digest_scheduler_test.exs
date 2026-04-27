defmodule DrivewayOS.Notifications.WeeklyDigestSchedulerTest do
  @moduledoc """
  Weekly Monday-morning recap email. Tests pin a deterministic
  `now` so the Monday-7-9am-tenant-local gate is exercised
  precisely.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Notifications.WeeklyDigestScheduler
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "wd-#{System.unique_integer([:positive])}",
        display_name: "Weekly Digest Shop",
        admin_email: "wd-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  # 2026-04-27 was a Monday. 8am Chicago = 13:00 UTC.
  defp monday_8am_chicago, do: ~U[2026-04-27 13:00:00.000000Z]

  defp drain_emails(acc \\ []) do
    receive do
      {:email, %Swoosh.Email{} = e} -> drain_emails([e | acc])
    after
      0 -> acc
    end
  end

  describe "dispatch_due/1" do
    test "sends a digest to each admin on Monday morning local time", ctx do
      drain_emails()

      count = WeeklyDigestScheduler.dispatch_due(monday_8am_chicago())

      assert count == 1

      received = drain_emails()
      subjects = Enum.map(received, & &1.subject)
      assert Enum.any?(subjects, &String.contains?(&1, "Your week"))

      reloaded = Ash.get!(Tenant, ctx.tenant.id, authorize?: false)
      assert reloaded.last_digest_sent_at != nil
    end

    test "skips outside the Monday 7-9am tenant-local window", ctx do
      # Tuesday at 8am Chicago.
      tuesday = ~U[2026-04-28 13:00:00.000000Z]

      assert 0 == WeeklyDigestScheduler.dispatch_due(tuesday)

      reloaded = Ash.get!(Tenant, ctx.tenant.id, authorize?: false)
      assert reloaded.last_digest_sent_at == nil
    end

    test "skips when last_digest_sent_at is within the past 6 days", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:mark_digest_sent, %{})
      |> Ash.update!(authorize?: false)

      assert 0 == WeeklyDigestScheduler.dispatch_due(monday_8am_chicago())
    end

    test "fires again 7+ days later", ctx do
      # Send once.
      WeeklyDigestScheduler.dispatch_due(monday_8am_chicago())

      drain_emails()

      # Move the clock forward 7 days. Still a Monday in Chicago,
      # since 7-day jumps preserve weekday.
      next_monday = ~U[2026-05-04 13:00:00.000000Z]

      assert 1 == WeeklyDigestScheduler.dispatch_due(next_monday)
      _ = ctx
    end

    test "subject mentions the booking count for the week", ctx do
      {:ok, [service | _]} =
        ServiceType |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "wdc-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Customer"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: customer.id,
          service_type_id: service.id,
          scheduled_at: DateTime.utc_now() |> DateTime.add(2 * 86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: service.duration_minutes,
          price_cents: service.base_price_cents,
          vehicle_description: "Truck",
          service_address: "1 Lane"
        },
        tenant: ctx.tenant.id
      )
      |> Ash.create!(authorize?: false)

      drain_emails()
      WeeklyDigestScheduler.dispatch_due(monday_8am_chicago())

      received = drain_emails()
      [email | _] = received
      assert email.subject =~ "1 bookings"
    end

    test "tenant with no admins is silently skipped", ctx do
      ctx.admin
      |> Ash.Changeset.for_update(:update, %{role: :customer})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      assert 0 == WeeklyDigestScheduler.dispatch_due(monday_8am_chicago())
    end
  end
end
