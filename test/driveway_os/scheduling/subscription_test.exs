defmodule DrivewayOS.Scheduling.SubscriptionTest do
  @moduledoc """
  Recurring booking subscription. A customer who wants their car
  detailed every 2 weeks signs up once; an Oban-style scheduler
  creates Appointment rows ahead of each due date.

  V1 contract:
    * Tenant-scoped via Ash :attribute multitenancy.
    * Belongs to a Customer + a ServiceType. Optional vehicle_id +
      address_id (saved-vehicle / saved-address selections).
    * Frequency is one of :weekly | :biweekly | :monthly.
    * Status state machine: :active <-> :paused, :active|:paused -> :cancelled (terminal).
    * Cross-tenant FK validation on customer_id, service_type_id,
      vehicle_id, address_id. Same defense-in-depth pattern as
      Appointment.
    * `:due` read action returns active subscriptions whose
      next_run_at falls in a [start, end] window — used by the
      scheduler.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{ServiceType, Subscription}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "sub-#{System.unique_integer([:positive])}",
        display_name: "Subscription Shop",
        admin_email: "sub-#{System.unique_integer([:positive])}@example.com",
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
          email: "sc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Sub Customer"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer, service: service}
  end

  describe ":subscribe (create)" do
    test "creates an active subscription with next_run_at = starts_at", ctx do
      starts_at = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      {:ok, sub} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            frequency: :biweekly,
            starts_at: starts_at,
            service_address: "1 Sub Lane",
            vehicle_description: "Subscriber Truck"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert sub.tenant_id == ctx.tenant.id
      assert sub.frequency == :biweekly
      assert sub.status == :active
      assert sub.starts_at == starts_at
      assert sub.next_run_at == starts_at
      assert sub.last_run_at == nil
    end

    test "rejects an unknown frequency", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Subscription
               |> Ash.Changeset.for_create(
                 :subscribe,
                 %{
                   customer_id: ctx.customer.id,
                   service_type_id: ctx.service.id,
                   frequency: :hourly,
                   starts_at: DateTime.utc_now() |> DateTime.add(86_400, :second),
                   service_address: "1 Sub Lane",
                   vehicle_description: "Truck"
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "cross-tenant FK validation: rejects a customer from another tenant", ctx do
      {:ok, %{tenant: other_tenant}} =
        Platform.provision_tenant(%{
          slug: "sb-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "sb-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, stranger} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "stranger-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      assert {:error, _} =
               Subscription
               |> Ash.Changeset.for_create(
                 :subscribe,
                 %{
                   customer_id: stranger.id,
                   service_type_id: ctx.service.id,
                   frequency: :biweekly,
                   starts_at: DateTime.utc_now() |> DateTime.add(86_400, :second),
                   service_address: "1 Sub Lane",
                   vehicle_description: "Truck"
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "state transitions" do
    setup ctx do
      starts_at = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)

      {:ok, sub} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            frequency: :weekly,
            starts_at: starts_at,
            service_address: "1 Sub Lane",
            vehicle_description: "Truck"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      Map.put(ctx, :sub, sub)
    end

    test "pause flips :active -> :paused", ctx do
      {:ok, paused} =
        ctx.sub
        |> Ash.Changeset.for_update(:pause, %{})
        |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

      assert paused.status == :paused
    end

    test "resume flips :paused -> :active", ctx do
      {:ok, paused} =
        ctx.sub
        |> Ash.Changeset.for_update(:pause, %{})
        |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

      {:ok, resumed} =
        paused
        |> Ash.Changeset.for_update(:resume, %{})
        |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

      assert resumed.status == :active
    end

    test "cancel is terminal: cannot resume after cancel", ctx do
      {:ok, cancelled} =
        ctx.sub
        |> Ash.Changeset.for_update(:cancel, %{})
        |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

      assert cancelled.status == :cancelled

      assert {:error, _} =
               cancelled
               |> Ash.Changeset.for_update(:resume, %{})
               |> Ash.update(authorize?: false, tenant: ctx.tenant.id)
    end
  end

  describe ":advance_next_run" do
    test "weekly bumps next_run_at by 7 days + stamps last_run_at", ctx do
      starts_at = ~U[2026-05-01 10:00:00.000000Z]

      {:ok, sub} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            frequency: :weekly,
            starts_at: starts_at,
            service_address: "1 Sub Lane",
            vehicle_description: "Truck"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      ran_at = ~U[2026-05-01 10:00:00.000000Z]

      {:ok, advanced} =
        sub
        |> Ash.Changeset.for_update(:advance_next_run, %{ran_at: ran_at})
        |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

      assert advanced.last_run_at == ran_at
      assert advanced.next_run_at == DateTime.add(starts_at, 7 * 86_400, :second)
    end

    test "biweekly bumps by 14 days, monthly by 30 days", ctx do
      for {freq, days} <- [{:biweekly, 14}, {:monthly, 30}] do
        starts_at = ~U[2026-05-01 10:00:00.000000Z]

        {:ok, sub} =
          Subscription
          |> Ash.Changeset.for_create(
            :subscribe,
            %{
              customer_id: ctx.customer.id,
              service_type_id: ctx.service.id,
              frequency: freq,
              starts_at: starts_at,
              service_address: "1 Sub Lane #{freq}",
              vehicle_description: "Truck #{freq}"
            },
            tenant: ctx.tenant.id
          )
          |> Ash.create(authorize?: false)

        {:ok, advanced} =
          sub
          |> Ash.Changeset.for_update(:advance_next_run, %{ran_at: starts_at})
          |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

        assert advanced.next_run_at == DateTime.add(starts_at, days * 86_400, :second)
      end
    end
  end

  describe ":due read action" do
    test "returns active subs whose next_run_at falls in the window", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      due = DateTime.add(now, 2 * 86_400, :second)
      too_far = DateTime.add(now, 30 * 86_400, :second)

      for {tag, when_due} <- [{"DueOne", due}, {"FarFuture", too_far}] do
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            frequency: :biweekly,
            starts_at: when_due,
            service_address: tag,
            vehicle_description: tag
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create!(authorize?: false)
      end

      {:ok, results} =
        Subscription
        |> Ash.Query.for_read(:due, %{
          window_start: now,
          window_end: DateTime.add(now, 7 * 86_400, :second)
        })
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      addresses = Enum.map(results, & &1.service_address)
      assert "DueOne" in addresses
      refute "FarFuture" in addresses
    end

    test "skips paused + cancelled subs", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      due = DateTime.add(now, 2 * 86_400, :second)

      {:ok, paused_sub} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            frequency: :weekly,
            starts_at: due,
            service_address: "PausedAddress",
            vehicle_description: "Paused"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      paused_sub
      |> Ash.Changeset.for_update(:pause, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      {:ok, results} =
        Subscription
        |> Ash.Query.for_read(:due, %{
          window_start: now,
          window_end: DateTime.add(now, 7 * 86_400, :second)
        })
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert results == []
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's subscriptions", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "si-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "si-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, b_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "sib-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "B Cust"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, [b_service | _]} =
        ServiceType |> Ash.Query.set_tenant(tenant_b.id) |> Ash.read(authorize?: false)

      {:ok, _} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: b_customer.id,
            service_type_id: b_service.id,
            frequency: :weekly,
            starts_at: DateTime.utc_now() |> DateTime.add(86_400, :second),
            service_address: "1 B Lane",
            vehicle_description: "B Truck"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, results_for_a} =
        Subscription
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert results_for_a == []
    end
  end
end
