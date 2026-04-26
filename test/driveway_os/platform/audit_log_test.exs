defmodule DrivewayOS.Platform.AuditLogTest do
  @moduledoc """
  Append-only ledger of platform-side admin actions:
  impersonation, suspend/reactivate, refunds, branding changes.

  V1 contract:
    * Inserts only — no updates, no destroys
    * platform_user_id nullable (tenant admins initiate some events)
    * tenant_id nullable (platform-level events have no tenant)
    * action enum constrains the events we know how to render
    * payload :map is free-form context
    * Read action `:recent_for_tenant` for the platform-admin tenant
      detail page to surface recent activity
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{AuditLog, Tenant}

  require Ash.Query

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "al-#{System.unique_integer([:positive])}",
        display_name: "Audit Log Test"
      })
      |> Ash.create(authorize?: false)

    %{tenant: tenant}
  end

  describe "log/1" do
    test "records an action for a tenant", %{tenant: tenant} do
      assert {:ok, entry} =
               Platform.log_audit(%{
                 action: :tenant_suspended,
                 tenant_id: tenant.id,
                 payload: %{"reason" => "non-payment"}
               })

      assert entry.action == :tenant_suspended
      assert entry.tenant_id == tenant.id
      assert entry.payload["reason"] == "non-payment"
    end

    test "rejects an unknown action atom", %{tenant: tenant} do
      assert {:error, %Ash.Error.Invalid{}} =
               Platform.log_audit(%{
                 action: :totally_made_up,
                 tenant_id: tenant.id
               })
    end

    test "platform-level event with no tenant succeeds" do
      assert {:ok, entry} =
               Platform.log_audit(%{
                 action: :platform_user_signed_in,
                 payload: %{"ip" => "1.2.3.4"}
               })

      assert is_nil(entry.tenant_id)
    end
  end

  describe "recent_for_tenant/2" do
    test "returns entries newest-first scoped to that tenant", %{tenant: tenant} do
      {:ok, _} =
        Platform.log_audit(%{action: :tenant_suspended, tenant_id: tenant.id, payload: %{}})

      {:ok, _} =
        Platform.log_audit(%{action: :tenant_reactivated, tenant_id: tenant.id, payload: %{}})

      {:ok, other} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "alo-#{System.unique_integer([:positive])}",
          display_name: "Other"
        })
        |> Ash.create(authorize?: false)

      {:ok, _} =
        Platform.log_audit(%{action: :tenant_suspended, tenant_id: other.id, payload: %{}})

      entries = Platform.recent_audit_for_tenant(tenant.id, 50)

      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.tenant_id == tenant.id))
      # Newest first.
      [first, second] = entries
      assert DateTime.compare(first.inserted_at, second.inserted_at) in [:gt, :eq]
    end
  end

  describe "immutability" do
    test "no :update action available", %{tenant: tenant} do
      {:ok, entry} =
        Platform.log_audit(%{action: :tenant_suspended, tenant_id: tenant.id, payload: %{}})

      # for_update raises immediately because the resource has no
      # :update action defined.
      assert_raise ArgumentError, ~r/No such update action/, fn ->
        Ash.Changeset.for_update(entry, :update, %{action: :tenant_reactivated})
      end
    end
  end
end
