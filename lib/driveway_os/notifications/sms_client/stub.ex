defmodule DrivewayOS.Notifications.SmsClient.Stub do
  @moduledoc """
  Dev/test SMS impl. Logs the message body to console and returns
  a synthetic success tuple so callers can smoke-test the SMS path
  without burning real Twilio credits.

  Tests that need to assert SMS was sent should use Mox + the
  `DrivewayOS.Notifications.SmsClientMock` rather than the Stub.
  """
  @behaviour DrivewayOS.Notifications.SmsClient

  require Logger

  @impl true
  def send_sms(from, to, body) do
    Logger.info("[sms.stub] #{from} → #{to}: #{body}")
    {:ok, %{sid: "stub_#{System.unique_integer([:positive])}", to: to, body: body}}
  end
end
