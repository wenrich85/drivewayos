defmodule DrivewayOSWeb.Platform.PlansLiveTest do
  @moduledoc """
  Platform admin → SaaS plan editor at admin.lvh.me/plans.

  Lets the operator (us) edit which features are gated to which
  tier, plus pricing + limits. Read-only access for non-platform
  users.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform.PlatformUser

  setup do
    {:ok, platform_user} =
      PlatformUser
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "ops-#{System.unique_integer([:positive])}@drivewayos.com",
        password: "Password123!",
        password_confirmation: "Password123!",
        name: "Ops"
      })
      |> Ash.create(authorize?: false)

    %{platform_user: platform_user}
  end

  defp sign_in_platform(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    conn |> Plug.Test.init_test_session(%{platform_token: token})
  end

  describe "auth gate" do
    test "no platform user → redirect to /platform-sign-in", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/platform-sign-in"}}} =
               conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/plans")
    end
  end

  describe "list" do
    test "shows the three seeded plans", %{conn: conn, platform_user: pu} do
      conn = sign_in_platform(conn, pu)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/plans")

      assert html =~ "Plans"
      assert html =~ "Starter"
      assert html =~ "Pro"
      assert html =~ "Enterprise"
    end

    test "shows feature counts per tier", %{conn: conn, platform_user: pu} do
      conn = sign_in_platform(conn, pu)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/plans")

      # Each tier should display its features list somehow.
      assert html =~ "basic_booking"
      assert html =~ "saved_vehicles"
      assert html =~ "marketing_dashboard"
    end
  end

  describe "edit" do
    test "saving features list updates the tier", %{conn: conn, platform_user: pu} do
      conn = sign_in_platform(conn, pu)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/plans")

      # Toggle a feature OFF for starter — saved_vehicles isn't in
      # starter to begin with, so toggle on the basic_booking off
      # would be destructive. Instead test the price update path.
      lv
      |> form("#plan-starter-form", %{
        "plan" => %{"monthly_cents" => "1900", "name" => "Starter"}
      })
      |> render_submit()

      DrivewayOS.Plans.flush_cache()
      starter = DrivewayOS.Plans.plan_for(:starter)
      assert starter.monthly_cents == 1900
    end

    test "toggling a feature on adds it to the tier", %{conn: conn, platform_user: pu} do
      conn = sign_in_platform(conn, pu)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/plans")

      # Click the "+ Add feature" button for starter and grant it
      # custom_domains.
      lv
      |> element("button[phx-click='toggle_feature'][phx-value-tier='starter'][phx-value-feature='custom_domains']")
      |> render_click()

      DrivewayOS.Plans.flush_cache()
      starter = DrivewayOS.Plans.plan_for(:starter)
      assert "custom_domains" in starter.features
    end
  end
end
