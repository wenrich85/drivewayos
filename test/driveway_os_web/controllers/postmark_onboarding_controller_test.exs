defmodule DrivewayOSWeb.PostmarkOnboardingControllerTest do
  @moduledoc """
  GET /onboarding/postmark/start — kicks off Postmark API-first
  provisioning for the current admin's tenant. Mirrors Phase 4's
  SquareOauthController shape but for an API-first provider:
  there's no separate /callback step — provision runs synchronously
  in the start handler and redirects.

  Logs :click before provision and :provisioned on success.
  Surfaces error to flash on failure.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "po-#{System.unique_integer([:positive])}",
        display_name: "Postmark OB Test",
        admin_email: "po-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)
    %{conn: conn, tenant: tenant, admin: admin}
  end

  test "GET /onboarding/postmark/start: provisions and redirects on success", ctx do
    Application.put_env(:driveway_os, :postmark_account_token, "pt_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :postmark_account_token) end)

    expect(PostmarkClient.Mock, :create_server, fn _name, _opts ->
      {:ok, %{server_id: 88_001, api_key: "server-token-pq"}}
    end)

    conn = get(ctx.conn, "/onboarding/postmark/start")
    assert redirected_to(conn) == "/admin/onboarding"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    types = events |> Enum.sort_by(& &1.occurred_at, DateTime) |> Enum.map(& &1.event_type)
    assert types == [:click, :provisioned]
    assert Enum.all?(events, &(&1.provider == :postmark))
  end

  test "GET /onboarding/postmark/start: error path logs :click only and redirects with flash", ctx do
    Application.put_env(:driveway_os, :postmark_account_token, "pt_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :postmark_account_token) end)

    expect(PostmarkClient.Mock, :create_server, fn _, _ ->
      {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
    end)

    conn = get(ctx.conn, "/onboarding/postmark/start")
    assert redirected_to(conn) == "/admin/onboarding"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Postmark"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    assert [event] = events
    assert event.event_type == :click
  end

  test "GET /onboarding/postmark/start: rejects when no current admin", _ctx do
    {:ok, %{tenant: t}} =
      Platform.provision_tenant(%{
        slug: "po-noauth-#{System.unique_integer([:positive])}",
        display_name: "Anon",
        admin_email: "anon-#{System.unique_integer([:positive])}@example.com",
        admin_name: "A",
        admin_password: "Password123!"
      })

    conn =
      build_conn()
      |> Map.put(:host, "#{t.slug}.lvh.me")
      |> get("/onboarding/postmark/start")

    # Existing tenant LoadCustomer plug pattern: redirect to /sign-in
    assert redirected_to(conn) =~ "/sign-in"
  end

  defp sign_in_admin_for_tenant(conn, tenant, admin) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

    conn
    |> Plug.Test.init_test_session(%{customer_token: token})
    |> Map.put(:host, "#{tenant.slug}.lvh.me")
  end
end
