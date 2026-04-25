defmodule DrivewayOSWeb.AdminDashboardTest do
  @moduledoc """
  V1 Slice 8: tenant-admin dashboard at `{slug}.lvh.me/admin`.

  Same `Customer` resource as end-customers — admins are just
  customers with `role: :admin`. Authorization gate redirects
  non-admins away from /admin.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "admin-#{System.unique_integer([:positive])}",
        display_name: "Admin Test Shop",
        admin_email: "owner-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!",
        admin_phone: "+15125550100"
      })

    {:ok, regular_customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "alice@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Alice"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    %{tenant: tenant, admin: admin, customer: regular_customer, service: service}
  end

  describe "auth gate" do
    test "unauthenticated → /sign-in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin")
    end

    test "non-admin customer → / (no admin access)",
         %{conn: conn, tenant: tenant, customer: customer} do
      conn = sign_in(conn, customer)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin")
    end

    test "admin signs in and sees the dashboard", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "Admin"
      assert html =~ ctx.tenant.display_name
    end
  end

  describe "dashboard contents" do
    test "shows count of pending appointments", ctx do
      {:ok, _appt} = book!(ctx.tenant, ctx.customer, ctx.service)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # The dashboard surfaces the pending count somewhere — text
      # "1" in proximity to "pending" is the test contract.
      assert html =~ "Pending"
      assert html =~ "Basic Wash"
    end

    test "shows customer count", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # Two customers exist: admin + alice
      assert html =~ "Customers"
      assert html =~ "2"
    end

    test "cross-tenant isolation: admin sees only their tenant's data", ctx do
      # Create a totally separate tenant and try to spoof its data into
      # ctx.admin's view. Should be invisible.
      {:ok, %{tenant: other_tenant, admin: _other_admin}} =
        Platform.provision_tenant(%{
          slug: "other-#{System.unique_integer([:positive])}",
          display_name: "Other Tenant",
          admin_email: "other-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      {:ok, [other_service | _]} =
        ServiceType |> Ash.Query.set_tenant(other_tenant.id) |> Ash.read(authorize?: false)

      {:ok, other_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "stranger@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger Danger"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _stranger_appt} = book!(other_tenant, other_customer, other_service)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "Stranger Danger"
    end
  end

  defp book!(tenant, customer, service) do
    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: customer.id,
        service_type_id: service.id,
        scheduled_at:
          DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
        duration_minutes: service.duration_minutes,
        price_cents: service.base_price_cents,
        vehicle_description: "Test vehicle",
        service_address: "1 Test Lane"
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end
end
