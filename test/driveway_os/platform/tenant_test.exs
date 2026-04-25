defmodule DrivewayOS.Platform.TenantTest do
  @moduledoc """
  V1 Slice 1: the Tenant anchor resource.

  `Tenant` is never itself tenant-scoped — it IS the tenant. Every
  business resource elsewhere in the app eventually carries a
  `tenant_id` pointing at this row.

  Tests cover:

    * Create with required fields (slug, display_name) succeeds
    * Slug uniqueness (global)
    * Subdomain derived from slug when not specified
    * Subdomain uniqueness
    * Stripe account id uniqueness (nullable; two NULLs OK)
    * Status enum + `:pending_onboarding` default
    * Default timezone "America/Chicago"
    * `:archive` / `:suspend` / `:reactivate` lifecycle actions
    * `:by_slug` / `:by_stripe_account` / `:active` reads
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform.Tenant

  require Ash.Query

  describe "create" do
    test "succeeds with slug + display_name; defaults applied" do
      {:ok, tenant} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "acme-wash-#{System.unique_integer([:positive])}",
          display_name: "Acme Wash"
        })
        |> Ash.create(authorize?: false)

      assert tenant.id
      assert to_string(tenant.slug) |> String.starts_with?("acme-wash-")
      assert tenant.display_name == "Acme Wash"
      assert tenant.status == :pending_onboarding
      assert tenant.stripe_account_status == :none
      assert tenant.timezone == "America/Chicago"
      assert is_nil(tenant.stripe_account_id)
      assert is_nil(tenant.archived_at)
    end

    test "subdomain defaults to slug when not provided" do
      slug = "subdom-#{System.unique_integer([:positive])}"

      {:ok, tenant} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: slug,
          display_name: "Subdom Test"
        })
        |> Ash.create(authorize?: false)

      assert tenant.subdomain == slug
    end

    test "subdomain can be set explicitly" do
      {:ok, tenant} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "custom-#{System.unique_integer([:positive])}",
          display_name: "Custom Sub",
          subdomain: "their-shop-#{System.unique_integer([:positive])}"
        })
        |> Ash.create(authorize?: false)

      assert tenant.subdomain |> String.starts_with?("their-shop-")
    end

    test "rejects duplicate slug" do
      slug = "dupe-#{System.unique_integer([:positive])}"

      {:ok, _a} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{slug: slug, display_name: "A"})
        |> Ash.create(authorize?: false)

      {:error, %Ash.Error.Invalid{}} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{slug: slug, display_name: "B"})
        |> Ash.create(authorize?: false)
    end

    test "rejects duplicate subdomain" do
      sub = "dupesub-#{System.unique_integer([:positive])}"

      {:ok, _a} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "a-#{System.unique_integer([:positive])}",
          display_name: "A",
          subdomain: sub
        })
        |> Ash.create(authorize?: false)

      {:error, %Ash.Error.Invalid{}} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "b-#{System.unique_integer([:positive])}",
          display_name: "B",
          subdomain: sub
        })
        |> Ash.create(authorize?: false)
    end

    test "rejects duplicate non-nil stripe_account_id" do
      acct = "acct_#{System.unique_integer([:positive])}"

      {:ok, _a} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "sa-a-#{System.unique_integer([:positive])}",
          display_name: "A",
          stripe_account_id: acct
        })
        |> Ash.create(authorize?: false)

      {:error, %Ash.Error.Invalid{}} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "sa-b-#{System.unique_integer([:positive])}",
          display_name: "B",
          stripe_account_id: acct
        })
        |> Ash.create(authorize?: false)
    end

    test "rejects slugs with invalid characters" do
      {:error, %Ash.Error.Invalid{}} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "Has Spaces",
          display_name: "Spaces"
        })
        |> Ash.create(authorize?: false)
    end

    test "rejects slugs that are too short" do
      {:error, %Ash.Error.Invalid{}} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "ab",
          display_name: "Short"
        })
        |> Ash.create(authorize?: false)
    end
  end

  describe "lifecycle actions" do
    test ":archive sets status + stamps archived_at" do
      {:ok, tenant} = create_tenant!("Archive Me")

      {:ok, archived} =
        tenant
        |> Ash.Changeset.for_update(:archive, %{})
        |> Ash.update(authorize?: false)

      assert archived.status == :archived
      assert archived.archived_at
    end

    test ":suspend flips status to :suspended" do
      {:ok, tenant} = create_tenant!("Suspend Me")

      {:ok, suspended} =
        tenant
        |> Ash.Changeset.for_update(:suspend, %{})
        |> Ash.update(authorize?: false)

      assert suspended.status == :suspended
    end

    test ":reactivate clears archived_at and sets :active" do
      {:ok, tenant} = create_tenant!("Reactivate Me")

      {:ok, archived} =
        tenant |> Ash.Changeset.for_update(:archive, %{}) |> Ash.update(authorize?: false)

      assert archived.archived_at

      {:ok, active} =
        archived
        |> Ash.Changeset.for_update(:reactivate, %{})
        |> Ash.update(authorize?: false)

      assert active.status == :active
      assert is_nil(active.archived_at)
    end
  end

  describe "read actions" do
    test ":by_slug returns the tenant" do
      slug = "by-slug-#{System.unique_integer([:positive])}"
      {:ok, tenant} = create_tenant!("By Slug Test", slug: slug)

      {:ok, [found]} =
        Tenant
        |> Ash.Query.for_read(:by_slug, %{slug: slug})
        |> Ash.read(authorize?: false)

      assert found.id == tenant.id
    end

    test ":by_slug excludes archived tenants" do
      slug = "archived-by-slug-#{System.unique_integer([:positive])}"
      {:ok, tenant} = create_tenant!("Archived", slug: slug)

      tenant
      |> Ash.Changeset.for_update(:archive, %{})
      |> Ash.update!(authorize?: false)

      {:ok, []} =
        Tenant
        |> Ash.Query.for_read(:by_slug, %{slug: slug})
        |> Ash.read(authorize?: false)
    end

    test ":by_stripe_account returns the tenant regardless of status" do
      acct = "acct_#{System.unique_integer([:positive])}"
      {:ok, tenant} = create_tenant!("Stripe Lookup", stripe_account_id: acct)

      {:ok, [found]} =
        Tenant
        |> Ash.Query.for_read(:by_stripe_account, %{stripe_account_id: acct})
        |> Ash.read(authorize?: false)

      assert found.id == tenant.id
    end
  end

  defp create_tenant!(display_name, opts \\ []) do
    slug = Keyword.get(opts, :slug, "tnt-#{System.unique_integer([:positive])}")

    attrs =
      %{slug: slug, display_name: display_name}
      |> maybe_put(:stripe_account_id, opts[:stripe_account_id])

    Tenant
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
