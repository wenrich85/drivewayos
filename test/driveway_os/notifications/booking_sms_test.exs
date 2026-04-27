defmodule DrivewayOS.Notifications.BookingSmsTest do
  @moduledoc """
  Body builder + dispatch shape for booking SMS. The actual
  outbound HTTP call is mocked via Mox + the
  Notifications.SmsClientMock defined in test_helper.exs.
  """
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Notifications.BookingSms

  setup :verify_on_exit!

  defp tenant(opts \\ []) do
    %DrivewayOS.Platform.Tenant{
      id: "tenant-1",
      display_name: Keyword.get(opts, :display_name, "Acme Wash"),
      support_phone: Keyword.get(opts, :support_phone, "+15125550000"),
      support_email: "support@acme.test"
    }
  end

  defp customer(opts \\ []) do
    %DrivewayOS.Accounts.Customer{
      name: Keyword.get(opts, :name, "Alice"),
      phone: Keyword.get(opts, :phone, "+15125551234"),
      email: %Ash.CiString{string: "alice@example.com"}
    }
  end

  defp service do
    %DrivewayOS.Scheduling.ServiceType{name: "Basic Wash", duration_minutes: 45}
  end

  defp appt do
    %DrivewayOS.Scheduling.Appointment{
      scheduled_at: ~U[2026-05-15 14:00:00Z],
      vehicle_description: "Blue Outback",
      service_address: "1 Cedar"
    }
  end

  describe "body/4" do
    test "includes customer name, service, when, and tenant display_name" do
      body = BookingSms.body(tenant(), customer(), appt(), service())

      assert body =~ "Alice"
      assert body =~ "Basic Wash"
      assert body =~ "Acme Wash"
      assert body =~ "STOP"
    end
  end

  describe "confirmation/4" do
    test "dispatches via the configured SmsClient when both numbers are set" do
      DrivewayOS.Notifications.SmsClientMock
      |> expect(:send_sms, fn from, to, body ->
        assert from == "+15125550000"
        assert to == "+15125551234"
        assert body =~ "Acme Wash"
        {:ok, %{sid: "sm_123", to: to, body: body}}
      end)

      assert {:ok, %{sid: "sm_123"}} =
               BookingSms.confirmation(tenant(), customer(), appt(), service())
    end

    test "returns {:error, :no_phone} when customer has no phone" do
      assert {:error, :no_phone} =
               BookingSms.confirmation(tenant(), customer(phone: nil), appt(), service())
    end

    test "returns {:error, :no_from_number} when tenant has no support_phone" do
      assert {:error, :no_from_number} =
               BookingSms.confirmation(tenant(support_phone: nil), customer(), appt(), service())
    end
  end
end
