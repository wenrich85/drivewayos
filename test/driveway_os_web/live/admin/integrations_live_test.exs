defmodule DrivewayOSWeb.Admin.IntegrationsLiveTest do
  @moduledoc """
  Tenant admin → integrations page. Lists connected integrations
  with pause/resume/disconnect buttons. Empty state shows a "no
  integrations connected" message.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "il-#{System.unique_integer([:positive])}",
        display_name: "Integrations LV Test",
        admin_email: "il-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)

    %{conn: conn, tenant: tenant, admin: admin}
  end

  test "redirects unauthenticated users", _ctx do
    # No sign-in. Use a tenant subdomain host so LoadTenantHook resolves.
    {:ok, %{tenant: t}} =
      Platform.provision_tenant(%{
        slug: "il-anon-#{System.unique_integer([:positive])}",
        display_name: "Anon",
        admin_email: "anon-#{System.unique_integer([:positive])}@example.com",
        admin_name: "A",
        admin_password: "Password123!"
      })

    conn =
      build_conn()
      |> Map.put(:host, "#{t.slug}.lvh.me")

    assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
             live(conn, "/admin/integrations")
  end

  test "empty state when tenant has no AccountingConnections", ctx do
    {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
    assert html =~ "No integrations connected yet"
  end

  test "lists Zoho Books row when an active connection exists", ctx do
    connect_zoho!(ctx.tenant.id)

    {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
    assert html =~ "Zoho Books"
    assert html =~ "Active"
    assert html =~ "Pause"
    assert html =~ "Disconnect"
  end

  test "shows Paused status when auto_sync_enabled is false", ctx do
    conn_row = connect_zoho!(ctx.tenant.id)
    conn_row |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)

    {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
    assert html =~ "Paused"
    assert html =~ "Resume"
  end

  test "Pause button toggles auto_sync_enabled to false", ctx do
    connect_zoho!(ctx.tenant.id)

    {:ok, view, _html} = live(ctx.conn, "/admin/integrations")
    view |> element("button", "Pause") |> render_click()

    {:ok, refreshed} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    refute refreshed.auto_sync_enabled
  end

  test "Disconnect button clears tokens", ctx do
    connect_zoho!(ctx.tenant.id)

    {:ok, view, _html} = live(ctx.conn, "/admin/integrations")
    view |> element("button", "Disconnect") |> render_click()

    {:ok, refreshed} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    assert refreshed.access_token == nil
    assert refreshed.disconnected_at != nil
  end

  test "Disconnect button is hidden on already-disconnected rows", ctx do
    conn_row = connect_zoho!(ctx.tenant.id)
    conn_row |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)

    {:ok, _view, html} = live(ctx.conn, "/admin/integrations")

    assert html =~ "Disconnected"
    refute html =~ ~s(phx-click="disconnect")
  end

  test "Pause does NOT mutate a connection from a different tenant", ctx do
    # Create a second tenant with its own connection
    {:ok, %{tenant: other_tenant}} =
      Platform.provision_tenant(%{
        slug: "other-#{System.unique_integer([:positive])}",
        display_name: "Other Tenant",
        admin_email: "other-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Other",
        admin_password: "Password123!"
      })

    other_conn = connect_zoho!(other_tenant.id)

    # Sign-in as ctx.tenant's admin, render the page (empty for them).
    {:ok, view, _html} = live(ctx.conn, "/admin/integrations")

    # Attempt to pause OTHER tenant's connection by crafting the event.
    # render_click bypasses the DOM filter — exactly what an attacker
    # would do via the browser console / DevTools.
    render_click(view, "pause", %{"id" => other_conn.id})

    # other_conn should still be active (untouched).
    {:ok, refreshed} =
      Platform.get_accounting_connection(other_tenant.id, :zoho_books)

    assert refreshed.auto_sync_enabled == true
  end

  defp connect_zoho!(tenant_id) do
    AccountingConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :zoho_books,
      external_org_id: "999",
      access_token: "at",
      refresh_token: "rt",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    })
    |> Ash.create!(authorize?: false)
  end

  # JWT-in-session sign-in + tenant-subdomain host (mirrors the helper
  # pattern used in customer_detail_live_test.exs).
  defp sign_in_admin_for_tenant(conn, tenant, admin) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

    conn
    |> Plug.Test.init_test_session(%{customer_token: token})
    |> Map.put(:host, "#{tenant.slug}.lvh.me")
  end
end
