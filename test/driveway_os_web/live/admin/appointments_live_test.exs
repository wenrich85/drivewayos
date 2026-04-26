defmodule DrivewayOSWeb.Admin.AppointmentsLiveTest do
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "ap-#{System.unique_integer([:positive])}",
        display_name: "Appointments Admin",
        admin_email: "ap-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "c-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Cust"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {:ok, appt} =
      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: customer.id,
          service_type_id: service.id,
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: service.duration_minutes,
          price_cents: service.base_price_cents,
          vehicle_description: "Red Tesla",
          service_address: "1 Main"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, customer: customer, appt: appt}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  test "admin sees the appointment row", ctx do
    conn = sign_in(ctx.conn, ctx.admin)

    {:ok, _lv, html} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

    assert html =~ "Appointments"
    assert html =~ "Red Tesla"
  end

  test "admin can confirm a pending appointment", ctx do
    conn = sign_in(ctx.conn, ctx.admin)

    {:ok, lv, _} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

    lv
    |> element("button[phx-click='confirm_appointment'][phx-value-id='#{ctx.appt.id}']")
    |> render_click()

    reloaded = Ash.get!(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
    assert reloaded.status == :confirmed
  end
end
