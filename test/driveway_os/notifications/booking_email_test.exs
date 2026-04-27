defmodule DrivewayOS.Notifications.BookingEmailTest do
  @moduledoc """
  Booking confirmation email — reads tenant branding via
  DrivewayOS.Branding so the From line, display name, and footer
  are tenant-specific.

  Crucially, an email sent for tenant A must never leak tenant B's
  branding. That's the load-bearing test in this file.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.Appointment

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant_a, admin: admin_a}} =
      Platform.provision_tenant(%{
        slug: "ema-#{System.unique_integer([:positive])}",
        display_name: "Acme Wash Co",
        admin_email: "owner-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant_a, admin: admin_a}
  end

  defp book!(tenant, customer) do
    {:ok, [service | _]} =
      DrivewayOS.Scheduling.ServiceType
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

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
          vehicle_description: "Blue 2022 Subaru Outback",
          service_address: "123 Cedar St"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {appt, service}
  end

  describe "confirmation/3" do
    test "to: customer email; from: tenant display + support email", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)

      email = BookingEmail.confirmation(ctx.tenant, ctx.admin, appt, service)

      assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      assert email.from == {"Acme Wash Co", "noreply@lvh.me"}
    end

    test "subject mentions the tenant", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.confirmation(ctx.tenant, ctx.admin, appt, service)
      assert email.subject =~ "Acme Wash Co"
    end

    test "body includes the service, vehicle, and address", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.confirmation(ctx.tenant, ctx.admin, appt, service)

      assert email.text_body =~ service.name
      assert email.text_body =~ appt.vehicle_description
      assert email.text_body =~ appt.service_address
    end

    test "tenant-A email never contains tenant-B branding (alert)", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "ema2-#{System.unique_integer([:positive])}",
          display_name: "Bravo Detail Inc",
          admin_email: "owner-b2-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B Owner",
          admin_password: "Password123!"
        })

      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.new_booking_alert(ctx.tenant, ctx.admin, ctx.admin, appt, service)

      refute email.text_body =~ "Bravo Detail"
      refute email.subject =~ "Bravo Detail"
      assert is_struct(tenant_b)
    end
  end

  describe "new_booking_alert/5" do
    test "to: admin email; from: tenant From line", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.new_booking_alert(ctx.tenant, ctx.admin, ctx.admin, appt, service)

      assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      assert email.from == {"Acme Wash Co", "noreply@lvh.me"}
    end

    test "subject says 'New booking' + service + customer name", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.new_booking_alert(ctx.tenant, ctx.admin, ctx.admin, appt, service)

      assert email.subject =~ "New booking"
      assert email.subject =~ service.name
      assert email.subject =~ ctx.admin.name
    end

    test "body lists customer email, service, schedule, address", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.new_booking_alert(ctx.tenant, ctx.admin, ctx.admin, appt, service)

      assert email.text_body =~ to_string(ctx.admin.email)
      assert email.text_body =~ service.name
      assert email.text_body =~ appt.service_address
      assert email.text_body =~ appt.vehicle_description
    end
  end

  describe "tenant_admins-driven fan-out" do
    test "Accounts.tenant_admins/1 returns only admin-role customers", ctx do
      # Add a non-admin customer; it should NOT appear in the result.
      {:ok, _normie} =
        DrivewayOS.Accounts.Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "normie-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Normie"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      admins = DrivewayOS.Accounts.tenant_admins(ctx.tenant.id)

      assert length(admins) == 1
      [a] = admins
      assert a.id == ctx.admin.id
    end

    test "tenant A's admin lookup excludes tenant B's admins", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "emi-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "ob-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other Owner",
          admin_password: "Password123!"
        })

      a_admins = DrivewayOS.Accounts.tenant_admins(ctx.tenant.id)
      b_admins = DrivewayOS.Accounts.tenant_admins(tenant_b.id)

      assert length(a_admins) == 1
      assert length(b_admins) == 1
      refute Enum.any?(a_admins, &(&1.tenant_id == tenant_b.id))
    end
  end

  describe "confirmed/4" do
    test "subject mentions 'confirmed' and the schedule", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.confirmed(ctx.tenant, ctx.admin, appt, service)

      assert email.subject =~ "confirmed"
      assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
    end

    test "body lists service, vehicle, address", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.confirmed(ctx.tenant, ctx.admin, appt, service)

      assert email.text_body =~ service.name
      assert email.text_body =~ appt.vehicle_description
      assert email.text_body =~ appt.service_address
    end
  end

  describe "cancelled/4" do
    test "subject says 'cancelled' and goes to the customer", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)

      cancelled_appt = %{
        appt
        | status: :cancelled,
          cancellation_reason: "Cancelled by customer"
      }

      email = BookingEmail.cancelled(ctx.tenant, ctx.admin, cancelled_appt, service)

      assert email.subject =~ "cancelled"
      assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      assert email.text_body =~ "Cancelled by customer"
    end
  end

  describe "customer_cancellation_alert/5" do
    test "to: admin; subject: 'Cancellation: <customer> — <service>'", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)

      email =
        BookingEmail.customer_cancellation_alert(ctx.tenant, ctx.admin, ctx.admin, appt, service)

      assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      assert email.subject =~ "Cancellation"
      assert email.subject =~ ctx.admin.name
      assert email.subject =~ service.name
    end
  end

  describe "subscription_cancelled/4" do
    test "to: customer; subject says 'cancelled' + service", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)

      sub = %DrivewayOS.Scheduling.Subscription{
        frequency: :biweekly,
        starts_at: appt.scheduled_at,
        next_run_at: appt.scheduled_at,
        vehicle_description: appt.vehicle_description,
        service_address: appt.service_address
      }

      email = BookingEmail.subscription_cancelled(ctx.tenant, ctx.admin, sub, service)

      assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      assert email.subject =~ "cancelled"
      assert email.subject =~ service.name
      assert email.text_body =~ "won't auto-book"
      assert email.text_body =~ "every 2 weeks"
    end
  end

  describe "subscription_confirmed/4" do
    test "to: customer; subject mentions service + recurring", ctx do
      {appt, service} = book!(ctx.tenant, ctx.admin)

      sub = %DrivewayOS.Scheduling.Subscription{
        frequency: :biweekly,
        starts_at: appt.scheduled_at,
        next_run_at: appt.scheduled_at,
        vehicle_description: appt.vehicle_description,
        service_address: appt.service_address
      }

      email = BookingEmail.subscription_confirmed(ctx.tenant, ctx.admin, sub, service)

      assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      assert email.subject =~ "recurring"
      assert email.subject =~ service.name
      assert email.text_body =~ "every 2 weeks"
      assert email.text_body =~ appt.vehicle_description
    end
  end

  describe "tenant-A email never contains tenant-B branding" do
    test "confirmation isolation", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "emb-#{System.unique_integer([:positive])}",
          display_name: "Bravo Detail Inc",
          admin_email: "owner-b-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B Owner",
          admin_password: "Password123!"
        })

      {appt, service} = book!(ctx.tenant, ctx.admin)
      email = BookingEmail.confirmation(ctx.tenant, ctx.admin, appt, service)

      refute email.text_body =~ "Bravo Detail"
      refute email.subject =~ "Bravo Detail"
      assert is_struct(tenant_b)
    end
  end
end
