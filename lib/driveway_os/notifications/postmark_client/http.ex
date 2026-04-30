defmodule DrivewayOS.Notifications.PostmarkClient.Http do
  @moduledoc """
  Concrete HTTP impl of the PostmarkClient behaviour. Talks to
  https://api.postmarkapp.com using `Req`.

  Auth: account-level token via `:postmark_account_token`
  application config (set from POSTMARK_ACCOUNT_TOKEN env var in
  runtime.exs). Each Server creation call returns a Server-scoped
  api_key that the caller stores per-tenant.
  """

  @behaviour DrivewayOS.Notifications.PostmarkClient

  @endpoint "https://api.postmarkapp.com"

  @impl true
  def create_server(name, opts) when is_binary(name) do
    color = Keyword.get(opts, :color, "Blue")

    body = %{
      "Name" => name,
      "Color" => color,
      "RawEmailEnabled" => false,
      "DeliveryHookUrl" => nil,
      "InboundHookUrl" => nil
    }

    request =
      Req.new(
        base_url: @endpoint,
        headers: [
          {"X-Postmark-Account-Token", account_token()},
          {"Accept", "application/json"}
        ],
        json: body,
        receive_timeout: 10_000
      )

    case Req.post(request, url: "/servers") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, %{server_id: body["ID"], api_key: body["ApiTokens"] |> List.first()}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  defp account_token do
    case Application.get_env(:driveway_os, :postmark_account_token) do
      nil -> raise "POSTMARK_ACCOUNT_TOKEN not configured"
      "" -> raise "POSTMARK_ACCOUNT_TOKEN not configured"
      token -> token
    end
  end
end
