defmodule DrivewayOS.Platform.AccountingConnectionTest do
  @moduledoc """
  Pin the `Platform.AccountingConnection` contract: per-(tenant,
  provider) OAuth tokens + sync state. Connect creates, refresh
  updates tokens, disconnect clears tokens but keeps row, pause/resume
  toggles auto_sync_enabled. Reconnecting the same provider for the
  same tenant upserts via the unique identity.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ac-#{System.unique_integer([:positive])}",
        display_name: "Accounting Test",
        admin_email: "ac-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "connect creates a row with auto_sync_enabled true and connected_at set", ctx do
    {:ok, conn} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :zoho_books,
        external_org_id: "12345",
        access_token: "at-1",
        refresh_token: "rt-1",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        region: "com"
      })
      |> Ash.create(authorize?: false)

    assert conn.tenant_id == ctx.tenant.id
    assert conn.provider == :zoho_books
    assert conn.access_token == "at-1"
    assert conn.refresh_token == "rt-1"
    assert conn.auto_sync_enabled == true
    assert %DateTime{} = conn.connected_at
    assert conn.disconnected_at == nil
  end

  test "refresh_tokens updates the three token fields", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:refresh_tokens, %{
        access_token: "at-2",
        refresh_token: "rt-2",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 7200, :second)
      })
      |> Ash.update(authorize?: false)

    assert updated.access_token == "at-2"
    assert updated.refresh_token == "rt-2"
  end

  test "disconnect clears tokens, sets disconnected_at, pauses sync", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update(authorize?: false)

    assert updated.access_token == nil
    assert updated.refresh_token == nil
    assert updated.access_token_expires_at == nil
    assert %DateTime{} = updated.disconnected_at
    assert updated.auto_sync_enabled == false
  end

  test "pause and resume toggle auto_sync_enabled", ctx do
    conn = connect_zoho!(ctx.tenant.id)
    {:ok, paused} = conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update(authorize?: false)
    refute paused.auto_sync_enabled

    {:ok, resumed} = paused |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update(authorize?: false)
    assert resumed.auto_sync_enabled
  end

  test "record_sync_success sets last_sync_at and clears error", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    {:ok, with_err} =
      conn
      |> Ash.Changeset.for_update(:record_sync_error, %{last_sync_error: "boom"})
      |> Ash.update(authorize?: false)

    assert with_err.last_sync_error == "boom"

    {:ok, healed} =
      with_err
      |> Ash.Changeset.for_update(:record_sync_success, %{})
      |> Ash.update(authorize?: false)

    assert %DateTime{} = healed.last_sync_at
    assert healed.last_sync_error == nil
  end

  test "unique_tenant_provider identity rejects duplicate (tenant, provider)", ctx do
    _ = connect_zoho!(ctx.tenant.id)

    {:error, %Ash.Error.Invalid{}} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :zoho_books,
        external_org_id: "67890",
        access_token: "at-99",
        refresh_token: "rt-99",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        region: "com"
      })
      |> Ash.create(authorize?: false)
  end

  test "provider rejects unknown values (only :zoho_books in V1)", ctx do
    {:error, %Ash.Error.Invalid{}} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :totally_not_a_real_provider,
        external_org_id: "1",
        access_token: "x",
        refresh_token: "y",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)
  end

  test "reconnect clears disconnected_at, restores active state, updates org_id", ctx do
    # Connect, disconnect, then reconnect
    conn = connect_zoho!(ctx.tenant.id)

    {:ok, disconnected} =
      conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update(authorize?: false)

    assert %DateTime{} = disconnected.disconnected_at
    refute disconnected.auto_sync_enabled

    {:ok, reconnected} =
      disconnected
      |> Ash.Changeset.for_update(:reconnect, %{
        access_token: "at-fresh",
        refresh_token: "rt-fresh",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        external_org_id: "different-org-456"
      })
      |> Ash.update(authorize?: false)

    assert reconnected.disconnected_at == nil
    assert reconnected.auto_sync_enabled == true
    assert reconnected.access_token == "at-fresh"
    assert reconnected.refresh_token == "rt-fresh"
    assert reconnected.external_org_id == "different-org-456"
    assert %DateTime{} = reconnected.connected_at
  end

  defp connect_zoho!(tenant_id) do
    AccountingConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :zoho_books,
      external_org_id: "12345",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    })
    |> Ash.create!(authorize?: false)
  end
end
