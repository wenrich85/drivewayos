defmodule DrivewayOSWeb.Admin.ServicesLiveTest do
  @moduledoc """
  Tenant admin → service catalog CRUD at `{slug}.lvh.me/admin/services`.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sv-#{System.unique_integer([:positive])}",
        display_name: "Services Admin",
        admin_email: "sv-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  describe "list" do
    test "shows the seeded services", %{conn: conn, tenant: tenant, admin: admin} do
      conn = sign_in(conn, admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/services")

      assert html =~ "Services"
      assert html =~ "Basic Wash"
      assert html =~ "Deep Clean"
    end
  end

  describe "create" do
    test "submits a new service", %{conn: conn, tenant: tenant, admin: admin} do
      conn = sign_in(conn, admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/services")

      html =
        lv
        |> form("#new-service-form", %{
          "service" => %{
            "name" => "Express Detail",
            "slug" => "express-detail",
            "description" => "30-minute spot clean",
            "base_price_dollars" => "75",
            "duration_minutes" => "30"
          }
        })
        |> render_submit()

      assert html =~ "Express Detail"

      {:ok, services} =
        ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

      created = Enum.find(services, &(&1.slug == "express-detail"))
      assert created
      assert created.base_price_cents == 7_500
    end
  end

  describe "deactivate" do
    test "toggles a service inactive", %{conn: conn, tenant: tenant, admin: admin} do
      {:ok, [svc | _]} =
        ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

      conn = sign_in(conn, admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/services")

      lv
      |> element("button[phx-click='toggle_active'][phx-value-id='#{svc.id}']")
      |> render_click()

      reloaded = Ash.get!(ServiceType, svc.id, tenant: tenant.id, authorize?: false)
      assert reloaded.active == false
    end
  end

  describe "edit" do
    test "Edit toggles inline form, save persists name + price + duration", %{
      conn: conn,
      tenant: tenant,
      admin: admin
    } do
      {:ok, [svc | _]} =
        ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

      conn = sign_in(conn, admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/services")

      html = render_click(lv, "edit_service", %{"id" => svc.id})
      assert html =~ "edit-service-form-#{svc.id}"

      lv
      |> form("#edit-service-form-#{svc.id}", %{
        "service" => %{
          "name" => "Express Wash",
          "base_price_dollars" => "75.00",
          "duration_minutes" => "30",
          "description" => "Quick exterior only"
        }
      })
      |> render_submit()

      reloaded = Ash.get!(ServiceType, svc.id, tenant: tenant.id, authorize?: false)
      assert reloaded.name == "Express Wash"
      assert reloaded.base_price_cents == 7500
      assert reloaded.duration_minutes == 30
      assert reloaded.description == "Quick exterior only"
    end

    test "Cancel returns to read mode without changing the row", %{
      conn: conn,
      tenant: tenant,
      admin: admin
    } do
      {:ok, [svc | _]} =
        ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)
      original_name = svc.name

      conn = sign_in(conn, admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/services")

      render_click(lv, "edit_service", %{"id" => svc.id})
      html = render_click(lv, "cancel_edit")

      refute html =~ "edit-service-form-#{svc.id}"

      reloaded = Ash.get!(ServiceType, svc.id, tenant: tenant.id, authorize?: false)
      assert reloaded.name == original_name
    end
  end
end
