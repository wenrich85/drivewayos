defmodule DrivewayOS.AppointmentBroadcasterTest do
  @moduledoc """
  Per-tenant PubSub fan-out. Subscribes a test process to a
  tenant's appointment topic and asserts that broadcasts arrive
  with the expected shape.
  """
  use ExUnit.Case, async: true

  alias DrivewayOS.AppointmentBroadcaster

  test "subscribe + broadcast round-trip" do
    tenant_id = "11111111-1111-1111-1111-111111111111"

    :ok = AppointmentBroadcaster.subscribe(tenant_id)
    AppointmentBroadcaster.broadcast(tenant_id, :confirmed, %{id: "appt-1"})

    assert_receive {:appointment, :confirmed, %{id: "appt-1"}}, 500
  end

  test "subscribers on different tenants don't cross-receive" do
    a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    :ok = AppointmentBroadcaster.subscribe(a)
    AppointmentBroadcaster.broadcast(b, :confirmed, %{id: "appt-b"})

    refute_receive {:appointment, _, _}, 200
  end

  describe "DrivewayOS.SubscriptionBroadcaster" do
    alias DrivewayOS.SubscriptionBroadcaster

    test "subscribe + broadcast round-trip per (tenant, customer)" do
      tenant = "11111111-1111-1111-1111-111111111111"
      customer = "22222222-2222-2222-2222-222222222222"

      :ok = SubscriptionBroadcaster.subscribe(tenant, customer)
      SubscriptionBroadcaster.broadcast(tenant, customer, :pause, %{id: "sub-1"})

      assert_receive {:subscription, :pause, %{id: "sub-1"}}, 500
    end

    test "different customers in the same tenant don't cross-receive" do
      tenant = "33333333-3333-3333-3333-333333333333"
      a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

      :ok = SubscriptionBroadcaster.subscribe(tenant, a)
      SubscriptionBroadcaster.broadcast(tenant, b, :cancel, %{id: "sub-b"})

      refute_receive {:subscription, _, _}, 200
    end
  end
end
