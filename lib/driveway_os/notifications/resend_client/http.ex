defmodule DrivewayOS.Notifications.ResendClient.Http do
  @moduledoc """
  Concrete HTTP impl of the ResendClient behaviour. Talks to
  https://api.resend.com using `Req`.

  Auth: master account `RESEND_API_KEY` via the
  `:resend_api_key` application config (set from RESEND_API_KEY
  env var in runtime.exs). Each api-key creation call returns a
  per-tenant api_key that the caller stores per-tenant.
  """

  @behaviour DrivewayOS.Notifications.ResendClient

  @endpoint "https://api.resend.com"

  @impl true
  def create_api_key(name) when is_binary(name) do
    request =
      Req.new(
        base_url: @endpoint,
        headers: [
          {"Authorization", "Bearer " <> master_token()},
          {"Accept", "application/json"}
        ],
        json: %{"name" => name},
        receive_timeout: 10_000
      )

    case Req.post(request, url: "/api-keys") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, %{key_id: body["id"], api_key: body["token"]}}

      {:ok, %Req.Response{status: 201, body: body}} ->
        {:ok, %{key_id: body["id"], api_key: body["token"]}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  @impl true
  def delete_api_key(key_id) when is_binary(key_id) do
    request =
      Req.new(
        base_url: @endpoint,
        headers: [
          {"Authorization", "Bearer " <> master_token()},
          {"Accept", "application/json"}
        ],
        receive_timeout: 10_000
      )

    case Req.delete(request, url: "/api-keys/" <> key_id) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, exception} -> {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  defp master_token do
    case Application.get_env(:driveway_os, :resend_api_key) do
      nil -> raise "RESEND_API_KEY not configured"
      "" -> raise "RESEND_API_KEY not configured"
      token -> token
    end
  end
end
