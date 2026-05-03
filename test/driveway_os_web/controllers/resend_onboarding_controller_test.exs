defmodule DrivewayOSWeb.ResendOnboardingControllerTest do
  @moduledoc """
  GET /onboarding/resend/start — kicks off Resend API-first
  provisioning for the current admin's tenant. Same shape as
  Postmark's onboarding controller — synchronous provision in the
  start handler, no /callback.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Notifications.ResendClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "re-#{System.unique_integer([:positive])}",
        display_name: "Resend OB Test",
        admin_email: "re-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    Application.put_env(:driveway_os, :resend_api_key, "re_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :resend_api_key) end)

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)
    %{conn: conn, tenant: tenant, admin: admin}
  end

  test "GET /onboarding/resend/start: provisions and redirects on success", ctx do
    expect(ResendClient.Mock, :create_api_key, fn _name ->
      {:ok, %{key_id: "k_x", api_key: "re_test_x"}}
    end)

    conn = get(ctx.conn, "/onboarding/resend/start")
    assert redirected_to(conn) == "/admin/onboarding"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    types = events |> Enum.sort_by(& &1.occurred_at, DateTime) |> Enum.map(& &1.event_type)
    assert types == [:click, :provisioned]
    assert Enum.all?(events, &(&1.provider == :resend))
  end

  test "GET /onboarding/resend/start: error path logs :click only and redirects with flash", ctx do
    expect(ResendClient.Mock, :create_api_key, fn _ ->
      {:error, %{status: 401, body: %{"message" => "Invalid token"}}}
    end)

    conn = get(ctx.conn, "/onboarding/resend/start")
    assert redirected_to(conn) == "/admin/onboarding"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Resend"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    assert [event] = events
    assert event.event_type == :click
  end

  test "GET /onboarding/resend/start: rejects when no current admin", _ctx do
    {:ok, %{tenant: t}} =
      Platform.provision_tenant(%{
        slug: "re-noauth-#{System.unique_integer([:positive])}",
        display_name: "Anon",
        admin_email: "anon-#{System.unique_integer([:positive])}@example.com",
        admin_name: "A",
        admin_password: "Password123!"
      })

    conn =
      build_conn()
      |> Map.put(:host, "#{t.slug}.lvh.me")
      |> get("/onboarding/resend/start")

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
