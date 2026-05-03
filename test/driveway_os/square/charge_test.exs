defmodule DrivewayOS.Square.ChargeTest do
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Square.{Charge, Client}
  alias DrivewayOS.Platform.PaymentConnection

  setup :verify_on_exit!

  defp connection do
    %PaymentConnection{
      tenant_id: "tenant-1",
      provider: :square,
      external_merchant_id: "MLR-99",
      access_token: "at-1",
      refresh_token: "rt-1"
    }
  end

  defp appointment do
    %{
      id: "appt-1",
      price_cents: 5000,
      service_name: "Basic Wash"
    }
  end

  test "create_checkout_session/3 builds the right body and unwraps the response" do
    conn = connection()
    appt = appointment()

    expect(Client.Mock, :create_payment_link, fn at, body ->
      assert at == "at-1"
      assert body["idempotency_key"] == "appt-1"
      assert body["order"]["location_id"] == "MLR-99-LOC"
      assert [item] = body["order"]["line_items"]
      assert item["name"] == "Basic Wash"
      assert item["quantity"] == "1"
      assert item["base_price_money"]["amount"] == 5000
      assert item["base_price_money"]["currency"] == "USD"
      assert body["checkout_options"]["redirect_url"] == "https://example.com/back"

      {:ok,
       %{
         checkout_url: "https://checkout.square.example/abc",
         payment_link_id: "pl-1",
         order_id: "ord-1"
       }}
    end)

    assert {:ok, %{checkout_url: url, order_id: order_id}} =
             Charge.create_checkout_session(conn, appt, "https://example.com/back",
               location_id: "MLR-99-LOC"
             )

    assert url == "https://checkout.square.example/abc"
    assert order_id == "ord-1"
  end

  test "propagates client errors" do
    expect(Client.Mock, :create_payment_link, fn _, _ ->
      {:error, %{status: 400, body: %{"errors" => [%{"code" => "INVALID_REQUEST_ERROR"}]}}}
    end)

    assert {:error, %{status: 400}} =
             Charge.create_checkout_session(connection(), appointment(),
               "https://example.com/back",
               location_id: "MLR-99-LOC"
             )
  end
end
