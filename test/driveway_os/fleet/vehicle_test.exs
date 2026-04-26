defmodule DrivewayOS.Fleet.VehicleTest do
  @moduledoc """
  Customer-owned vehicles. Tenant-scoped. Booking flow lets the
  customer pick from saved vehicles or add a new one inline.

  V1 contract:
    * Tenant-scoped via Ash :attribute multitenancy
    * Belongs to a Customer (FK + cross-tenant validation at the
      app layer — same pattern as Appointment.customer_id)
    * Required: year + make + model + color
    * Optional: license_plate, nickname, notes
    * `display_label/1` returns the human-friendly summary used
      in select boxes ("2022 Subaru Outback (Blue)")
    * `:for_customer` read action lists a customer's vehicles
      newest-first
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Fleet.Vehicle
  alias DrivewayOS.Platform

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "veh-#{System.unique_integer([:positive])}",
        display_name: "Vehicle Test Shop",
        admin_email: "veh-#{System.unique_integer([:positive])}@example.com",
        admin_name: "VehAdmin",
        admin_password: "Password123!"
      })

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "vc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Veh Customer"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, customer: customer}
  end

  describe "create" do
    test "valid vehicle with required fields", ctx do
      {:ok, v} =
        Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            year: 2022,
            make: "Subaru",
            model: "Outback",
            color: "Blue"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert v.tenant_id == ctx.tenant.id
      assert v.customer_id == ctx.customer.id
      assert v.year == 2022
      assert v.make == "Subaru"
    end

    test "rejects implausible year", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Vehicle
               |> Ash.Changeset.for_create(
                 :add,
                 %{
                   customer_id: ctx.customer.id,
                   year: 1800,
                   make: "Stanley",
                   model: "Steamer",
                   color: "Black"
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "cross-tenant FK validation: rejects a customer_id from another tenant",
         %{tenant: tenant} do
      {:ok, %{tenant: other_tenant}} =
        Platform.provision_tenant(%{
          slug: "vot-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "vot-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
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

      # tenant A booking a vehicle for a customer that belongs to
      # tenant B must fail (defense-in-depth — the Ash multitenancy
      # filter alone wouldn't catch this since customer_id is just
      # an FK).
      assert {:error, _} =
               Vehicle
               |> Ash.Changeset.for_create(
                 :add,
                 %{
                   customer_id: stranger.id,
                   year: 2022,
                   make: "Subaru",
                   model: "Outback",
                   color: "Blue"
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "display_label/1" do
    test "format: 'YEAR MAKE MODEL (COLOR)'", ctx do
      {:ok, v} =
        Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            year: 2022,
            make: "Subaru",
            model: "Outback",
            color: "Blue"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert Vehicle.display_label(v) == "2022 Subaru Outback (Blue)"
    end

    test "uses nickname when present", ctx do
      {:ok, v} =
        Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            year: 2018,
            make: "Toyota",
            model: "Tacoma",
            color: "Silver",
            nickname: "Work truck"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert Vehicle.display_label(v) == "Work truck — 2018 Toyota Tacoma (Silver)"
    end
  end

  describe ":for_customer read action" do
    test "lists a customer's vehicles newest-first", ctx do
      Enum.each([2018, 2020, 2022], fn yr ->
        Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            year: yr,
            make: "Honda",
            model: "Accord",
            color: "Red"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create!(authorize?: false)
      end)

      {:ok, vs} =
        Vehicle
        |> Ash.Query.for_read(:for_customer, %{customer_id: ctx.customer.id})
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      # Newest first by inserted_at — the last one we created
      # (year 2022) ends up first.
      assert length(vs) == 3
      [first, _, _] = vs
      assert first.year == 2022
    end
  end

  describe "tenant isolation" do
    test "tenant A can't read tenant B's vehicles", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "vib-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "vib-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, b_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "bc-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "B Cust"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _} =
        Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: b_customer.id,
            year: 2021,
            make: "Tesla",
            model: "Model 3",
            color: "White"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, results_for_a} =
        Vehicle
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert results_for_a == []
    end
  end
end
