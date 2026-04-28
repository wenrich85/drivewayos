defmodule DrivewayOSWeb.AdminAppointmentsExportControllerTest do
  @moduledoc """
  GET /admin/appointments.csv — admin-only CSV export of every
  appointment in the current tenant. Tests cover the happy path,
  the auth gates (anonymous, non-admin, cross-tenant), and the
  RFC-4180 quoting for cells that contain commas / quotes /
  newlines.
  """
  use DrivewayOSWeb.ConnCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "exp-#{System.unique_integer([:positive])}",
        display_name: "Export Shop",
        admin_email: "exp-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, alice} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "alice-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Alice"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    {:ok, appt} =
      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: alice.id,
          service_type_id: service.id,
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: service.duration_minutes,
          price_cents: service.base_price_cents,
          vehicle_description: "Blue Outback",
          service_address: "123 Cedar"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, alice: alice, service: service, appt: appt}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    Plug.Test.init_test_session(conn, %{customer_token: token})
  end

  describe "auth" do
    test "anonymous → 404", %{conn: conn, tenant: tenant} do
      conn =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> get(~p"/admin/appointments.csv")

      assert conn.status == 404
    end

    test "non-admin customer → 404", ctx do
      conn =
        sign_in(ctx.conn, ctx.alice)
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> get(~p"/admin/appointments.csv")

      assert conn.status == 404
    end
  end

  describe "happy path" do
    test "admin gets text/csv with the appointment row + header", ctx do
      conn =
        sign_in(ctx.conn, ctx.admin)
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> get(~p"/admin/appointments.csv")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"

      [disposition | _] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "appointments-#{ctx.tenant.slug}"
      assert disposition =~ ".csv"

      body = conn.resp_body
      # Header row.
      assert body =~ "Scheduled at,Customer,Email"
      # Booking row content.
      assert body =~ "Alice"
      assert body =~ "Blue Outback"
      assert body =~ "123 Cedar"
      assert body =~ "50.00"
      assert body =~ "pending"
    end

    test "multi-vehicle bookings flatten into the Vehicles cell", ctx do
      {:ok, multi} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.alice.id,
            service_type_id: ctx.service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(2 * 86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "BMW 530",
            additional_vehicles: [
              %{"description" => "Honda Pilot"},
              %{"description" => "Mini Cooper"}
            ],
            service_address: "1 Cedar"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn =
        sign_in(ctx.conn, ctx.admin)
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> get(~p"/admin/appointments.csv")

      body = conn.resp_body

      # The Vehicles cell contains semicolons and a comma if any
      # description has one; the cell quoting handles that. Here we
      # just confirm all three cars land in the row.
      assert body =~ "BMW 530"
      assert body =~ "Honda Pilot"
      assert body =~ "Mini Cooper"
      assert is_struct(multi)
    end

    test "values containing commas are RFC-4180 quoted", ctx do
      {:ok, _} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.alice.id,
            service_type_id: ctx.service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Honda, with a comma",
            service_address: "1 Cedar"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn =
        sign_in(ctx.conn, ctx.admin)
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> get(~p"/admin/appointments.csv")

      # The whole vehicles cell is wrapped in quotes — assert the
      # exact double-quoted form lands in the body.
      assert conn.resp_body =~ ~s("Honda, with a comma")
    end

    test "cross-tenant: tenant A admin only sees tenant A rows", ctx do
      # Build a tenant B with its own appointment, then ensure A's
      # CSV doesn't leak the B row.
      {:ok, %{tenant: tenant_b, admin: _admin_b}} =
        Platform.provision_tenant(%{
          slug: "expb-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "expb-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B Owner",
          admin_password: "Password123!"
        })

      {:ok, [service_b | _]} =
        ServiceType |> Ash.Query.set_tenant(tenant_b.id) |> Ash.read(authorize?: false)

      {:ok, customer_b} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "stranger-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger Danger"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: customer_b.id,
            service_type_id: service_b.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: service_b.duration_minutes,
            price_cents: service_b.base_price_cents,
            vehicle_description: "B-tenant car",
            service_address: "B-tenant address"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      conn =
        sign_in(ctx.conn, ctx.admin)
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> get(~p"/admin/appointments.csv")

      refute conn.resp_body =~ "Stranger Danger"
      refute conn.resp_body =~ "B-tenant car"
    end
  end
end
