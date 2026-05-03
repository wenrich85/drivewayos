defmodule DrivewayOS.Square.Client.Http do
  @moduledoc """
  Production impl of the `Square.Client` behaviour. Uses Req.

  Base URLs are read from app env at runtime so sandbox/prod toggle
  via `SQUARE_OAUTH_BASE` + `SQUARE_API_BASE` env vars without
  recompile (per Phase 4 design decision #7). Defaults to prod when
  unset.

  401 → `{:error, :auth_failed}` for refresh + api_get + api_post
  + create_payment_link. exchange_oauth_code returns the full
  {status, body} map on non-200 (preserves Square's
  error_description for the OAuth controller's error handling —
  same divergence as Phase 3's ZohoClient.Http).
  """
  @behaviour DrivewayOS.Square.Client

  require Logger

  defp oauth_base,
    do: Application.get_env(:driveway_os, :square_oauth_base, "https://connect.squareup.com")

  defp api_base,
    do: Application.get_env(:driveway_os, :square_api_base, "https://connect.squareup.com/v2")

  @impl true
  def exchange_oauth_code(code, redirect_uri) do
    body = %{
      "grant_type" => "authorization_code",
      "client_id" => Application.fetch_env!(:driveway_os, :square_app_id),
      "client_secret" => Application.fetch_env!(:driveway_os, :square_app_secret),
      "redirect_uri" => redirect_uri,
      "code" => code
    }

    case Req.post("#{oauth_base()}/oauth2/token",
           json: body,
           headers: [{"square-version", "2024-01-18"}]
         ) do
      {:ok,
       %{
         status: 200,
         body: %{"access_token" => at, "refresh_token" => rt, "merchant_id" => mid} = b
       }} ->
        {:ok,
         %{
           access_token: at,
           refresh_token: rt,
           expires_in: parse_expires_in(b),
           merchant_id: mid
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Square code exchange failed status=#{status} body=#{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def refresh_access_token(refresh_token) do
    body = %{
      "grant_type" => "refresh_token",
      "client_id" => Application.fetch_env!(:driveway_os, :square_app_id),
      "client_secret" => Application.fetch_env!(:driveway_os, :square_app_secret),
      "refresh_token" => refresh_token
    }

    case Req.post("#{oauth_base()}/oauth2/token",
           json: body,
           headers: [{"square-version", "2024-01-18"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => at} = b}} ->
        {:ok, %{access_token: at, expires_in: parse_expires_in(b)}}

      {:ok, %{status: 401}} ->
        {:error, :auth_failed}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def api_get(access_token, path, params \\ []) do
    case Req.get("#{api_base()}#{path}",
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
  def api_post(access_token, path, body) do
    case Req.post("#{api_base()}#{path}", json: body, headers: auth_headers(access_token)) do
      {:ok, %{status: status, body: body}} when status in [200, 201] -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :auth_failed}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_payment_link(access_token, body) do
    case Req.post("#{api_base()}/online-checkout/payment-links",
           json: body,
           headers: auth_headers(access_token)
         ) do
      {:ok,
       %{
         status: 200,
         body: %{
           "payment_link" => link,
           "related_resources" => %{"orders" => [%{"id" => order_id} | _]}
         }
       }} ->
        {:ok,
         %{
           checkout_url: link["url"],
           payment_link_id: link["id"],
           order_id: order_id
         }}

      {:ok, %{status: 200, body: %{"payment_link" => link} = b}} ->
        # Some Square responses don't include orders in related_resources;
        # fall back to the order_id field on the link itself.
        {:ok,
         %{
           checkout_url: link["url"],
           payment_link_id: link["id"],
           order_id:
             link["order_id"] || get_in(b, ["related_resources", "orders", Access.at(0), "id"])
         }}

      {:ok, %{status: 401}} ->
        {:error, :auth_failed}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers(token) do
    [{"authorization", "Bearer #{token}"}, {"square-version", "2024-01-18"}]
  end

  # Square's token responses include `expires_at` (ISO-8601) — convert
  # to seconds-from-now for parity with Zoho's `expires_in`.
  defp parse_expires_in(%{"expires_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.diff(dt, DateTime.utc_now(), :second)
      _ -> 30 * 86_400
    end
  end

  # Square default 30 days
  defp parse_expires_in(_), do: 30 * 86_400
end
