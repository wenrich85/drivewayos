defmodule DrivewayOS.Notifications.ReminderSchedulerTest do
  @moduledoc """
  ReminderScheduler hourly sweep — tests drive dispatch_due_reminders/1
  directly with a deterministic `now`. The GenServer itself is not
  started in test (config/test.exs sets `:start_schedulers?` false).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Notifications.ReminderScheduler
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "rem-#{System.unique_integer([:positive])}",
        display_name: "Reminder Test Shop",
        admin_email: "rem-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "remc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Rem Cust"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, customer: customer, service: service}
  end

  defp book_at!(ctx, scheduled_at) do
    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: ctx.customer.id,
        service_type_id: ctx.service.id,
        scheduled_at: scheduled_at,
        duration_minutes: ctx.service.duration_minutes,
        price_cents: ctx.service.base_price_cents,
        vehicle_description: "Reminder Truck",
        service_address: "1 Reminder Lane"
      },
      tenant: ctx.tenant.id
    )
    |> Ash.create!(authorize?: false)
  end

  describe "dispatch_due_reminders/1" do
    test "sends a reminder for an appointment 24h out + marks reminder_sent_at", ctx do
      now = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      one_day_out = DateTime.add(now, 24 * 3600, :second)

      appt = book_at!(ctx, one_day_out)

      count = ReminderScheduler.dispatch_due_reminders(now)

      assert count == 1

      reloaded = Ash.get!(Appointment, appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.reminder_sent_at != nil

      assert_received {:email, %Swoosh.Email{subject: subject, to: [{_, addr}]}}
      assert subject =~ "Reminder"
      assert addr == to_string(ctx.customer.email)
    end

    test "skips appointments outside the 23-25h window", ctx do
      now = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      # 6h out — too soon
      _too_soon = book_at!(ctx, DateTime.add(now, 6 * 3600, :second))
      # 48h out — too far
      _too_far = book_at!(ctx, DateTime.add(now, 48 * 3600, :second))

      count = ReminderScheduler.dispatch_due_reminders(now)
      assert count == 0
    end

    test "doesn't double-send if reminder_sent_at is already set", ctx do
      now = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      one_day_out = DateTime.add(now, 24 * 3600, :second)

      appt = book_at!(ctx, one_day_out)

      # First sweep → 1 sent
      assert ReminderScheduler.dispatch_due_reminders(now) == 1
      _ = appt
      # Second sweep → 0
      assert ReminderScheduler.dispatch_due_reminders(now) == 0
    end

    test "skips cancelled appointments", ctx do
      now = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      one_day_out = DateTime.add(now, 24 * 3600, :second)

      appt = book_at!(ctx, one_day_out)

      appt
      |> Ash.Changeset.for_update(:cancel, %{cancellation_reason: "Test cancel"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      assert ReminderScheduler.dispatch_due_reminders(now) == 0
    end

    test "tenant isolation: a tenant-A appointment can't trigger a tenant-B reminder", _ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "remb-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "remb-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, b_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "rembc-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "B Cust"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, [b_service | _]} =
        ServiceType |> Ash.Query.set_tenant(tenant_b.id) |> Ash.read(authorize?: false)

      now = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      one_day_out = DateTime.add(now, 24 * 3600, :second)

      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: b_customer.id,
          service_type_id: b_service.id,
          scheduled_at: one_day_out,
          duration_minutes: b_service.duration_minutes,
          price_cents: b_service.base_price_cents,
          vehicle_description: "B Truck",
          service_address: "1 B Lane"
        },
        tenant: tenant_b.id
      )
      |> Ash.create!(authorize?: false)

      count = ReminderScheduler.dispatch_due_reminders(now)
      assert count == 1

      # Email sent to tenant B's customer, not tenant A's.
      assert_received {:email, %Swoosh.Email{to: [{_, addr}]}}
      assert addr == to_string(b_customer.email)
    end
  end
end
