defmodule DrivewayOS.Square.Charge do
  @moduledoc """
  Square Checkout (Payment Links) session creation.

  V1 charges one line item per appointment (the service name + price).
  Tenant's `external_merchant_id` is used as the location id stem;
  callers may override via `location_id` opt for tenants with multiple
  Square locations.

  Idempotency key = appointment id, so retrying the same booking
  doesn't create duplicate Payment Links in Square.

  `create_checkout_session/4` returns `{:ok, %{checkout_url, payment_link_id, order_id}}`
  on success. Caller (the booking flow) stores `order_id` on the
  Appointment as `square_order_id` so the webhook can match
  payment.updated events back to the right booking.
  """

  alias DrivewayOS.Square.Client
  alias DrivewayOS.Platform.PaymentConnection

  @doc """
  Build a Square Payment Link for `appointment` on behalf of the
  tenant connected via `connection`. `redirect_url` is where Square
  sends the customer after they pay.

  `opts`:
    * `:location_id` — Square Location ID for charge attribution.
       Defaults to the connection's `external_merchant_id` (Square
       merchants who have only one location can pass that as their
       primary location id, or the connection should populate it
       at OAuth time — V1 uses the merchant_id as a placeholder
       location_id; production deployments must pass an explicit
       location_id from the tenant's configured Square location.)
    * `:currency` — defaults to "USD".
  """
  @spec create_checkout_session(
          PaymentConnection.t(),
          appointment :: map(),
          redirect_url :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, %{checkout_url: String.t(), payment_link_id: String.t(), order_id: String.t()}}
          | {:error, term()}
  def create_checkout_session(%PaymentConnection{} = conn, appointment, redirect_url, opts \\ []) do
    location_id = Keyword.get(opts, :location_id, conn.external_merchant_id)
    currency = Keyword.get(opts, :currency, "USD")

    body = %{
      "idempotency_key" => appointment.id,
      "checkout_options" => %{
        "redirect_url" => redirect_url
      },
      "order" => %{
        "location_id" => location_id,
        "line_items" => [
          %{
            "name" => appointment.service_name,
            "quantity" => "1",
            "base_price_money" => %{
              "amount" => appointment.price_cents,
              "currency" => currency
            }
          }
        ]
      }
    }

    Client.impl().create_payment_link(conn.access_token, body)
  end
end
