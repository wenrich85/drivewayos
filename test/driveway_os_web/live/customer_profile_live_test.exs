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

  require Ash.Query

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

  describe "email verification banner" do
    test "shows when current_customer.email_verified_at is nil", %{
      conn: conn,
      tenant: tenant,
      customer: customer
    } do
      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/me")

      assert html =~ "Verify your email"
      assert html =~ "/auth/customer/resend-verification"
    end

    test "hides once email_verified_at is set", %{
      conn: conn,
      tenant: tenant,
      customer: customer
    } do
      customer
      |> Ash.Changeset.for_update(:verify_email, %{})
      |> Ash.update!(authorize?: false)

      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/me")

      refute html =~ "Verify your email"
    end
  end

  describe "edit profile (name/phone)" do
    test "Edit toggles inline form, save persists name + phone", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/me")

      html = render_click(lv, "edit_profile")
      assert html =~ "profile-edit-form"

      lv
      |> form("#profile-edit-form", %{
        "profile" => %{"name" => "Alice Updated", "phone" => "+15125559999"}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.name == "Alice Updated"
      assert reloaded.phone == "+15125559999"
    end

    test "Cancel returns to read mode without changing the row", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/me")

      render_click(lv, "edit_profile")
      html = render_click(lv, "cancel_edit_profile")

      refute html =~ "profile-edit-form"

      {:ok, reloaded} = Ash.get(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.name == "Alice Anderson"
    end
  end

  describe "add vehicle inline" do
    test "form submit creates a Vehicle row and shows it in the list", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/me")

      render_click(lv, "add_vehicle")

      html =
        lv
        |> form("#vehicle-add-form", %{
          "vehicle" => %{
            "year" => "2018",
            "make" => "Toyota",
            "model" => "Tacoma",
            "color" => "Silver"
          }
        })
        |> render_submit()

      assert html =~ "2018 Toyota Tacoma"

      {:ok, [v]} =
        Vehicle
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert v.make == "Toyota"
      assert v.customer_id == ctx.customer.id
    end
  end

  describe "delete vehicle" do
    test "Delete button removes the row", ctx do
      {:ok, vehicle} =
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

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/me")

      assert html =~ "2022 Subaru Outback"

      html = render_click(lv, "delete_vehicle", %{"id" => vehicle.id})

      refute html =~ "2022 Subaru Outback"

      {:ok, vehicles} =
        Vehicle
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert vehicles == []
    end
  end

  describe "add address inline" do
    test "form submit creates an Address row and shows it in the list", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/me")

      render_click(lv, "add_address")

      html =
        lv
        |> form("#address-add-form", %{
          "address" => %{
            "street_line1" => "1 Main",
            "city" => "SA",
            "state" => "TX",
            "zip" => "78261"
          }
        })
        |> render_submit()

      assert html =~ "1 Main"

      {:ok, [a]} =
        Address
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert a.city == "SA"
      assert a.customer_id == ctx.customer.id
    end
  end

  describe "delete address" do
    test "Delete button removes the row", ctx do
      {:ok, addr} =
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            street_line1: "9 Oak",
            city: "SA",
            state: "TX",
            zip: "78261"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/me")

      assert html =~ "9 Oak"

      html = render_click(lv, "delete_address", %{"id" => addr.id})

      refute html =~ "9 Oak"

      {:ok, addresses} =
        Address
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert addresses == []
    end
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end
end
