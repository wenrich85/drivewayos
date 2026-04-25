defmodule DrivewayOS.Scheduling.ServiceTypeTest do
  @moduledoc """
  V1 Slice 5: per-tenant ServiceType.

  ServiceType is the catalog the customer picks from when booking
  ("Basic Wash $50", "Deep Detail $200"). Tenant admin CRUD's it
  in their admin shell; customer-facing pages render the active
  ones.

  Multitenancy is the headline invariant: same slug across tenants
  is fine; cross-tenant reads are impossible.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

  setup do
    {:ok, tenant_a} = create_tenant!("A")
    {:ok, tenant_b} = create_tenant!("B")
    %{tenant_a: tenant_a, tenant_b: tenant_b}
  end

  describe "create" do
    test "creates a service type scoped to the tenant", %{tenant_a: tenant} do
      {:ok, svc} =
        ServiceType
        |> Ash.Changeset.for_create(
          :create,
          %{
            slug: "basic-wash",
            name: "Basic Wash",
            description: "Exterior + tires + window",
            base_price_cents: 5_000,
            duration_minutes: 45
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert svc.tenant_id == tenant.id
      assert svc.name == "Basic Wash"
      assert svc.base_price_cents == 5_000
      assert svc.duration_minutes == 45
      assert svc.active == true
    end

    test "rejects creation without `tenant:`" do
      assert_raise Ash.Error.Invalid, fn ->
        ServiceType
        |> Ash.Changeset.for_create(:create, %{
          slug: "no-tenant",
          name: "No Tenant",
          base_price_cents: 5_000,
          duration_minutes: 45
        })
        |> Ash.create!(authorize?: false)
      end
    end

    test "rejects negative price", %{tenant_a: tenant} do
      assert {:error, _} =
               ServiceType
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   slug: "freebie",
                   name: "Free",
                   base_price_cents: -100,
                   duration_minutes: 30
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "slug uniqueness" do
    test "same slug rejected within a tenant", %{tenant_a: tenant} do
      {:ok, _} = create_service!(tenant, "basic")
      assert {:error, _} = create_service!(tenant, "basic")
    end

    test "same slug allowed across tenants", %{tenant_a: a, tenant_b: b} do
      {:ok, _} = create_service!(a, "basic")
      {:ok, _} = create_service!(b, "basic")
    end
  end

  describe "cross-tenant read isolation" do
    test "tenant A only sees its own services", %{tenant_a: a, tenant_b: b} do
      {:ok, on_a} = create_service!(a, "a-only")
      {:ok, _on_b} = create_service!(b, "b-only")

      {:ok, a_rows} =
        ServiceType |> Ash.Query.set_tenant(a.id) |> Ash.read(authorize?: false)

      assert length(a_rows) == 1
      assert hd(a_rows).id == on_a.id
    end
  end

  describe "active read" do
    test "only returns rows where active = true", %{tenant_a: tenant} do
      {:ok, on} = create_service!(tenant, "on")
      {:ok, off} = create_service!(tenant, "off")

      off
      |> Ash.Changeset.for_update(:update, %{active: false})
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      {:ok, rows} =
        ServiceType
        |> Ash.Query.for_read(:active)
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      assert length(rows) == 1
      assert hd(rows).id == on.id
    end
  end

  defp create_service!(tenant, slug) do
    ServiceType
    |> Ash.Changeset.for_create(
      :create,
      %{
        slug: slug,
        name: String.capitalize(slug),
        base_price_cents: 5_000,
        duration_minutes: 45
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  defp create_tenant!(name) do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "svc-#{System.unique_integer([:positive])}",
      display_name: name
    })
    |> Ash.create(authorize?: false)
  end
end
