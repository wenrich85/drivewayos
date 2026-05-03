defmodule DrivewayOS.Platform.EmailConnectionTest do
  @moduledoc """
  Pin the `Platform.EmailConnection` contract: per-(tenant, email
  provider) api_key + lifecycle state for email integrations.
  Mirrors Phase 4's PaymentConnection shape with email-flavored
  field names. API-first, so no refresh_token / expiry — Resend
  api_keys don't expire.

  The `:reconnect` action incorporates Phase 3's M1 fix
  preemptively (clears disconnected_at, refreshes api_key,
  restores auto_send_enabled, sets connected_at to now).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.EmailConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ec-#{System.unique_integer([:positive])}",
        display_name: "Email Conn Test",
        admin_email: "ec-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "connect creates a row with auto_send_enabled true and connected_at set", ctx do
    {:ok, conn} =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "key-1",
        api_key: "re_test_1"
      })
      |> Ash.create(authorize?: false)

    assert conn.tenant_id == ctx.tenant.id
    assert conn.provider == :resend
    assert conn.external_key_id == "key-1"
    assert conn.api_key == "re_test_1"
    assert conn.auto_send_enabled == true
    assert %DateTime{} = conn.connected_at
    assert conn.disconnected_at == nil
  end

  test "disconnect clears api_key + external_key_id, sets disconnected_at, pauses send", ctx do
    conn = connect_resend!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update(authorize?: false)

    assert updated.api_key == nil
    assert updated.external_key_id == nil
    assert %DateTime{} = updated.disconnected_at
    assert updated.auto_send_enabled == false
  end

  test "pause and resume toggle auto_send_enabled", ctx do
    conn = connect_resend!(ctx.tenant.id)
    {:ok, paused} = conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update(authorize?: false)
    refute paused.auto_send_enabled

    {:ok, resumed} = paused |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update(authorize?: false)
    assert resumed.auto_send_enabled
  end

  test "record_send_success sets last_send_at and clears error", ctx do
    conn = connect_resend!(ctx.tenant.id)

    {:ok, with_err} =
      conn
      |> Ash.Changeset.for_update(:record_send_error, %{last_send_error: "boom"})
      |> Ash.update(authorize?: false)

    assert with_err.last_send_error == "boom"

    {:ok, healed} =
      with_err
      |> Ash.Changeset.for_update(:record_send_success, %{})
      |> Ash.update(authorize?: false)

    assert %DateTime{} = healed.last_send_at
    assert healed.last_send_error == nil
  end

  test "reconnect clears disconnected_at, restores active state, updates api_key", ctx do
    conn = connect_resend!(ctx.tenant.id)

    {:ok, disconnected} =
      conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update(authorize?: false)

    assert %DateTime{} = disconnected.disconnected_at
    refute disconnected.auto_send_enabled

    {:ok, reconnected} =
      disconnected
      |> Ash.Changeset.for_update(:reconnect, %{
        external_key_id: "key-fresh",
        api_key: "re_test_fresh"
      })
      |> Ash.update(authorize?: false)

    assert reconnected.disconnected_at == nil
    assert reconnected.auto_send_enabled == true
    assert reconnected.api_key == "re_test_fresh"
    assert reconnected.external_key_id == "key-fresh"
    assert %DateTime{} = reconnected.connected_at
  end

  test "unique_tenant_provider identity rejects duplicate (tenant, provider)", ctx do
    _ = connect_resend!(ctx.tenant.id)

    {:error, %Ash.Error.Invalid{}} =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "key-2",
        api_key: "re_test_2"
      })
      |> Ash.create(authorize?: false)
  end

  test "provider rejects unknown values (only :resend in V1)", ctx do
    {:error, %Ash.Error.Invalid{}} =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :totally_not_a_real_provider,
        external_key_id: "x",
        api_key: "y"
      })
      |> Ash.create(authorize?: false)
  end

  test "Platform.get_email_connection/2 returns the row", ctx do
    _ = connect_resend!(ctx.tenant.id)

    assert {:ok, conn} = Platform.get_email_connection(ctx.tenant.id, :resend)
    assert conn.provider == :resend
  end

  test "Platform.get_email_connection/2 :not_found when none", ctx do
    assert {:error, :not_found} = Platform.get_email_connection(ctx.tenant.id, :resend)
  end

  test "Platform.get_active_email_connection/2 :no_active_connection when paused", ctx do
    conn = connect_resend!(ctx.tenant.id)
    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)

    assert {:error, :no_active_connection} =
             Platform.get_active_email_connection(ctx.tenant.id, :resend)
  end

  test "Platform.get_active_email_connection/2 :no_active_connection when disconnected", ctx do
    conn = connect_resend!(ctx.tenant.id)
    conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)

    assert {:error, :no_active_connection} =
             Platform.get_active_email_connection(ctx.tenant.id, :resend)
  end

  test "Platform.get_active_email_connection/2 returns the row when active", ctx do
    _ = connect_resend!(ctx.tenant.id)

    assert {:ok, conn} = Platform.get_active_email_connection(ctx.tenant.id, :resend)
    assert conn.api_key == "re_test_1"
    assert conn.auto_send_enabled == true
  end

  defp connect_resend!(tenant_id) do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :resend,
      external_key_id: "key-1",
      api_key: "re_test_1"
    })
    |> Ash.create!(authorize?: false)
  end
end
