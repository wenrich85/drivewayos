defmodule DrivewayOS.Accounting.ZohoClient do
  @moduledoc """
  Behaviour for the Zoho Books HTTP layer. Three concerns:

    * `exchange_oauth_code/2` — POST to /oauth/v2/token to convert
      the authorization code returned on the OAuth callback into an
      access_token + refresh_token.
    * `refresh_access_token/2` — POST to /oauth/v2/token with grant
      type `refresh_token` to get a fresh access_token when the
      stored one expires.
    * `api_get/4` / `api_post/4` — REST calls against
      `https://www.zohoapis.com/books/v3/...` with the access_token
      in the auth header. Always pass `organization_id` query param.

  Tests Mox-mock this behaviour. Production uses
  `DrivewayOS.Accounting.ZohoClient.Http`.
  """

  @callback exchange_oauth_code(code :: String.t(), redirect_uri :: String.t()) ::
              {:ok,
               %{
                 access_token: String.t(),
                 refresh_token: String.t(),
                 expires_in: integer()
               }}
              | {:error, term()}

  @callback refresh_access_token(refresh_token :: String.t(), client_secret :: String.t()) ::
              {:ok, %{access_token: String.t(), expires_in: integer()}}
              | {:error, term()}

  @callback api_get(
              access_token :: String.t(),
              organization_id :: String.t(),
              path :: String.t(),
              params :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback api_post(
              access_token :: String.t(),
              organization_id :: String.t(),
              path :: String.t(),
              body :: map()
            ) :: {:ok, map()} | {:error, term()}

  @doc "Returns the configured impl module — production = Http, tests = Mox mock."
  @spec impl() :: module()
  def impl, do: Application.get_env(:driveway_os, :zoho_client, __MODULE__.Http)

  defdelegate exchange_oauth_code(code, redirect_uri), to: __MODULE__.Http
  defdelegate refresh_access_token(refresh_token, client_secret), to: __MODULE__.Http
  defdelegate api_get(access_token, org_id, path, params), to: __MODULE__.Http
  defdelegate api_post(access_token, org_id, path, body), to: __MODULE__.Http
end
