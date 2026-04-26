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

    test "tenant-A email never contains tenant-B branding", ctx do
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
