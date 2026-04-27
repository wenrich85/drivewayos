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

  describe "status filter" do
    setup ctx do
      # Confirm one extra appointment so we have rows in two distinct
      # statuses to filter against.
      {:ok, confirmed} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.appt.service_type_id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(2 * 86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: 45,
            price_cents: 5_000,
            vehicle_description: "Blue Subaru Outback",
            service_address: "1 Oak"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      confirmed
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      Map.put(ctx, :confirmed, Ash.reload!(confirmed, authorize?: false))
    end

    test "filtering to :pending shows only pending rows", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      html = render_change(lv, "filter_status", %{"status" => "pending"})

      assert html =~ "Red Tesla"
      refute html =~ "Blue Subaru Outback"
    end

    test "filtering to :confirmed shows only confirmed rows", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      html = render_change(lv, "filter_status", %{"status" => "confirmed"})

      refute html =~ "Red Tesla"
      assert html =~ "Blue Subaru Outback"
    end

    test "filter :all returns to showing both", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      render_change(lv, "filter_status", %{"status" => "pending"})
      html = render_change(lv, "filter_status", %{"status" => "all"})

      assert html =~ "Red Tesla"
      assert html =~ "Blue Subaru Outback"
    end
  end

  describe "search" do
    test "filters rows by case-insensitive substring match on customer or vehicle", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      html = render_change(lv, "search", %{"q" => "tesla"})

      assert html =~ "Red Tesla"
    end
  end

  describe "acquisition channel column + filter" do
    setup ctx do
      {:ok, google_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.appt.service_type_id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(2 * 86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: 45,
            price_cents: 5_000,
            vehicle_description: "Google Truck",
            service_address: "1 Google Lane",
            acquisition_channel: "Google"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, friend_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.appt.service_type_id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: 45,
            price_cents: 5_000,
            vehicle_description: "Friend Truck",
            service_address: "1 Friend Lane",
            acquisition_channel: "Friend / family"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      Map.merge(ctx, %{google_appt: google_appt, friend_appt: friend_appt})
    end

    test "channel column shows the value or '—' when nil", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      assert html =~ "Google"
      assert html =~ "Friend / family"
    end

    test "filtering by 'Google' hides Friend rows", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      html = render_change(lv, "filter_channel", %{"channel" => "Google"})

      assert html =~ "Google Truck"
      refute html =~ "Friend Truck"
    end

    test "filtering by '_none' shows only appointments with no channel", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      html = render_change(lv, "filter_channel", %{"channel" => "_none"})

      # Original appt (ctx.appt has no channel) should be visible.
      assert html =~ "Red Tesla"
      refute html =~ "Google Truck"
      refute html =~ "Friend Truck"
    end
  end

  describe "pinned admin notes preview" do
    test "shows truncated admin_notes preview next to customer name", ctx do
      ctx.customer
      |> Ash.Changeset.for_update(:update, %{
        admin_notes: "Gate code 4321; prefers Saturday mornings; tip well"
      })
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      assert html =~ "Gate code 4321"
      assert html =~ "📌"
    end

    test "no preview when customer has no admin_notes", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/appointments")

      refute html =~ "📌"
    end
  end
end
