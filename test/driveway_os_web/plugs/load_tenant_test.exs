defmodule DrivewayOSWeb.Plugs.LoadTenantTest do
  @moduledoc """
  V1 Slice 2B: subdomain-based tenant resolution.

  The plug reads `conn.host`, classifies it into one of three contexts,
  and writes:

    * `conn.assigns[:tenant_context]` — `:tenant | :marketing | :platform_admin`
    * `conn.assigns[:current_tenant]` — the `%Tenant{}` when in :tenant context, else nil
    * `conn.private[:tenant_id]` — the tenant id (also stored in session by the plug)

  Unknown / archived tenant subdomains halt with 404 — that's the
  load-bearing contract this test suite proves.
  """
  use DrivewayOS.DataCase, async: false

  import Mox
  import Plug.Test
  import Plug.Conn

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOSWeb.Plugs.LoadTenant

  @opts LoadTenant.init([])

  setup :set_mox_global

  setup do
    # Permissive DNS stub so any verify_custom_domain call in this
    # file's setup paths just succeeds.
    DrivewayOS.Platform.DnsResolverMock
    |> stub(:lookup_cname, fn _ -> {:ok, ["edge.lvh.me"]} end)
    |> stub(:lookup_txt, fn _ -> {:ok, []} end)

    :ok
  end

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "load-test-#{System.unique_integer([:positive])}",
        display_name: "Load Test Tenant"
      })
      |> Ash.create(authorize?: false)

    %{tenant: tenant}
  end

  describe "platform host (no subdomain)" do
    test "marketing context: :marketing, no current_tenant" do
      conn =
        conn(:get, "/")
        |> with_host("lvh.me")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      refute conn.halted
      assert conn.assigns[:tenant_context] == :marketing
      assert conn.assigns[:current_tenant] == nil
    end

    test "www subdomain is also marketing" do
      conn =
        conn(:get, "/")
        |> with_host("www.lvh.me")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      refute conn.halted
      assert conn.assigns[:tenant_context] == :marketing
    end

    test "localhost is treated as marketing (dev convenience)" do
      conn =
        conn(:get, "/")
        |> with_host("localhost")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      refute conn.halted
      assert conn.assigns[:tenant_context] == :marketing
      assert conn.assigns[:current_tenant] == nil
    end

    test "127.0.0.1 is treated as marketing (dev convenience)" do
      conn =
        conn(:get, "/")
        |> with_host("127.0.0.1")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      refute conn.halted
      assert conn.assigns[:tenant_context] == :marketing
    end
  end

  describe "platform admin subdomain" do
    test "admin.* sets :platform_admin context" do
      conn =
        conn(:get, "/")
        |> with_host("admin.lvh.me")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      refute conn.halted
      assert conn.assigns[:tenant_context] == :platform_admin
      assert conn.assigns[:current_tenant] == nil
    end
  end

  describe "tenant subdomain" do
    test "loads the tenant when slug matches", %{tenant: tenant} do
      conn =
        conn(:get, "/")
        |> with_host("#{tenant.slug}.lvh.me")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      refute conn.halted
      assert conn.assigns[:tenant_context] == :tenant
      assert conn.assigns[:current_tenant].id == tenant.id
    end

    test "stores tenant_id in session for LV on_mount to read",
         %{tenant: tenant} do
      conn =
        conn(:get, "/")
        |> with_host("#{tenant.slug}.lvh.me")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      assert get_session(conn, :tenant_id) == tenant.id
    end

    test "404s on an unknown subdomain" do
      conn =
        conn(:get, "/")
        |> with_host("never-existed-#{System.unique_integer([:positive])}.lvh.me")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      assert conn.halted
      assert conn.status == 404
    end

    test "404s on an archived tenant", %{tenant: tenant} do
      tenant
      |> Ash.Changeset.for_update(:archive, %{})
      |> Ash.update!(authorize?: false)

      conn =
        conn(:get, "/")
        |> with_host("#{tenant.slug}.lvh.me")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      assert conn.halted
      assert conn.status == 404
    end
  end

  describe "custom domains" do
    test "verified custom hostname resolves to its tenant", %{tenant: tenant} do
      hostname = "verified-#{System.unique_integer([:positive])}.example.com"
      {:ok, cd} = DrivewayOS.Platform.add_custom_domain(tenant, hostname)
      {:ok, _} = DrivewayOS.Platform.verify_custom_domain(cd)

      conn =
        conn(:get, "/")
        |> with_host(hostname)
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      refute conn.halted
      assert conn.assigns[:tenant_context] == :tenant
      assert conn.assigns[:current_tenant].id == tenant.id
    end

    test "unverified custom hostname → 404", %{tenant: tenant} do
      hostname = "unverified-#{System.unique_integer([:positive])}.example.com"
      {:ok, _} = DrivewayOS.Platform.add_custom_domain(tenant, hostname)

      conn =
        conn(:get, "/")
        |> with_host(hostname)
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      assert conn.halted
      assert conn.status == 404
    end

    test "unknown hostname (not custom domain, not platform) → 404" do
      conn =
        conn(:get, "/")
        |> with_host("totally-random-#{System.unique_integer([:positive])}.example.org")
        |> init_test_session(%{})
        |> LoadTenant.call(@opts)

      assert conn.halted
      assert conn.status == 404
    end
  end

  defp with_host(conn, host) do
    %{conn | host: host}
  end
end
