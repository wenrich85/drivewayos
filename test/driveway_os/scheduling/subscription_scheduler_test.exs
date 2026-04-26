defmodule DrivewayOS.Scheduling.SubscriptionSchedulerTest do
  @moduledoc """
  Hourly sweep that materializes due Subscriptions into
  Appointments. Tests drive `dispatch_due/1` directly with a
  deterministic `now`; the GenServer itself is not started in
  test (config/test.exs sets `:start_schedulers?` false).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType, Subscription, SubscriptionScheduler}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "subs-#{System.unique_integer([:positive])}",
        display_name: "Subscription Scheduler Shop",
        admin_email: "subs-#{System.unique_integer([:positive])}@example.com",
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
          email: "subc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Sub Cust"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer, service: service}
  end

  defp subscribe!(ctx, opts) do
    starts_at =
      Keyword.get_lazy(opts, :starts_at, fn ->
        DateTime.utc_now() |> DateTime.add(86_400, :second)
      end)

    Subscription
    |> Ash.Changeset.for_create(
      :subscribe,
      %{
        customer_id: ctx.customer.id,
        service_type_id: ctx.service.id,
        frequency: Keyword.get(opts, :frequency, :biweekly),
        starts_at: starts_at,
        service_address: Keyword.get(opts, :service_address, "1 Sub Lane"),
        vehicle_description: Keyword.get(opts, :vehicle_description, "Sub Truck")
      },
      tenant: ctx.tenant.id
    )
    |> Ash.create!(authorize?: false)
  end

  describe "dispatch_due/1" do
    test "creates an Appointment from a due subscription + advances next_run_at", ctx do
      now = DateTime.utc_now() |> DateTime.add(-3600, :second)
      due_at = DateTime.add(now, 86_400, :second)

      sub = subscribe!(ctx, starts_at: due_at, frequency: :biweekly)

      count = SubscriptionScheduler.dispatch_due(now)
      assert count == 1

      reloaded = Ash.get!(Subscription, sub.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.last_run_at != nil
      assert DateTime.diff(reloaded.next_run_at, due_at, :day) == 14

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.customer_id == ctx.customer.id
      assert appt.service_address == "1 Sub Lane"
      assert appt.notes =~ "Created from subscription"
      # Appointment.scheduled_at is :utc_datetime (second precision);
      # the sub's :utc_datetime_usec gets truncated. Compare the
      # truncated values.
      assert appt.scheduled_at == DateTime.truncate(due_at, :second)
    end

    test "skips paused + cancelled subs", ctx do
      now = DateTime.utc_now() |> DateTime.add(-3600, :second)
      due_at = DateTime.add(now, 86_400, :second)

      paused = subscribe!(ctx, starts_at: due_at, service_address: "Paused")

      paused
      |> Ash.Changeset.for_update(:pause, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      cancelled = subscribe!(ctx, starts_at: due_at, service_address: "Cancelled")

      cancelled
      |> Ash.Changeset.for_update(:cancel, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      count = SubscriptionScheduler.dispatch_due(now)
      assert count == 0

      {:ok, appts} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appts == []
    end

    test "doesn't double-create on consecutive sweeps (advance moves out of window)", ctx do
      now = DateTime.utc_now() |> DateTime.add(-3600, :second)
      due_at = DateTime.add(now, 86_400, :second)

      _sub = subscribe!(ctx, starts_at: due_at, frequency: :biweekly)

      assert SubscriptionScheduler.dispatch_due(now) == 1
      # Second sweep: next_run_at is now 14 days from the first run,
      # well outside the 3-day lookahead.
      assert SubscriptionScheduler.dispatch_due(now) == 0
    end

    test "tenant isolation: tenant A's sub doesn't create tenant B's appointment", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "subi-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "subi-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, b_cust} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "subbi-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "B Cust"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, [b_service | _]} =
        ServiceType |> Ash.Query.set_tenant(tenant_b.id) |> Ash.read(authorize?: false)

      now = DateTime.utc_now() |> DateTime.add(-3600, :second)
      due_at = DateTime.add(now, 86_400, :second)

      Subscription
      |> Ash.Changeset.for_create(
        :subscribe,
        %{
          customer_id: b_cust.id,
          service_type_id: b_service.id,
          frequency: :weekly,
          starts_at: due_at,
          service_address: "1 B Lane",
          vehicle_description: "B Truck"
        },
        tenant: tenant_b.id
      )
      |> Ash.create!(authorize?: false)

      assert SubscriptionScheduler.dispatch_due(now) == 1

      {:ok, a_appts} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      {:ok, b_appts} =
        Appointment |> Ash.Query.set_tenant(tenant_b.id) |> Ash.read(authorize?: false)

      assert a_appts == []
      assert length(b_appts) == 1
    end
  end
end
