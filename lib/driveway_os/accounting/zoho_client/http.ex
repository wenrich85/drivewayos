defmodule DrivewayOS.Accounting.ZohoClient.Http do
  @moduledoc """
  Production impl of the `ZohoClient` behaviour. Uses Req. Hardcoded
  to the .com region for V1 (per spec decision #8).
  """
  @behaviour DrivewayOS.Accounting.ZohoClient

  require Logger

  @oauth_base "https://accounts.zoho.com"
  @api_base "https://www.zohoapis.com/books/v3"

  @impl true
  def exchange_oauth_code(code, redirect_uri) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "client_id" => Application.fetch_env!(:driveway_os, :zoho_client_id),
        "client_secret" => Application.fetch_env!(:driveway_os, :zoho_client_secret),
        "redirect_uri" => redirect_uri,
        "code" => code
      })

    # Note: unlike `refresh_access_token` / `api_*`, this returns the
    # full {status, body} map on non-200. Code-exchange is a one-shot
    # OAuth-callback flow — the body's `error_description` field
    # distinguishes "code expired" / "invalid_grant" / "redirect_uri
    # mismatch", which the controller needs to render an actionable
    # error message. `{:error, :auth_failed}` would discard that.
    case Req.post("#{@oauth_base}/oauth/v2/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => at, "refresh_token" => rt} = b}} ->
        {:ok,
         %{
           access_token: at,
           refresh_token: rt,
           expires_in: b["expires_in"] || 3600
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Zoho code exchange failed status=#{status} body=#{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def refresh_access_token(refresh_token) do
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "client_id" => Application.fetch_env!(:driveway_os, :zoho_client_id),
        "client_secret" => Application.fetch_env!(:driveway_os, :zoho_client_secret),
        "refresh_token" => refresh_token
      })

    case Req.post("#{@oauth_base}/oauth/v2/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => at} = b}} ->
        {:ok, %{access_token: at, expires_in: b["expires_in"] || 3600}}

      {:ok, %{status: 401}} ->
        {:error, :auth_failed}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def api_get(access_token, org_id, path, params \\ []) do
    params = Keyword.put(params, :organization_id, org_id)

    case Req.get("#{@api_base}#{path}",
           params: params,
           headers: auth_headers(access_token)
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :auth_failed}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def api_post(access_token, org_id, path, body) do
    url = "#{@api_base}#{path}?organization_id=#{org_id}"

    # Zoho expects form-encoded JSONString param.
    form = %{"JSONString" => Jason.encode!(body)}

    case Req.post(url, form: form, headers: auth_headers(access_token)) do
      {:ok, %{status: status, body: body}} when status in [200, 201] -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :auth_failed}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth_headers(token), do: [{"authorization", "Zoho-oauthtoken #{token}"}]
end
