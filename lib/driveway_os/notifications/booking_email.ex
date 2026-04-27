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

  @doc """
  Operator-side notification: fired when a customer books an
  appointment so the tenant admin doesn't have to refresh /admin
  to find out. One email per admin (the BookingLive fan-out
  iterates over `Accounts.tenant_admins/1`).
  """
  @spec new_booking_alert(Tenant.t(), Customer.t(), Customer.t(), Appointment.t(), ServiceType.t()) ::
          Swoosh.Email.t()
  def new_booking_alert(
        %Tenant{} = tenant,
        %Customer{} = admin,
        %Customer{} = customer,
        %Appointment{} = appt,
        %ServiceType{} = service
      ) do
    new()
    |> to({admin.name, to_string(admin.email)})
    |> from(Branding.from_address(tenant))
    |> subject("New booking: #{service.name} for #{customer.name}")
    |> text_body(alert_body(tenant, admin, customer, appt, service))
  end

  @doc """
  Customer-side notification: appointment was confirmed by the
  operator. Fired from AppointmentDetailLive / DashboardLive when
  an admin clicks Confirm.
  """
  @spec confirmed(Tenant.t(), Customer.t(), Appointment.t(), ServiceType.t()) ::
          Swoosh.Email.t()
  def confirmed(
        %Tenant{} = tenant,
        %Customer{} = customer,
        %Appointment{} = appt,
        %ServiceType{} = service
      ) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Your booking is confirmed — #{format_when(appt.scheduled_at)}")
    |> text_body("""
    Hey #{customer.name},

    #{Branding.display_name(tenant)} confirmed your booking.

      Service:  #{service.name}
      When:     #{format_when(appt.scheduled_at)}
      Vehicle:  #{appt.vehicle_description}
      Where:    #{appt.service_address}

    Reply to this email if anything's changed before then.

    -- #{Branding.display_name(tenant)}
    """)
  end

  @doc """
  Customer-side notification: their recurring subscription just
  materialized into a concrete Appointment N days out. Distinct
  from `confirmation/4` because the customer didn't actively
  click "Book" — we want them to know an auto-booking landed and
  give them an obvious cancel path.
  """
  @spec subscription_appointment_created(
          Tenant.t(),
          Customer.t(),
          Appointment.t(),
          ServiceType.t()
        ) :: Swoosh.Email.t()
  def subscription_appointment_created(
        %Tenant{} = tenant,
        %Customer{} = customer,
        %Appointment{} = appt,
        %ServiceType{} = service
      ) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Your next #{service.name} is on the books")
    |> text_body("""
    Hey #{customer.name},

    Your recurring booking with #{Branding.display_name(tenant)}
    just auto-scheduled the next one:

      Service:  #{service.name}
      When:     #{format_when(appt.scheduled_at)}
      Vehicle:  #{appt.vehicle_description}
      Where:    #{appt.service_address}
      Total:    #{format_price(appt.price_cents)}

    We'll send a reminder the day before. If anything's changed,
    cancel from your appointment page or pause the recurring plan
    from your profile.

    -- #{Branding.display_name(tenant)}
    """)
  end

  @doc """
  Customer-side reminder: appointment is ~24h out. Fired by the
  ReminderScheduler GenServer; the appointment row is then marked
  `reminder_sent_at` so we never double-send.
  """
  @spec reminder(Tenant.t(), Customer.t(), Appointment.t(), ServiceType.t()) ::
          Swoosh.Email.t()
  def reminder(
        %Tenant{} = tenant,
        %Customer{} = customer,
        %Appointment{} = appt,
        %ServiceType{} = service
      ) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Reminder: #{service.name} tomorrow at #{format_time(appt.scheduled_at)}")
    |> text_body("""
    Hey #{customer.name},

    Just a reminder that #{Branding.display_name(tenant)} is
    scheduled to wash your vehicle tomorrow.

      Service:  #{service.name}
      When:     #{format_when(appt.scheduled_at)}
      Vehicle:  #{appt.vehicle_description}
      Where:    #{appt.service_address}

    If anything's changed, reply to this email or cancel from your
    appointment page so we can re-shuffle the route.

    -- #{Branding.display_name(tenant)}
    """)
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%-I:%M %p UTC")

  @doc """
  Customer-side notification: appointment was cancelled. Sent for
  cancellations from either side (admin or customer); the
  cancellation_reason on the appointment captures who.
  """
  @spec cancelled(Tenant.t(), Customer.t(), Appointment.t(), ServiceType.t()) ::
          Swoosh.Email.t()
  def cancelled(
        %Tenant{} = tenant,
        %Customer{} = customer,
        %Appointment{} = appt,
        %ServiceType{} = service
      ) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Your booking has been cancelled")
    |> text_body("""
    Hey #{customer.name},

    Your #{service.name} booking with #{Branding.display_name(tenant)}
    has been cancelled.

      When was: #{format_when(appt.scheduled_at)}
      Vehicle:  #{appt.vehicle_description}
      Where:    #{appt.service_address}
      Reason:   #{appt.cancellation_reason || "—"}

    Need to rebook? Reply to this email.

    -- #{Branding.display_name(tenant)}
    """)
  end

  @doc """
  Operator-side notification: a customer cancelled their own
  booking. Mirror of new_booking_alert/5 — fan out per admin.
  """
  @spec customer_cancellation_alert(
          Tenant.t(),
          Customer.t(),
          Customer.t(),
          Appointment.t(),
          ServiceType.t()
        ) ::
          Swoosh.Email.t()
  def customer_cancellation_alert(
        %Tenant{} = tenant,
        %Customer{} = admin,
        %Customer{} = customer,
        %Appointment{} = appt,
        %ServiceType{} = service
      ) do
    new()
    |> to({admin.name, to_string(admin.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Cancellation: #{customer.name} — #{service.name}")
    |> text_body("""
    Hi #{admin.name},

    #{customer.name} just cancelled their #{service.name} booking on
    #{Branding.display_name(tenant)}.

      When was: #{format_when(appt.scheduled_at)}
      Vehicle:  #{appt.vehicle_description}
      Where:    #{appt.service_address}
      Reason:   #{appt.cancellation_reason || "—"}

    -- #{Branding.display_name(tenant)}
    """)
  end

  @doc """
  Customer-side notification: a recurring subscription was just
  created. Sent from the self-serve flow on /book/success and the
  admin-created flow on /admin/customers/:id.
  """
  @spec subscription_confirmed(
          Tenant.t(),
          Customer.t(),
          DrivewayOS.Scheduling.Subscription.t(),
          ServiceType.t()
        ) :: Swoosh.Email.t()
  def subscription_confirmed(
        %Tenant{} = tenant,
        %Customer{} = customer,
        %DrivewayOS.Scheduling.Subscription{} = sub,
        %ServiceType{} = service
      ) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("You're set up for recurring #{service.name}")
    |> text_body("""
    Hey #{customer.name},

    You're all set for recurring service with #{Branding.display_name(tenant)}.

      Service:    #{service.name}
      Frequency:  #{frequency_label(sub.frequency)}
      Next wash:  #{format_when(sub.next_run_at)}
      Vehicle:    #{sub.vehicle_description}
      Where:      #{sub.service_address}

    We'll auto-book each one a few days in advance and email you a
    reminder the day before. Pause or cancel anytime from your
    profile.

    -- #{Branding.display_name(tenant)}
    """)
  end

  defp frequency_label(:weekly), do: "every week"
  defp frequency_label(:biweekly), do: "every 2 weeks"
  defp frequency_label(:monthly), do: "every month"
  defp frequency_label(other), do: to_string(other)

  @doc """
  Customer-side notification: their loyalty punch card just hit
  the threshold and they've earned a free wash. Fired exactly
  once per cycle from the Appointment.:complete after_action when
  loyalty_count transitions from threshold-1 to threshold.
  """
  @spec loyalty_earned(Tenant.t(), Customer.t(), pos_integer()) :: Swoosh.Email.t()
  def loyalty_earned(%Tenant{} = tenant, %Customer{} = customer, threshold)
      when is_integer(threshold) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("You've earned a free wash at #{Branding.display_name(tenant)}")
    |> text_body("""
    Hey #{customer.name},

    Big day — that was your #{threshold}th wash with
    #{Branding.display_name(tenant)}, which means your next one is on us.

    Apply your free wash from the booking flow next time you're
    due — we'll automatically deduct the price.

    Thanks for sticking with us.

    -- #{Branding.display_name(tenant)}
    """)
  end

  defp alert_body(tenant, admin, customer, appt, service) do
    """
    Hi #{admin.name},

    A new booking just came through #{Branding.display_name(tenant)}.

      Customer: #{customer.name} (#{to_string(customer.email)})
      Service:  #{service.name}
      When:     #{format_when(appt.scheduled_at)}
      Vehicle:  #{appt.vehicle_description}
      Where:    #{appt.service_address}
      Total:    #{format_price(appt.price_cents)}
      Status:   #{appt.status}

    Confirm or cancel from your admin dashboard.

    -- #{Branding.display_name(tenant)}
    """
  end

  defp format_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a %b %-d, %Y at %-I:%M %p UTC")
  end

  defp format_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)
end
