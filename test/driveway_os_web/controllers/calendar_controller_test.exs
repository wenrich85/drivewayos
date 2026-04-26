defmodule DrivewayOSWeb.CalendarControllerTest do
  @moduledoc """
  GET /appointments/:id/calendar.ics — single-event iCalendar
  download. Visible to the booker, any tenant admin, or anyone
  with the URL when the appointment was guest-booked.
  """
  use DrivewayOSWeb.ConnCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "ics-#{System.unique_integer([:positive])}",
        display_name: "ICS Test Shop",
        plan_tier: :pro
      })
      |> Ash.create(authorize?: false)

    {:ok, _service} =
      ServiceType
      |> Ash.Changeset.for_create(
        :create,
        %{
          slug: "basic",
          name: "Basic Wash",
          base_price_cents: 5_000,
          duration_minutes: 45
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant}
  end

  defp service(tenant) do
    {:ok, [s | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    s
  end

  defp book_for(tenant, customer) do
    s = service(tenant)

    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: customer.id,
        service_type_id: s.id,
        scheduled_at:
          DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
        duration_minutes: s.duration_minutes,
        price_cents: s.base_price_cents,
        vehicle_description: "ICS Truck",
        service_address: "1 Calendar Lane, San Antonio TX"
      },
      tenant: tenant.id
    )
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  test "signed-in booker downloads a valid VCALENDAR", %{conn: conn, tenant: tenant} do
    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "alice@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Alice"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    appt = book_for(tenant, customer)

    conn =
      conn
      |> sign_in(customer)
      |> Map.put(:host, "#{tenant.slug}.lvh.me")
      |> get(~p"/appointments/#{appt.id}/calendar.ics")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/calendar"
    body = conn.resp_body
    assert body =~ "BEGIN:VCALENDAR"
    assert body =~ "BEGIN:VEVENT"
    assert body =~ "SUMMARY:Basic Wash"
    assert body =~ "LOCATION:1 Calendar Lane\\, San Antonio TX"
    assert body =~ "END:VEVENT"
    assert body =~ "END:VCALENDAR"
    # CRLF line endings per RFC 5545.
    assert String.contains?(body, "\r\n")
  end

  test "guest-booked appointment is downloadable without auth", %{conn: conn, tenant: tenant} do
    {:ok, guest} =
      Customer
      |> Ash.Changeset.for_create(
        :register_guest,
        %{name: "Guest", email: "g@example.com"},
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    appt = book_for(tenant, guest)

    conn =
      conn
      |> Map.put(:host, "#{tenant.slug}.lvh.me")
      |> get(~p"/appointments/#{appt.id}/calendar.ics")

    assert conn.status == 200
    assert conn.resp_body =~ "BEGIN:VCALENDAR"
  end

  test "non-booker non-admin cannot download a non-guest appointment", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, alice} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "a@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Alice"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {:ok, bob} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "b@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Bob"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    bob_appt = book_for(tenant, bob)

    conn =
      conn
      |> sign_in(alice)
      |> Map.put(:host, "#{tenant.slug}.lvh.me")
      |> get(~p"/appointments/#{bob_appt.id}/calendar.ics")

    assert conn.status == 404
  end
end
