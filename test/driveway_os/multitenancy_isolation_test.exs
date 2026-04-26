defmodule DrivewayOS.MultitenancyIsolationTest do
  @moduledoc """
  V1 done-criteria gate: every tenant-scoped resource refuses
  cross-tenant reads.

  The load-bearing test suite for the multi-tenancy story. If any
  case here fails, the SaaS thesis is broken — period — and shipping
  to a second tenant is not safe.

  Coverage:

    1. For every Ash-multitenant resource, scoped read on tenant A
       returns ZERO of tenant B's rows.
    2. For every Ash-multitenant resource, an unscoped Ash.read!/1
       raises (forces the explicit `set_tenant` path).
    3. JWT minted for a Customer on tenant A, when presented with
       tenant B as the verification target, fails verification.
    4. The DB-layer query a malicious LV could craft (e.g.
       Repo.all/1 directly) is the ONLY escape hatch — and it
       requires the Repo, not Ash. Documented here so it stays
       visible.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, BlockTemplate, ServiceType}

  require Ash.Query

  @tenant_scoped_resources [
    {Customer, :customer},
    {ServiceType, :service_type},
    {Appointment, :appointment},
    {BlockTemplate, :block_template}
  ]

  setup do
    {:ok, %{tenant: tenant_a, admin: admin_a}} =
      Platform.provision_tenant(%{
        slug: "iso-a-#{System.unique_integer([:positive])}",
        display_name: "Iso A",
        admin_email: "isoa-#{System.unique_integer([:positive])}@example.com",
        admin_name: "A",
        admin_password: "Password123!"
      })

    {:ok, %{tenant: tenant_b, admin: admin_b}} =
      Platform.provision_tenant(%{
        slug: "iso-b-#{System.unique_integer([:positive])}",
        display_name: "Iso B",
        admin_email: "isob-#{System.unique_integer([:positive])}@example.com",
        admin_name: "B",
        admin_password: "Password123!"
      })

    %{tenant_a: tenant_a, admin_a: admin_a, tenant_b: tenant_b, admin_b: admin_b}
  end

  describe "tenant-scoped read isolation" do
    test "Customer: tenant A read can't see tenant B's customers", %{
      tenant_a: a,
      tenant_b: b,
      admin_a: admin_a,
      admin_b: admin_b
    } do
      {:ok, a_results} =
        Customer |> Ash.Query.set_tenant(a.id) |> Ash.read(authorize?: false)

      {:ok, b_results} =
        Customer |> Ash.Query.set_tenant(b.id) |> Ash.read(authorize?: false)

      a_ids = Enum.map(a_results, & &1.id)
      b_ids = Enum.map(b_results, & &1.id)

      assert admin_a.id in a_ids
      refute admin_b.id in a_ids
      assert admin_b.id in b_ids
      refute admin_a.id in b_ids
    end

    test "ServiceType: tenant A read can't see tenant B's services", %{
      tenant_a: a,
      tenant_b: b
    } do
      # Add a uniquely-named service to B so the assertion is sharp.
      {:ok, b_only} =
        ServiceType
        |> Ash.Changeset.for_create(
          :create,
          %{
            slug: "b-only-svc",
            name: "B Only Service",
            base_price_cents: 100,
            duration_minutes: 30
          },
          tenant: b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, a_results} =
        ServiceType |> Ash.Query.set_tenant(a.id) |> Ash.read(authorize?: false)

      refute b_only.id in Enum.map(a_results, & &1.id)
      refute Enum.any?(a_results, &(&1.name == "B Only Service"))
    end

    test "Appointment: tenant A read can't see tenant B's appointments", %{
      tenant_a: a,
      tenant_b: b,
      admin_b: admin_b
    } do
      {:ok, [b_service | _]} =
        ServiceType |> Ash.Query.set_tenant(b.id) |> Ash.read(authorize?: false)

      {:ok, b_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: admin_b.id,
            service_type_id: b_service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: 30,
            price_cents: 1000,
            vehicle_description: "B's Car",
            service_address: "B's Drive"
          },
          tenant: b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, a_appts} =
        Appointment |> Ash.Query.set_tenant(a.id) |> Ash.read(authorize?: false)

      refute b_appt.id in Enum.map(a_appts, & &1.id)
    end

    test "BlockTemplate: tenant A read can't see tenant B's templates", %{
      tenant_a: a,
      tenant_b: b
    } do
      {:ok, b_block} =
        BlockTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "B's slot",
            day_of_week: 1,
            start_time: ~T[10:00:00],
            duration_minutes: 60,
            capacity: 1
          },
          tenant: b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, a_blocks} =
        BlockTemplate |> Ash.Query.set_tenant(a.id) |> Ash.read(authorize?: false)

      refute b_block.id in Enum.map(a_blocks, & &1.id)
    end
  end

  describe "unscoped reads raise" do
    test "Customer.read without tenant raises Ash.Error.Unknown" do
      assert_raise Ash.Error.Invalid, fn -> Customer |> Ash.read!() end
    end

    test "ServiceType.read without tenant raises" do
      assert_raise Ash.Error.Invalid, fn -> ServiceType |> Ash.read!() end
    end

    test "Appointment.read without tenant raises" do
      assert_raise Ash.Error.Invalid, fn -> Appointment |> Ash.read!() end
    end

    test "BlockTemplate.read without tenant raises" do
      assert_raise Ash.Error.Invalid, fn -> BlockTemplate |> Ash.read!() end
    end
  end

  describe "cross-tenant create through cross-tenant FK is blocked" do
    test "Appointment.book with customer_id from another tenant fails", %{
      tenant_a: a,
      admin_b: admin_b
    } do
      {:ok, [a_service | _]} =
        ServiceType |> Ash.Query.set_tenant(a.id) |> Ash.read(authorize?: false)

      result =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: admin_b.id,
            service_type_id: a_service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: 30,
            price_cents: 1000,
            vehicle_description: "X",
            service_address: "Y"
          },
          tenant: a.id
        )
        |> Ash.create(authorize?: false)

      # The Appointment.book action's check_in_tenant guard rejects this.
      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  describe "JWT cross-tenant rejection" do
    test "Customer JWT minted for tenant A fails verification when targeting tenant B",
         %{tenant_a: a, tenant_b: b, admin_a: admin_a} do
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(admin_a)

      # Verifying with tenant: a.id (the right tenant) succeeds
      assert {:ok, _, _} =
               AshAuthentication.Jwt.verify(token, :driveway_os, tenant: a.id)

      # Verifying with tenant: b.id (a different tenant) fails — the
      # JWT carries a tenant claim that's checked at verify-time.
      assert :error =
               AshAuthentication.Jwt.verify(token, :driveway_os, tenant: b.id)
    end
  end

  describe "ID-guessing escalation is blocked" do
    test "Ash.get(Customer, b_admin_id, tenant: a.id) returns :error",
         %{tenant_a: a, admin_b: admin_b} do
      assert {:error, _} = Ash.get(Customer, admin_b.id, tenant: a.id, authorize?: false)
    end

    test "Ash.get(Appointment, b_appt_id, tenant: a.id) returns :error",
         %{tenant_a: a, tenant_b: b, admin_b: admin_b} do
      {:ok, [b_service | _]} =
        ServiceType |> Ash.Query.set_tenant(b.id) |> Ash.read(authorize?: false)

      {:ok, b_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: admin_b.id,
            service_type_id: b_service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: 30,
            price_cents: 1000,
            vehicle_description: "X",
            service_address: "Y"
          },
          tenant: b.id
        )
        |> Ash.create(authorize?: false)

      assert {:error, _} = Ash.get(Appointment, b_appt.id, tenant: a.id, authorize?: false)
    end
  end

  describe "all-resource sweep" do
    @doc """
    Catch-all that ensures any future tenant-scoped Ash resource
    we add to @tenant_scoped_resources is exercised by the
    isolation invariants above. If you add a resource with
    `multitenancy do strategy :attribute end`, append it to that
    list AND to the per-resource read-isolation describe blocks.
    """
    test "sentinel: every listed resource has multitenancy enabled" do
      Enum.each(@tenant_scoped_resources, fn {resource, _label} ->
        assert Ash.Resource.Info.multitenancy_strategy(resource) == :attribute,
               "#{inspect(resource)} should be tenant-scoped via attribute multitenancy"
      end)
    end
  end
end
