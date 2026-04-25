defmodule DrivewayOSWeb.LandingLiveTest do
  @moduledoc """
  V1 Slice 3: per-tenant landing page + platform marketing landing.

  One route, two render paths chosen by `tenant_context`:

      lvh.me               → MarketingLive  (DrivewayOS-branded)
      {slug}.lvh.me        → TenantLandingLive  (tenant-branded)

  These tests prove the dispatch works and the right copy / branding
  shows up for each context.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform.Tenant

  describe "marketing landing (no tenant)" do
    test "renders DrivewayOS branding when host is the platform host", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "lvh.me")
        |> live(~p"/")

      assert html =~ "DrivewayOS"
      # The platform marketing copy is the only place the product
      # name appears in V1 — tenant pages don't mention it.
    end
  end

  describe "tenant landing" do
    setup do
      {:ok, tenant} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "landing-#{System.unique_integer([:positive])}",
          display_name: "Acme Mobile Wash",
          primary_color_hex: "#FF6600"
        })
        |> Ash.create(authorize?: false)

      %{tenant: tenant}
    end

    test "renders tenant.display_name in the welcome heading", %{conn: conn, tenant: tenant} do
      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> live(~p"/")

      assert html =~ "Acme Mobile Wash"
    end

    test "DOES NOT show platform branding on tenant page", %{conn: conn, tenant: tenant} do
      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> live(~p"/")

      # The product name should never appear in customer-facing tenant
      # surfaces. The only place "DrivewayOS" can leak is the platform
      # marketing/admin pages.
      refute html =~ "DrivewayOS"
    end

    test "applies primary_color_hex to the page", %{conn: conn, tenant: tenant} do
      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> live(~p"/")

      # Branding hook lands somewhere on the page (style attribute,
      # CSS variable, etc.). Just check the value appears at all.
      assert html =~ "FF6600"
    end
  end

  describe "unknown subdomain" do
    test "404s before any LV mounts", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, "nobody-#{System.unique_integer([:positive])}.lvh.me")
        |> get(~p"/")

      assert conn.status == 404
    end
  end
end
