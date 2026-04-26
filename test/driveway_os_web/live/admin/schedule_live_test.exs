defmodule DrivewayOSWeb.Admin.ScheduleLiveTest do
  @moduledoc """
  Tenant admin → schedule template UI at `{slug}.lvh.me/admin/schedule`.
  Lets the operator add / remove weekly availability blocks.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.BlockTemplate

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sl-#{System.unique_integer([:positive])}",
        display_name: "Schedule Admin Shop",
        admin_email: "sl-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  describe "auth" do
    test "unauthenticated → /sign-in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/schedule")
    end
  end

  describe "list" do
    test "empty state when no templates", %{conn: conn, tenant: tenant, admin: admin} do
      conn = sign_in(conn, admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/schedule")

      assert html =~ "Availability"
      assert html =~ "No availability"
    end
  end

  describe "create" do
    test "submits a new template + appears in list",
         %{conn: conn, tenant: tenant, admin: admin} do
      conn = sign_in(conn, admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/schedule")

      html =
        lv
        |> form("#new-block-form", %{
          "block" => %{
            "name" => "Wed mornings",
            "day_of_week" => "3",
            "start_time" => "09:00",
            "duration_minutes" => "180",
            "capacity" => "1"
          }
        })
        |> render_submit()

      assert html =~ "Wed mornings"

      {:ok, [bt | _]} =
        BlockTemplate |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

      assert bt.day_of_week == 3
      assert bt.duration_minutes == 180
    end
  end

  describe "delete" do
    test "removes a template", %{conn: conn, tenant: tenant, admin: admin} do
      {:ok, bt} =
        BlockTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Going away",
            day_of_week: 1,
            start_time: ~T[10:00:00],
            duration_minutes: 60,
            capacity: 1
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(conn, admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/schedule")

      html =
        lv
        |> element("button[phx-click='delete_block'][phx-value-id='#{bt.id}']")
        |> render_click()

      refute html =~ "Going away"
    end
  end

  describe "edit" do
    test "Edit toggles the inline form, save persists changes", %{
      conn: conn,
      tenant: tenant,
      admin: admin
    } do
      {:ok, bt} =
        BlockTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Original",
            day_of_week: 1,
            start_time: ~T[09:00:00],
            duration_minutes: 60,
            capacity: 1
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(conn, admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/schedule")

      html = render_click(lv, "edit_block", %{"id" => bt.id})
      assert html =~ "edit-block-form-#{bt.id}"

      lv
      |> form("#edit-block-form-#{bt.id}", %{
        "block" => %{
          "name" => "Renamed",
          "day_of_week" => "2",
          "start_time" => "10:30",
          "duration_minutes" => "90",
          "capacity" => "2"
        }
      })
      |> render_submit()

      reloaded = Ash.get!(BlockTemplate, bt.id, tenant: tenant.id, authorize?: false)

      assert reloaded.name == "Renamed"
      assert reloaded.day_of_week == 2
      assert reloaded.start_time == ~T[10:30:00]
      assert reloaded.duration_minutes == 90
      assert reloaded.capacity == 2
    end
  end
end
