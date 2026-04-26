defmodule DrivewayOSWeb.CalendarController do
  @moduledoc """
  Single-appointment iCalendar (.ics) export so customers can drop
  the booking into Google / Apple / Outlook with one click.

  Authorization mirrors AppointmentDetailLive — booker, admin, or
  (guest-booked appointments) anyone with the URL. The id is a
  UUID so URL-possession is the trust model for guests, same as
  `/book/success/:id`.

  No content-disposition `inline` here: most calendar apps trigger
  on the `text/calendar` MIME type alone, and the `attachment`
  fallback ensures browsers that don't recognize it still let the
  user save the file.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Branding
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  def appointment(conn, %{"id" => id}) do
    tenant = conn.assigns[:current_tenant]

    with %{} = tenant <- tenant,
         {:ok, appt} <- Ash.get(Appointment, id, tenant: tenant.id, authorize?: false),
         {:ok, service} <-
           Ash.get(ServiceType, appt.service_type_id, tenant: tenant.id, authorize?: false),
         {:ok, booker} <-
           Ash.get(Customer, appt.customer_id, tenant: tenant.id, authorize?: false),
         true <- can_view?(booker, conn.assigns[:current_customer]) do
      ics = build_ics(tenant, appt, service)

      conn
      |> put_resp_content_type("text/calendar")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="booking-#{short_id(appt.id)}.ics")
      )
      |> send_resp(200, ics)
    else
      _ -> send_resp(conn, 404, "Not found.")
    end
  end

  defp can_view?(_booker, %Customer{role: :admin}), do: true
  defp can_view?(%Customer{id: id}, %Customer{id: id}), do: true
  defp can_view?(%Customer{guest?: true}, _), do: true
  defp can_view?(_, _), do: false

  defp build_ics(tenant, appt, service) do
    end_time = DateTime.add(appt.scheduled_at, appt.duration_minutes * 60, :second)
    now = DateTime.utc_now()

    [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//DrivewayOS//Booking//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      "BEGIN:VEVENT",
      "UID:#{appt.id}@drivewayos",
      "DTSTAMP:#{ics_time(now)}",
      "DTSTART:#{ics_time(appt.scheduled_at)}",
      "DTEND:#{ics_time(end_time)}",
      "SUMMARY:#{ics_text("#{service.name} — #{Branding.display_name(tenant)}")}",
      "LOCATION:#{ics_text(appt.service_address)}",
      "DESCRIPTION:#{ics_text(description(tenant, appt, service))}",
      "STATUS:#{ics_status(appt.status)}",
      "END:VEVENT",
      "END:VCALENDAR"
    ]
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp description(tenant, appt, service) do
    "#{service.name} appointment with #{Branding.display_name(tenant)}. " <>
      "Vehicle: #{appt.vehicle_description}."
  end

  defp ics_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp ics_text(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp ics_status(:cancelled), do: "CANCELLED"
  defp ics_status(:completed), do: "CONFIRMED"
  defp ics_status(:confirmed), do: "CONFIRMED"
  defp ics_status(_), do: "TENTATIVE"

  defp short_id(id), do: id |> to_string() |> String.slice(0, 8)
end
