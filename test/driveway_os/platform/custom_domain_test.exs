defmodule DrivewayOS.Platform.CustomDomainTest do
  @moduledoc """
  Custom domains let a tenant point their own hostname (e.g.
  `book.acmewash.com`) at DrivewayOS — instead of being stuck on
  `acme.drivewayos.com` forever.

  V1 contract:
    * Tenant adds a hostname → `:pending` until DNS is verified
    * `Platform.verify_custom_domain!/1` flips `verified_at`
    * Routing only resolves to the tenant once verified
    * Hostnames are globally unique (one Acme Wash, one
      `book.acmewash.com`)

  SSL is the tenant's responsibility in V1 (Cloudflare, their own LB).
  Cert automation lands in a follow-up.
  """
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{CustomDomain, Tenant}

  require Ash.Query

  # Tests that already call verify_custom_domain expect it to
  # succeed; stub the DNS resolver permissively at module level so
  # we don't have to set per-test expectations everywhere. The
  # describe blocks that test failure paths set their own explicit
  # expectations on top of these stubs.
  setup :set_mox_global

  setup do
    DrivewayOS.Platform.DnsResolverMock
    |> stub(:lookup_cname, fn _ -> {:ok, ["edge.lvh.me"]} end)
    |> stub(:lookup_txt, fn _ -> {:ok, []} end)

    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "cd-test-#{System.unique_integer([:positive])}",
        display_name: "CD Test Tenant"
      })
      |> Ash.create(authorize?: false)

    %{tenant: tenant}
  end

  describe "create" do
    test "starts unverified with a verification token", %{tenant: tenant} do
      {:ok, cd} =
        CustomDomain
        |> Ash.Changeset.for_create(:create, %{
          hostname: "book-#{System.unique_integer([:positive])}.example.com",
          tenant_id: tenant.id
        })
        |> Ash.create(authorize?: false)

      assert cd.id
      assert cd.tenant_id == tenant.id
      assert is_nil(cd.verified_at)
      assert is_binary(cd.verification_token)
      assert String.length(cd.verification_token) >= 16
      assert cd.ssl_status == :none
    end

    test "rejects duplicate hostname (across all tenants)", %{tenant: tenant} do
      hostname = "dup-#{System.unique_integer([:positive])}.example.com"

      {:ok, _} =
        CustomDomain
        |> Ash.Changeset.for_create(:create, %{hostname: hostname, tenant_id: tenant.id})
        |> Ash.create(authorize?: false)

      # Different tenant, same hostname — must fail.
      {:ok, other_tenant} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "cd-other-#{System.unique_integer([:positive])}",
          display_name: "Other"
        })
        |> Ash.create(authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               CustomDomain
               |> Ash.Changeset.for_create(:create, %{
                 hostname: hostname,
                 tenant_id: other_tenant.id
               })
               |> Ash.create(authorize?: false)
    end

    test "normalizes hostname to lowercase", %{tenant: tenant} do
      {:ok, cd} =
        CustomDomain
        |> Ash.Changeset.for_create(:create, %{
          hostname: "MiXeDcAsE-#{System.unique_integer([:positive])}.example.com",
          tenant_id: tenant.id
        })
        |> Ash.create(authorize?: false)

      assert cd.hostname == String.downcase(cd.hostname)
    end
  end

  describe ":verify action" do
    test "flips verified_at to now", %{tenant: tenant} do
      {:ok, cd} =
        CustomDomain
        |> Ash.Changeset.for_create(:create, %{
          hostname: "verify-#{System.unique_integer([:positive])}.example.com",
          tenant_id: tenant.id
        })
        |> Ash.create(authorize?: false)

      {:ok, verified} =
        cd
        |> Ash.Changeset.for_update(:verify, %{})
        |> Ash.update(authorize?: false)

      assert %DateTime{} = verified.verified_at
    end
  end

  describe "Platform.add_custom_domain/2" do
    test "creates an unverified domain for the tenant", %{tenant: tenant} do
      hostname = "add-#{System.unique_integer([:positive])}.example.com"

      assert {:ok, cd} = Platform.add_custom_domain(tenant, hostname)
      assert cd.tenant_id == tenant.id
      assert cd.hostname == hostname
      assert is_nil(cd.verified_at)
    end
  end

  describe "Platform.verify_custom_domain/1 (real DNS check)" do
    import Mox
    setup :verify_on_exit!

    test "verifies when CNAME points at our edge", %{tenant: tenant} do
      hostname = "cname-#{System.unique_integer([:positive])}.example.com"
      {:ok, cd} = Platform.add_custom_domain(tenant, hostname)
      expected_target = "edge.lvh.me"

      DrivewayOS.Platform.DnsResolverMock
      |> expect(:lookup_cname, fn ^hostname -> {:ok, [expected_target]} end)

      assert {:ok, verified} = Platform.verify_custom_domain(cd)
      assert %DateTime{} = verified.verified_at
    end

    test "verifies via TXT token when CNAME doesn't match", %{tenant: tenant} do
      hostname = "txt-#{System.unique_integer([:positive])}.example.com"
      {:ok, cd} = Platform.add_custom_domain(tenant, hostname)

      DrivewayOS.Platform.DnsResolverMock
      |> expect(:lookup_cname, fn _ -> {:ok, ["wrong-target.example.com"]} end)
      |> expect(:lookup_txt, fn "_drivewayos." <> ^hostname ->
        {:ok, [cd.verification_token]}
      end)

      assert {:ok, verified} = Platform.verify_custom_domain(cd)
      assert %DateTime{} = verified.verified_at
    end

    test "rejects when neither CNAME nor TXT match", %{tenant: tenant} do
      hostname = "fail-#{System.unique_integer([:positive])}.example.com"
      {:ok, cd} = Platform.add_custom_domain(tenant, hostname)

      DrivewayOS.Platform.DnsResolverMock
      |> expect(:lookup_cname, fn _ -> {:ok, []} end)
      |> expect(:lookup_txt, fn _ -> {:ok, []} end)

      assert {:error, :dns_not_pointing_here} = Platform.verify_custom_domain(cd)

      reloaded = Ash.get!(DrivewayOS.Platform.CustomDomain, cd.id, authorize?: false)
      assert is_nil(reloaded.verified_at)
    end
  end

  describe "Platform.get_tenant_by_custom_hostname/1" do
    test "returns the tenant for a verified hostname", %{tenant: tenant} do
      hostname = "lookup-#{System.unique_integer([:positive])}.example.com"
      {:ok, cd} = Platform.add_custom_domain(tenant, hostname)
      {:ok, _} = Platform.verify_custom_domain(cd)

      assert {:ok, %Tenant{id: id}} = Platform.get_tenant_by_custom_hostname(hostname)
      assert id == tenant.id
    end

    test "returns :error for an unverified hostname", %{tenant: tenant} do
      hostname = "unverified-#{System.unique_integer([:positive])}.example.com"
      {:ok, _} = Platform.add_custom_domain(tenant, hostname)

      assert {:error, :not_found} = Platform.get_tenant_by_custom_hostname(hostname)
    end

    test "returns :error for an unknown hostname" do
      assert {:error, :not_found} =
               Platform.get_tenant_by_custom_hostname("nobody-here.example.com")
    end

    test "case-insensitive lookup", %{tenant: tenant} do
      hostname = "case-#{System.unique_integer([:positive])}.example.com"
      {:ok, cd} = Platform.add_custom_domain(tenant, hostname)
      {:ok, _} = Platform.verify_custom_domain(cd)

      assert {:ok, _} = Platform.get_tenant_by_custom_hostname(String.upcase(hostname))
    end

    test "returns :error if the tenant is archived", %{tenant: tenant} do
      hostname = "archived-#{System.unique_integer([:positive])}.example.com"
      {:ok, cd} = Platform.add_custom_domain(tenant, hostname)
      {:ok, _} = Platform.verify_custom_domain(cd)

      tenant
      |> Ash.Changeset.for_update(:archive, %{})
      |> Ash.update!(authorize?: false)

      assert {:error, :not_found} = Platform.get_tenant_by_custom_hostname(hostname)
    end
  end
end
