defmodule DrivewayOSWeb.Admin.TodayPrintLiveTest do
  @moduledoc """
  /admin/today/print — printable single-page route sheet for today.
  Admin-gated; same data shape as the dashboard's Today widget but
  stripped of action buttons.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "tp-#{System.unique_integer([:positive])}",
        display_name: "Print Test",
        admin_email: "tp-#{System.unique_integer([:positive])}@example.com",
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
          email: "tpc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Print Customer",
          phone: "+15125559876"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, customer: customer, service: service}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  defp local_today_at(tz, %Time{} = time_of_day) do
    {:ok, now_local} = DateTime.shift_zone(DateTime.utc_now(), tz)
    {:ok, ndt} = NaiveDateTime.new(DateTime.to_date(now_local), time_of_day)
    {:ok, dt_local} = DateTime.from_naive(ndt, tz)
    candidate = DateTime.shift_zone!(dt_local, "Etc/UTC") |> DateTime.truncate(:second)

    if DateTime.compare(candidate, DateTime.utc_now()) == :gt do
      candidate
    else
      DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.truncate(:second)
    end
  end

  describe "auth gate" do
    test "non-admin → /", %{conn: conn, tenant: tenant, customer: customer} do
      conn = sign_in(conn, customer)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/admin/today/print")
    end

    test "anonymous → /sign-in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/admin/today/print")
    end
  end

  describe "rendering" do
    test "shows today's confirmed appointments with customer phone", ctx do
      tz = ctx.tenant.timezone
      noon_today = local_today_at(tz, ~T[12:00:00])

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: noon_today,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Print Vehicle",
            service_address: "1 Print Lane"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/today/print")

      assert html =~ "route"
      assert html =~ "Print Customer"
      assert html =~ "+15125559876"
      assert html =~ "Print Vehicle"
      assert html =~ "1 Print Lane"
    end

    test "shows acquisition_channel as 'Source' when set", ctx do
      tz = ctx.tenant.timezone
      noon_today = local_today_at(tz, ~T[12:00:00])

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: noon_today,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Source RX",
            service_address: "1 Source Lane",
            acquisition_channel: "Friend / family"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/today/print")

      assert html =~ "Source"
      assert html =~ "Friend / family"
    end

    test "shows the customer's pinned admin_notes on the print sheet", ctx do
      tz = ctx.tenant.timezone
      noon_today = local_today_at(tz, ~T[12:00:00])

      ctx.customer
      |> Ash.Changeset.for_update(:update, %{admin_notes: "Gate code 4321; dog on porch"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: noon_today,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Pinned Vehicle",
            service_address: "1 Pinned Lane"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/today/print")

      assert html =~ "Pinned"
      assert html =~ "Gate code 4321"
    end

    test "hides Source row when acquisition_channel is nil", ctx do
      tz = ctx.tenant.timezone
      noon_today = local_today_at(tz, ~T[12:00:00])

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: noon_today,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Quiet RX",
            service_address: "1 Quiet Lane"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/today/print")

      refute html =~ "Source"
    end

    test "empty state when nothing today", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/today/print")

      assert html =~ "Nothing scheduled today"
    end
  end
end
