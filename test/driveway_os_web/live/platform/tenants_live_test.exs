defmodule DrivewayOSWeb.Platform.TenantsLiveTest do
  @moduledoc """
  Platform admin → tenant list at admin.lvh.me/tenants.

  Auth: `current_platform_user` must be present (PlatformUser).
  No PlatformUser → bounced to /platform-sign-in.

  Read paths use raw Repo / unscoped Ash queries because Tenant is
  not itself tenant-scoped (it IS the tenant).
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{PlatformUser, Tenant}

  setup do
    # Create at least two tenants so the list renders something
    # interesting.
    {:ok, %{tenant: t1}} =
      Platform.provision_tenant(%{
        slug: "pl-#{System.unique_integer([:positive])}",
        display_name: "Platform Test One",
        admin_email: "p1-#{System.unique_integer([:positive])}@example.com",
        admin_name: "P1",
        admin_password: "Password123!"
      })

    {:ok, %{tenant: t2}} =
      Platform.provision_tenant(%{
        slug: "pl-#{System.unique_integer([:positive])}",
        display_name: "Platform Test Two",
        admin_email: "p2-#{System.unique_integer([:positive])}@example.com",
        admin_name: "P2",
        admin_password: "Password123!"
      })

    {:ok, platform_user} =
      PlatformUser
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "operator-#{System.unique_integer([:positive])}@drivewayos.com",
        password: "Password123!",
        password_confirmation: "Password123!",
        name: "Operator"
      })
      |> Ash.create(authorize?: false)

    %{t1: t1, t2: t2, platform_user: platform_user}
  end

  defp sign_in_platform(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    conn |> Plug.Test.init_test_session(%{platform_token: token})
  end

  describe "auth gate" do
    test "no platform user → redirect to /platform-sign-in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/platform-sign-in"}}} =
               conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/tenants")
    end

    test "wrong host (tenant subdomain) → 404 / redirect away", %{conn: conn, t1: t1} do
      assert {:error, _} =
               conn |> Map.put(:host, "#{t1.slug}.lvh.me") |> live(~p"/tenants")
    end
  end

  describe "list" do
    test "shows all tenants with display names",
         %{conn: conn, platform_user: pu, t1: t1, t2: t2} do
      conn = sign_in_platform(conn, pu)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/tenants")

      assert html =~ "Tenants"
      assert html =~ t1.display_name
      assert html =~ t2.display_name
    end
  end

  describe "suspend / reactivate" do
    test "operator can suspend an active tenant",
         %{conn: conn, platform_user: pu, t1: t1} do
      t1
      |> Ash.Changeset.for_update(:reactivate, %{})
      |> Ash.update!(authorize?: false)

      conn = sign_in_platform(conn, pu)

      {:ok, lv, _} =
        conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/tenants")

      lv
      |> element("button[phx-click='suspend_tenant'][phx-value-id='#{t1.id}']")
      |> render_click()

      reloaded = Ash.get!(Tenant, t1.id, authorize?: false)
      assert reloaded.status == :suspended
    end

    test "operator can reactivate a suspended tenant",
         %{conn: conn, platform_user: pu, t1: t1} do
      t1
      |> Ash.Changeset.for_update(:suspend, %{})
      |> Ash.update!(authorize?: false)

      conn = sign_in_platform(conn, pu)

      {:ok, lv, _} =
        conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/tenants")

      lv
      |> element("button[phx-click='reactivate_tenant'][phx-value-id='#{t1.id}']")
      |> render_click()

      reloaded = Ash.get!(Tenant, t1.id, authorize?: false)
      assert reloaded.status == :active
    end
  end
end
