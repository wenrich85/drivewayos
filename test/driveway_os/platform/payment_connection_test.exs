defmodule DrivewayOS.Platform.PaymentConnectionTest do
  @moduledoc """
  Pin the `Platform.PaymentConnection` contract: per-(tenant, provider)
  OAuth tokens + lifecycle state for payment integrations. Mirrors
  Phase 3's AccountingConnection shape with payment-flavored field
  names. The `:reconnect` action incorporates Phase 3's M1 fix
  preemptively (clears disconnected_at, refreshes tokens, restores
  auto_charge_enabled, sets connected_at to now).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PaymentConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "pc-#{System.unique_integer([:positive])}",
        display_name: "Payment Conn Test",
        admin_email: "pc-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "connect creates a row with auto_charge_enabled true and connected_at set", ctx do
    {:ok, conn} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :square,
        external_merchant_id: "MLR-1",
        access_token: "at-1",
        refresh_token: "rt-1",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)

    assert conn.tenant_id == ctx.tenant.id
    assert conn.provider == :square
    assert conn.access_token == "at-1"
    assert conn.refresh_token == "rt-1"
    assert conn.auto_charge_enabled == true
    assert %DateTime{} = conn.connected_at
    assert conn.disconnected_at == nil
  end

  test "refresh_tokens updates the three token fields", ctx do
    conn = connect_square!(ctx.tenant.id)

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

  test "disconnect clears tokens, sets disconnected_at, pauses charge", ctx do
    conn = connect_square!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update(authorize?: false)

    assert updated.access_token == nil
    assert updated.refresh_token == nil
    assert updated.access_token_expires_at == nil
    assert %DateTime{} = updated.disconnected_at
    assert updated.auto_charge_enabled == false
  end

  test "pause and resume toggle auto_charge_enabled", ctx do
    conn = connect_square!(ctx.tenant.id)
    {:ok, paused} = conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update(authorize?: false)
    refute paused.auto_charge_enabled

    {:ok, resumed} = paused |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update(authorize?: false)
    assert resumed.auto_charge_enabled
  end

  test "record_charge_success sets last_charge_at and clears error", ctx do
    conn = connect_square!(ctx.tenant.id)

    {:ok, with_err} =
      conn
      |> Ash.Changeset.for_update(:record_charge_error, %{last_charge_error: "boom"})
      |> Ash.update(authorize?: false)

    assert with_err.last_charge_error == "boom"

    {:ok, healed} =
      with_err
      |> Ash.Changeset.for_update(:record_charge_success, %{})
      |> Ash.update(authorize?: false)

    assert %DateTime{} = healed.last_charge_at
    assert healed.last_charge_error == nil
  end

  test "reconnect clears disconnected_at, restores active state, updates merchant_id", ctx do
    conn = connect_square!(ctx.tenant.id)

    {:ok, disconnected} =
      conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update(authorize?: false)

    assert %DateTime{} = disconnected.disconnected_at
    refute disconnected.auto_charge_enabled

    {:ok, reconnected} =
      disconnected
      |> Ash.Changeset.for_update(:reconnect, %{
        access_token: "at-fresh",
        refresh_token: "rt-fresh",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        external_merchant_id: "MLR-DIFFERENT"
      })
      |> Ash.update(authorize?: false)

    assert reconnected.disconnected_at == nil
    assert reconnected.auto_charge_enabled == true
    assert reconnected.access_token == "at-fresh"
    assert reconnected.external_merchant_id == "MLR-DIFFERENT"
    assert %DateTime{} = reconnected.connected_at
  end

  test "unique_tenant_provider identity rejects duplicate (tenant, provider)", ctx do
    _ = connect_square!(ctx.tenant.id)

    {:error, %Ash.Error.Invalid{}} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :square,
        external_merchant_id: "MLR-2",
        access_token: "at-99",
        refresh_token: "rt-99",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)
  end

  test "provider rejects unknown values (only :square in V1)", ctx do
    {:error, %Ash.Error.Invalid{}} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :totally_not_a_real_provider,
        external_merchant_id: "x",
        access_token: "x",
        refresh_token: "y",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)
  end

  defp connect_square!(tenant_id) do
    PaymentConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :square,
      external_merchant_id: "MLR-1",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> Ash.create!(authorize?: false)
  end
end
