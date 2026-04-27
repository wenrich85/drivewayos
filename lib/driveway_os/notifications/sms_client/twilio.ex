defmodule DrivewayOS.Notifications.SmsClient.Twilio do
  @moduledoc """
  Production SMS impl. Posts to Twilio's
  `/2010-04-01/Accounts/<sid>/Messages.json` endpoint with HTTP
  Basic auth (account_sid / auth_token).

  Reads creds from runtime config:

      config :driveway_os, DrivewayOS.Notifications.SmsClient.Twilio,
        account_sid: ...,
        auth_token: ...

  When any cred is missing, returns `{:error, :unconfigured}`
  early so a half-configured prod doesn't 500 the booking flow.
  Callers fall back to email-only.
  """
  @behaviour DrivewayOS.Notifications.SmsClient

  require Logger

  @impl true
  def send_sms(from, to, body) do
    case credentials() do
      {:ok, sid, token} ->
        do_send(sid, token, from, to, body)

      :error ->
        {:error, :unconfigured}
    end
  end

  defp credentials do
    cfg = Application.get_env(:driveway_os, __MODULE__, [])
    sid = Keyword.get(cfg, :account_sid)
    token = Keyword.get(cfg, :auth_token)

    if is_binary(sid) and sid != "" and is_binary(token) and token != "",
      do: {:ok, sid, token},
      else: :error
  end

  defp do_send(sid, token, from, to, body) do
    url = "https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json"

    case Req.post(url,
           auth: {:basic, "#{sid}:#{token}"},
           form: [From: from, To: to, Body: body]
         ) do
      {:ok, %Req.Response{status: status, body: %{"sid" => message_sid}}}
      when status in 200..299 ->
        {:ok, %{sid: message_sid, to: to, body: body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("[sms.twilio] HTTP #{status}: #{inspect(body)}")
        {:error, :twilio_rejected}

      {:error, reason} ->
        Logger.warning("[sms.twilio] transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
