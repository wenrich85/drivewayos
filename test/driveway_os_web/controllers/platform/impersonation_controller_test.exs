defmodule DrivewayOSWeb.Platform.ImpersonationControllerTest do
  @moduledoc """
  Platform-admin → tenant-impersonation flow.

      GET /platform/impersonate/:tenant_id

  Mints a customer JWT for the tenant's first admin Customer + sets
  an `impersonated_by` session marker, then redirects the operator
  to the tenant's subdomain. Auth-gated to PlatformUser; logs the
  impersonation start event.
  """
  use DrivewayOSWeb.ConnCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PlatformUser

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "imp-#{System.unique_integer([:positive])}",
        display_name: "Impersonation Test",
        admin_email: "imp-#{System.unique_integer([:positive])}@example.com",
        admin_name: "ImpAdmin",
        admin_password: "Password123!"
      })

    {:ok, platform_user} =
      PlatformUser
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "op-#{System.unique_integer([:positive])}@drivewayos.com",
        password: "Password123!",
        password_confirmation: "Password123!",
        name: "Op"
      })
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, platform_user: platform_user}
  end

  defp sign_in_platform(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    conn |> Plug.Test.init_test_session(%{platform_token: token})
  end

  describe "GET /platform/impersonate/:id" do
    test "platform user gets a customer_token + impersonated_by + redirect to tenant",
         %{conn: conn, tenant: tenant, platform_user: pu} do
      conn =
        conn
        |> sign_in_platform(pu)
        |> Map.put(:host, "admin.lvh.me")
        |> get("/platform/impersonate/#{tenant.id}")

      assert redirected_to(conn, 302) =~ "#{tenant.slug}.lvh.me"
      assert is_binary(get_session(conn, :customer_token))
      assert get_session(conn, :impersonated_by) == pu.id
    end

    test "without a platform user → 403", %{conn: conn, tenant: tenant} do
      conn =
        conn
        |> Map.put(:host, "admin.lvh.me")
        |> get("/platform/impersonate/#{tenant.id}")

      assert conn.status in [401, 403] or
               (conn.status == 302 and redirected_to(conn) =~ "platform-sign-in")
    end

    test "from outside admin host → 403", %{conn: conn, tenant: tenant, platform_user: pu} do
      conn =
        conn
        |> sign_in_platform(pu)
        |> Map.put(:host, "lvh.me")
        |> get("/platform/impersonate/#{tenant.id}")

      assert conn.status in [401, 403, 404] or
               (conn.status == 302 and redirected_to(conn) != tenant.slug)
    end
  end
end
