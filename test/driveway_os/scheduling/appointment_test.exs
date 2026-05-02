defmodule DrivewayOS.Scheduling.AppointmentTest do
  @moduledoc """
  V1 Slice 6a: tenant-scoped Appointment resource.

  Carries enough fields for the V1 demo loop (customer, service,
  scheduled_at, vehicle/address as flat strings, status, price). V2
  will split vehicles/addresses into their own resources and add
  block templates.

  Cross-tenant invariants tested at the resource layer here; the LV
  flow that creates appointments lands in Slice 6b.
  """
  use DrivewayOS.DataCase, async: false
  use Oban.Testing, repo: DrivewayOS.Repo

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, tenant_a} = create_tenant!()
    {:ok, tenant_b} = create_tenant!()

    {:ok, customer_a} = create_customer!(tenant_a, "alice@example.com")
    {:ok, customer_b} = create_customer!(tenant_b, "bob@example.com")

    {:ok, service_a} = create_service!(tenant_a)
    {:ok, service_b} = create_service!(tenant_b)

    %{
      tenant_a: tenant_a,
      tenant_b: tenant_b,
      customer_a: customer_a,
      customer_b: customer_b,
      service_a: service_a,
      service_b: service_b
    }
  end

  describe "book" do
    test "creates an appointment scoped to the tenant", ctx do
      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer_a.id,
            service_type_id: ctx.service_a.id,
            scheduled_at: future(),
            vehicle_description: "Blue 2022 Subaru Outback",
            service_address: "123 Cedar St, San Antonio TX 78261",
            price_cents: ctx.service_a.base_price_cents,
            duration_minutes: ctx.service_a.duration_minutes
          },
          tenant: ctx.tenant_a.id
        )
        |> Ash.create(authorize?: false)

      assert appt.tenant_id == ctx.tenant_a.id
      assert appt.customer_id == ctx.customer_a.id
      assert appt.service_type_id == ctx.service_a.id
      assert appt.status == :pending
      assert appt.price_cents == ctx.service_a.base_price_cents
    end

    test "additional_vehicles auto-multiply price_cents at book time", ctx do
      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer_a.id,
            service_type_id: ctx.service_a.id,
            scheduled_at: future(),
            vehicle_description: "Primary BMW 530",
            additional_vehicles: [
              %{"description" => "Secondary Honda Pilot"},
              %{"description" => "Tertiary Mini Cooper"}
            ],
            service_address: "1 Cedar",
            price_cents: ctx.service_a.base_price_cents,
            duration_minutes: ctx.service_a.duration_minutes
          },
          tenant: ctx.tenant_a.id
        )
        |> Ash.create(authorize?: false)

      # The book action normalizes string entries into typed maps
      # and fills in price_cents from the primary's price.
      assert appt.additional_vehicles == [
               %{"description" => "Secondary Honda Pilot", "price_cents" => ctx.service_a.base_price_cents},
               %{"description" => "Tertiary Mini Cooper", "price_cents" => ctx.service_a.base_price_cents}
             ]

      # 1 primary + 2 additional = 3× base price.
      assert appt.price_cents == ctx.service_a.base_price_cents * 3
    end

    test "no additional_vehicles → price_cents unchanged", ctx do
      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer_a.id,
            service_type_id: ctx.service_a.id,
            scheduled_at: future(),
            vehicle_description: "Solo Civic",
            service_address: "2 Cedar",
            price_cents: ctx.service_a.base_price_cents,
            duration_minutes: ctx.service_a.duration_minutes
          },
          tenant: ctx.tenant_a.id
        )
        |> Ash.create(authorize?: false)

      assert appt.additional_vehicles == []
      assert appt.price_cents == ctx.service_a.base_price_cents
    end

    test "scheduled_at must be in the future", ctx do
      assert {:error, _} =
               Appointment
               |> Ash.Changeset.for_create(
                 :book,
                 %{
                   customer_id: ctx.customer_a.id,
                   service_type_id: ctx.service_a.id,
                   scheduled_at: ~U[2020-01-01 12:00:00Z],
                   vehicle_description: "X",
                   service_address: "Y",
                   price_cents: 5_000,
                   duration_minutes: 45
                 },
                 tenant: ctx.tenant_a.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "cross-tenant isolation" do
    test "tenant A cannot book with tenant B's customer", ctx do
      assert {:error, _} =
               Appointment
               |> Ash.Changeset.for_create(
                 :book,
                 %{
                   customer_id: ctx.customer_b.id,
                   service_type_id: ctx.service_a.id,
                   scheduled_at: future(),
                   vehicle_description: "X",
                   service_address: "Y",
                   price_cents: 5_000,
                   duration_minutes: 45
                 },
                 tenant: ctx.tenant_a.id
               )
               |> Ash.create(authorize?: false)
    end

    test "reading appointments scoped to tenant only returns own rows", ctx do
      {:ok, on_a} = book!(ctx.tenant_a, ctx.customer_a, ctx.service_a)
      {:ok, _on_b} = book!(ctx.tenant_b, ctx.customer_b, ctx.service_b)

      {:ok, a_rows} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant_a.id) |> Ash.read(authorize?: false)

      assert length(a_rows) == 1
      assert hd(a_rows).id == on_a.id
    end
  end

  describe "status transitions" do
    test ":confirm flips pending → confirmed", ctx do
      {:ok, appt} = book!(ctx.tenant_a, ctx.customer_a, ctx.service_a)

      {:ok, confirmed} =
        appt
        |> Ash.Changeset.for_update(:confirm, %{})
        |> Ash.update(authorize?: false, tenant: ctx.tenant_a.id)

      assert confirmed.status == :confirmed
    end

    test ":cancel flips to cancelled with reason", ctx do
      {:ok, appt} = book!(ctx.tenant_a, ctx.customer_a, ctx.service_a)

      {:ok, cancelled} =
        appt
        |> Ash.Changeset.for_update(:cancel, %{cancellation_reason: "weather"})
        |> Ash.update(authorize?: false, tenant: ctx.tenant_a.id)

      assert cancelled.status == :cancelled
      assert cancelled.cancellation_reason == "weather"
    end
  end

  describe ":mark_paid enqueues Accounting.SyncWorker (Phase 3 Task 10)" do
    test "enqueues with tenant_id + appointment_id args", ctx do
      {:ok, appt} = book!(ctx.tenant_a, ctx.customer_a, ctx.service_a)

      appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: "pi_test_123"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant_a.id)

      assert_enqueued(
        worker: DrivewayOS.Accounting.SyncWorker,
        args: %{"tenant_id" => ctx.tenant_a.id, "appointment_id" => appt.id}
      )
    end
  end

  defp book!(tenant, customer, service) do
    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: customer.id,
        service_type_id: service.id,
        scheduled_at: future(),
        vehicle_description: "Test vehicle",
        service_address: "1 Test Lane",
        price_cents: service.base_price_cents,
        duration_minutes: service.duration_minutes
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  defp future do
    DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)
  end

  defp create_tenant! do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "appt-#{System.unique_integer([:positive])}",
      display_name: "Appt Test"
    })
    |> Ash.create(authorize?: false)
  end

  defp create_customer!(tenant, email) do
    Customer
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: email,
        password: "Password123!",
        password_confirmation: "Password123!",
        name: "Customer #{email}"
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  defp create_service!(tenant) do
    ServiceType
    |> Ash.Changeset.for_create(
      :create,
      %{
        slug: "basic-#{System.unique_integer([:positive])}",
        name: "Basic Wash",
        base_price_cents: 5_000,
        duration_minutes: 45
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end
end
