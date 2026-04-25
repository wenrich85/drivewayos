defmodule DrivewayOS.Platform.ProvisioningTest do
  @moduledoc """
  V1 Slice 4: tenant signup flow.

  `Platform.provision_tenant/1` is the atomic creation step — it
  takes a flat map of signup-form values, opens an Ecto transaction,
  and creates a Tenant + a first Customer (the tenant admin) inside
  that tenant's data slice. Either both succeed or neither does.

  Slug reservations + format are enforced at this layer so the
  signup LV can lean on it.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  require Ash.Query

  describe "provision_tenant/1" do
    test "creates Tenant + admin Customer in one transaction" do
      attrs = valid_attrs()

      {:ok, %{tenant: tenant, admin: admin}} = Platform.provision_tenant(attrs)

      assert tenant.id
      assert tenant.status == :pending_onboarding
      assert tenant.display_name == attrs.display_name
      assert to_string(tenant.slug) == attrs.slug

      assert admin.tenant_id == tenant.id
      assert admin.role == :admin
      assert to_string(admin.email) == attrs.admin_email
      assert admin.name == attrs.admin_name
      assert admin.hashed_password
    end

    test "rejects reserved slugs" do
      reserved = ~w(admin www api app platform status auth signup login signin)

      for slug <- reserved do
        attrs = valid_attrs(slug: slug)
        assert {:error, _} = Platform.provision_tenant(attrs)
      end
    end

    test "rejects taken slug" do
      slug = "taken-#{System.unique_integer([:positive])}"

      {:ok, _} = Platform.provision_tenant(valid_attrs(slug: slug))

      assert {:error, _} =
               Platform.provision_tenant(valid_attrs(slug: slug, admin_email: "two@example.com"))
    end

    test "rejects malformed slug" do
      assert {:error, _} = Platform.provision_tenant(valid_attrs(slug: "Has Spaces"))
      assert {:error, _} = Platform.provision_tenant(valid_attrs(slug: "ab"))
      assert {:error, _} = Platform.provision_tenant(valid_attrs(slug: "-leading-dash"))
    end

    test "rejects weak password" do
      assert {:error, _} = Platform.provision_tenant(valid_attrs(admin_password: "short1!"))
    end

    test "rejects malformed admin email" do
      assert {:error, _} = Platform.provision_tenant(valid_attrs(admin_email: "not-an-email"))
    end

    test "transaction rolls back if Customer creation fails" do
      # Force a Customer-side failure (bad email) and assert the Tenant
      # didn't sneak through.
      attrs = valid_attrs(admin_email: "")

      assert {:error, _} = Platform.provision_tenant(attrs)

      # No tenant with this slug should exist.
      assert {:error, :not_found} = Platform.get_tenant_by_slug(attrs.slug)
    end
  end

  defp valid_attrs(overrides \\ %{}) do
    %{
      slug: "tenant-#{System.unique_integer([:positive])}",
      display_name: "Acme Wash",
      admin_email: "owner-#{System.unique_integer([:positive])}@example.com",
      admin_name: "Acme Owner",
      admin_password: "Password123!",
      admin_phone: "+15125550199"
    }
    |> Map.merge(Map.new(overrides))
  end
end
