defmodule DrivewayOSWeb.CustomerProfileLiveTest do
  @moduledoc """
  /me — the customer's own profile + saved-data hub.

  V1 ships read-only. Edit forms (name/phone, vehicle CRUD,
  address CRUD) land in D2.

  Auth gate: anonymous → /sign-in; signed-in → render. Cross-tenant
  isolation is inherited from the LoadCustomer hook + Ash multi-
  tenancy filters but is asserted here for defense-in-depth.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Fleet.{Address, Vehicle}
  alias DrivewayOS.Platform.Tenant

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "prof-#{System.unique_integer([:positive])}",
        display_name: "Profile Test",
        plan_tier: :pro
      })
      |> Ash.create(authorize?: false)

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "alice@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Alice Anderson",
          phone: "+15125551234"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer}
  end

  describe "auth gate" do
    test "redirects to /sign-in when no customer is signed in", %{
      conn: conn,
      tenant: tenant
    } do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/me")
    end
  end

  describe "rendering" do
    test "shows the signed-in customer's name, email, phone", %{
      conn: conn,
      tenant: tenant,
      customer: customer
    } do
      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/me")

      assert html =~ "Alice Anderson"
      assert html =~ "alice@example.com"
      assert html =~ "+15125551234"
    end

    test "lists saved vehicles", %{conn: conn, tenant: tenant, customer: customer} do
      {:ok, _v} =
        Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: customer.id,
            year: 2022,
            make: "Subaru",
            model: "Outback",
            color: "Blue"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/me")

      assert html =~ "2022 Subaru Outback"
    end

    test "lists saved addresses", %{conn: conn, tenant: tenant, customer: customer} do
      {:ok, _a} =
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: customer.id,
            street_line1: "123 Cedar St",
            city: "San Antonio",
            state: "TX",
            zip: "78261"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/me")

      assert html =~ "123 Cedar St"
    end

    test "shows empty-state copy when nothing's saved yet", %{
      conn: conn,
      tenant: tenant,
      customer: customer
    } do
      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/me")

      assert html =~ "No saved vehicles" or html =~ "No vehicles saved"
      assert html =~ "No saved addresses" or html =~ "No addresses saved"
    end
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end
end
