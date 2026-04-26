defmodule DrivewayOS.Notifications.BookingEmail do
  @moduledoc """
  Booking confirmation email — sent to a customer right after their
  appointment is created (or right after Stripe confirms payment,
  on the Connect path).

  All branding flows through `DrivewayOS.Branding` so a tenant's
  display name + support email show up correctly. Cross-tenant
  leakage is the load-bearing test in
  `DrivewayOS.Notifications.BookingEmailTest`.
  """
  import Swoosh.Email

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Branding
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  @spec confirmation(Tenant.t(), Customer.t(), Appointment.t(), ServiceType.t()) ::
          Swoosh.Email.t()
  def confirmation(
        %Tenant{} = tenant,
        %Customer{} = customer,
        %Appointment{} = appt,
        %ServiceType{} = service
      ) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Your booking with #{Branding.display_name(tenant)} is confirmed")
    |> text_body(text_body(tenant, customer, appt, service))
  end

  defp text_body(tenant, customer, appt, service) do
    """
    Hey #{customer.name},

    Thanks for booking with #{Branding.display_name(tenant)}!

    Here's what we have on the books:

      Service:  #{service.name}
      When:     #{format_when(appt.scheduled_at)}
      Vehicle:  #{appt.vehicle_description}
      Where:    #{appt.service_address}
      Total:    #{format_price(appt.price_cents)}

    We'll reach out to you on the day of to confirm an exact arrival
    window.

    Questions? Reply to this email or call us anytime.

    -- #{Branding.display_name(tenant)}
    """
  end

  defp format_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a %b %-d, %Y at %-I:%M %p UTC")
  end

  defp format_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)
end
