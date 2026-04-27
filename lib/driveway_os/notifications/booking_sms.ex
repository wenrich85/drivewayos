defmodule DrivewayOS.Notifications.BookingSms do
  @moduledoc """
  Builds + dispatches booking-related SMS messages. Public surface:

      * `confirmation/4` — fires right after a booking lands when
        the customer has a phone number AND the tenant's plan
        includes `:sms_notifications`. Mirrors the existing
        BookingEmail.confirmation flow.

  Bodies are plain text, branded by the tenant display_name + kept
  short so they fit a single SMS segment (~160 chars) where possible.
  """
  alias DrivewayOS.Branding
  alias DrivewayOS.Notifications.SmsClient

  @doc """
  Send a booking-confirmation SMS. Returns `{:ok, _}` on a real
  send, `{:error, :no_phone}` when the customer has no phone
  number, or `{:error, :no_from_number}` when the tenant hasn't
  configured a Twilio sender.
  """
  @spec confirmation(map(), map(), map(), map()) :: {:ok, map()} | {:error, atom() | term()}
  def confirmation(tenant, customer, appt, service) do
    with {:ok, to} <- normalize_phone(customer.phone),
         {:ok, from} <- tenant_from_number(tenant) do
      SmsClient.send_sms(from, to, body(tenant, customer, appt, service))
    end
  end

  @doc "Body builder exposed for test assertions."
  @spec body(map(), map(), map(), map()) :: String.t()
  def body(tenant, customer, appt, service) do
    when_str = format_when(appt.scheduled_at)

    "Hi #{customer.name}, your #{service.name} with " <>
      "#{Branding.display_name(tenant)} is booked for #{when_str}. " <>
      "We'll text you on the day of. Reply STOP to opt out."
  end

  defp normalize_phone(nil), do: {:error, :no_phone}
  defp normalize_phone(""), do: {:error, :no_phone}
  defp normalize_phone(phone) when is_binary(phone) do
    case String.trim(phone) do
      "" -> {:error, :no_phone}
      p -> {:ok, p}
    end
  end

  defp tenant_from_number(%{support_phone: phone}) when is_binary(phone) and phone != "",
    do: {:ok, phone}

  defp tenant_from_number(_), do: {:error, :no_from_number}

  defp format_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d %-I:%M %p UTC")
end
