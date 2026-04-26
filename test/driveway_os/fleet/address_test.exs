defmodule DrivewayOS.Fleet.AddressTest do
  @moduledoc """
  Customer-owned service addresses. Tenant-scoped + per-customer.

  V1 contract:
    * Required: street_line1, city, state, zip
    * Optional: street_line2, nickname, instructions
    * lat/lon set by the geocoding hook (Phase B+ wires a real
      provider; V1's default impl is a no-op that leaves them nil)
    * `:for_customer` read action lists a customer's addresses
      newest-first
    * `display_label/1` flattens to "123 Cedar St, San Antonio TX 78261"
    * Cross-tenant FK validation matches the Vehicle pattern

  Zone assignment lives in Phase B alongside the route optimizer.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Fleet.Address
  alias DrivewayOS.Platform

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "addr-#{System.unique_integer([:positive])}",
        display_name: "Address Test Shop",
        admin_email: "addr-#{System.unique_integer([:positive])}@example.com",
        admin_name: "AddrAdmin",
        admin_password: "Password123!"
      })

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "ac-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Addr Customer"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer}
  end

  describe "create" do
    test "valid address with required fields", ctx do
      {:ok, a} =
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            street_line1: "123 Cedar St",
            city: "San Antonio",
            state: "TX",
            zip: "78261"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert a.tenant_id == ctx.tenant.id
      assert a.customer_id == ctx.customer.id
      assert a.street_line1 == "123 Cedar St"
      assert a.city == "San Antonio"
      assert a.state == "TX"
      assert a.zip == "78261"
      # No geocoding hook configured in test → lat/lon stay nil.
      assert is_nil(a.lat)
      assert is_nil(a.lon)
    end

    test "rejects 1-character state code", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Address
               |> Ash.Changeset.for_create(
                 :add,
                 %{
                   customer_id: ctx.customer.id,
                   street_line1: "1 Main",
                   city: "Austin",
                   state: "T",
                   zip: "78701"
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "rejects malformed zip", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Address
               |> Ash.Changeset.for_create(
                 :add,
                 %{
                   customer_id: ctx.customer.id,
                   street_line1: "1 Main",
                   city: "Austin",
                   state: "TX",
                   zip: "ABCDE"
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "cross-tenant FK validation rejects another tenant's customer", %{tenant: tenant} do
      {:ok, %{tenant: other}} =
        Platform.provision_tenant(%{
          slug: "addrx-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "addrx-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      {:ok, stranger} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "addr-strg-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger"
          },
          tenant: other.id
        )
        |> Ash.create(authorize?: false)

      assert {:error, _} =
               Address
               |> Ash.Changeset.for_create(
                 :add,
                 %{
                   customer_id: stranger.id,
                   street_line1: "1 Cross",
                   city: "Austin",
                   state: "TX",
                   zip: "78701"
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "geocoding hook" do
    test "Live impl no-ops when no provider is configured" do
      # Default impl in test env is the no-op stub; lat/lon stay nil.
      assert {:ok, %{lat: nil, lon: nil}} = DrivewayOS.Fleet.Geocoder.lookup("78261")
    end
  end

  describe "display_label/1" do
    test "flattens to single-line address", ctx do
      {:ok, a} =
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            street_line1: "123 Cedar St",
            street_line2: "Apt 4B",
            city: "San Antonio",
            state: "TX",
            zip: "78261"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert Address.display_label(a) == "123 Cedar St Apt 4B, San Antonio TX 78261"
    end

    test "uses nickname when present", ctx do
      {:ok, a} =
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            street_line1: "456 Oak Ln",
            city: "Austin",
            state: "TX",
            zip: "78701",
            nickname: "Home"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert Address.display_label(a) == "Home — 456 Oak Ln, Austin TX 78701"
    end
  end

  describe ":for_customer read action" do
    test "lists a customer's addresses newest-first", ctx do
      Enum.each(["111 A", "222 B", "333 C"], fn line ->
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            street_line1: line,
            city: "Austin",
            state: "TX",
            zip: "78701"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create!(authorize?: false)
      end)

      {:ok, addresses} =
        Address
        |> Ash.Query.for_read(:for_customer, %{customer_id: ctx.customer.id})
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert length(addresses) == 3
      [first, _, _] = addresses
      assert first.street_line1 == "333 C"
    end
  end

  describe "tenant isolation" do
    test "tenant A can't see tenant B's addresses", ctx do
      {:ok, %{tenant: b}} =
        Platform.provision_tenant(%{
          slug: "addrb-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "addrb-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, b_cust} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "addr-b-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "B Cust"
          },
          tenant: b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _} =
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: b_cust.id,
            street_line1: "999 Hidden",
            city: "Austin",
            state: "TX",
            zip: "78701"
          },
          tenant: b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, results} =
        Address
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert results == []
    end
  end
end
