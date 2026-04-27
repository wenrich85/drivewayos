defmodule DrivewayOS.Notifications.SmsClient do
  @moduledoc """
  Behaviour + dispatcher for outgoing SMS. The runtime impl is
  selected via the `:driveway_os, :sms_client` config key:

      * `DrivewayOS.Notifications.SmsClient.Twilio` — production
      * `DrivewayOS.Notifications.SmsClient.Stub` — dev/test, logs
        the message and returns `{:ok, %{...}}` so callers can
        smoke-test the wiring without spending real Twilio credits

  Sites should call `SmsClient.send_sms/3` rather than calling the
  impl directly so the test config + Mox can swap it out cleanly.
  """

  @typedoc "E.164 phone number, e.g. \"+15125551234\"."
  @type phone :: String.t()

  @callback send_sms(from :: phone(), to :: phone(), body :: String.t()) ::
              {:ok, %{sid: String.t() | nil, to: phone(), body: String.t()}}
              | {:error, atom() | term()}

  @doc "Returns the configured impl, defaulting to Twilio in prod."
  def impl,
    do:
      Application.get_env(
        :driveway_os,
        :sms_client,
        DrivewayOS.Notifications.SmsClient.Twilio
      )

  @doc """
  Send a single SMS. Best-effort dispatcher — callers should treat
  `{:error, :unconfigured}` as 'tenant hasn't set up SMS yet' and
  `{:error, _}` as 'try again later or fall back to email'.
  """
  @spec send_sms(phone(), phone(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_sms(from, to, body), do: impl().send_sms(from, to, body)
end
