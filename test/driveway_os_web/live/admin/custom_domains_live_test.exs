defmodule DrivewayOSWeb.Admin.CustomDomainsLiveTest do
  @moduledoc """
  Tenant admin → custom domains UI at `{slug}.lvh.me/admin/domains`.

  Lets the operator add a hostname (`book.acmewash.com`), see the
  CNAME instructions, and click "Verify" once DNS is set up.

  Auth: same gate as the dashboard — admin Customer in the current
  tenant.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform

  setup :set_mox_global

  setup do
    DrivewayOS.Platform.DnsResolverMock
    |> stub(:lookup_cname, fn _ -> {:ok, ["edge.lvh.me"]} end)
    |> stub(:lookup_txt, fn _ -> {:ok, []} end)

    :ok
  end

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "cdadmin-#{System.unique_integer([:positive])}",
        display_name: "CD Admin Shop",
        admin_email: "cdowner-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  describe "auth" do
    test "unauthenticated → /sign-in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")
    end
  end

  describe "list" do
    test "shows empty state when no custom domains", %{conn: conn, tenant: tenant, admin: admin} do
      conn = sign_in(conn, admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")

      assert html =~ "Custom domains"
      assert html =~ "No custom domains yet"
    end

    test "lists existing domains with their verified status",
         %{conn: conn, tenant: tenant, admin: admin} do
      {:ok, _} = Platform.add_custom_domain(tenant, "book.example1.com")
      {:ok, second} = Platform.add_custom_domain(tenant, "shop.example2.com")
      {:ok, _} = Platform.verify_custom_domain(second)

      conn = sign_in(conn, admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")

      assert html =~ "book.example1.com"
      assert html =~ "shop.example2.com"
      assert html =~ "Pending"
      assert html =~ "Verified"
    end
  end

  describe "add" do
    test "submits a new domain and shows it", %{conn: conn, tenant: tenant, admin: admin} do
      conn = sign_in(conn, admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")

      hostname = "new-#{System.unique_integer([:positive])}.example.com"

      html =
        lv
        |> form("#add-domain-form", domain: %{hostname: hostname})
        |> render_submit()

      assert html =~ hostname
      assert html =~ "Pending"
    end

    test "shows verification instructions including the token",
         %{conn: conn, tenant: tenant, admin: admin} do
      {:ok, cd} = Platform.add_custom_domain(tenant, "instructions.example.com")

      conn = sign_in(conn, admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")

      # The page must show the user what CNAME to add and what token
      # to put in the verification TXT record.
      assert html =~ cd.verification_token
      assert html =~ "CNAME"
    end

    test "rejects invalid hostnames", %{conn: conn, tenant: tenant, admin: admin} do
      conn = sign_in(conn, admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")

      html =
        lv
        |> form("#add-domain-form", domain: %{hostname: "not a hostname"})
        |> render_submit()

      assert html =~ "must match"
    end
  end

  describe "verify" do
    test "clicking verify flips the domain to verified",
         %{conn: conn, tenant: tenant, admin: admin} do
      {:ok, cd} = Platform.add_custom_domain(tenant, "verifyme.example.com")

      conn = sign_in(conn, admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")

      html =
        lv
        |> element("button[phx-click='verify_domain'][phx-value-id='#{cd.id}']")
        |> render_click()

      assert html =~ "Verified"
    end
  end

  describe "cross-tenant isolation" do
    test "admin doesn't see another tenant's domains",
         %{conn: conn, tenant: tenant, admin: admin} do
      {:ok, %{tenant: other_tenant}} =
        Platform.provision_tenant(%{
          slug: "other-cd-#{System.unique_integer([:positive])}",
          display_name: "Other CD Shop",
          admin_email: "othercd-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      {:ok, _} = Platform.add_custom_domain(other_tenant, "stranger-domain.example.com")

      conn = sign_in(conn, admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/domains")

      refute html =~ "stranger-domain.example.com"
    end
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end
end
