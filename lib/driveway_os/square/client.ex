defmodule DrivewayOS.Square.Client do
  @moduledoc """
  Behaviour for the Square HTTP layer. Five concerns:

    * `exchange_oauth_code/2` — POST to /oauth2/token (grant_type:
      authorization_code) to convert the OAuth callback's code into
      access + refresh tokens. Square returns the tenant's
      merchant_id directly in this response — no separate org probe.
    * `refresh_access_token/1` — POST to /oauth2/token (grant_type:
      refresh_token).
    * `api_get/3` / `api_post/3` — REST calls against
      https://connect.squareup.com/v2/... (or sandbox host) with the
      access_token in Authorization header.
    * `create_payment_link/2` — POST /v2/online-checkout/payment-links
      to create a hosted Square Checkout session for a booking.

  Tests Mox-mock this behaviour. Production uses
  `DrivewayOS.Square.Client.Http`.
  """

  @callback exchange_oauth_code(code :: String.t(), redirect_uri :: String.t()) ::
              {:ok,
               %{
                 access_token: String.t(),
                 refresh_token: String.t(),
                 expires_in: integer(),
                 merchant_id: String.t()
               }}
              | {:error, term()}

  @callback refresh_access_token(refresh_token :: String.t()) ::
              {:ok, %{access_token: String.t(), expires_in: integer()}}
              | {:error, term()}

  @callback api_get(
              access_token :: String.t(),
              path :: String.t(),
              params :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback api_post(
              access_token :: String.t(),
              path :: String.t(),
              body :: map()
            ) :: {:ok, map()} | {:error, term()}

  @callback create_payment_link(
              access_token :: String.t(),
              body :: map()
            ) ::
              {:ok,
               %{
                 checkout_url: String.t(),
                 payment_link_id: String.t(),
                 order_id: String.t()
               }}
              | {:error, term()}

  @doc "Returns the configured impl module — production = Http, tests = Mox mock."
  @spec impl() :: module()
  def impl, do: Application.get_env(:driveway_os, :square_client, __MODULE__.Http)

  defdelegate exchange_oauth_code(code, redirect_uri), to: __MODULE__.Http
  defdelegate refresh_access_token(refresh_token), to: __MODULE__.Http
  defdelegate api_get(access_token, path, params), to: __MODULE__.Http
  defdelegate api_post(access_token, path, body), to: __MODULE__.Http
  defdelegate create_payment_link(access_token, body), to: __MODULE__.Http
end
