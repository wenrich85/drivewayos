defmodule DrivewayOSWeb.AppointmentDetailLiveTest do
  @moduledoc """
  /appointments/:id — single appointment detail. Visible to:

    * the customer who booked it
    * any admin in the tenant

  Customers see "Cancel" if it's still pending/confirmed; admins
  see "Confirm" / "Cancel" / "Start" / "Complete" based on status.

  Cross-tenant + cross-customer isolation: viewing somebody else's
  appointment id bounces the request away.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "ad-#{System.unique_integer([:positive])}",
        display_name: "Appt Detail Shop",
        admin_email: "ad-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "c-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "C"
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
          customer_id: customer.id,
          service_type_id: service.id,
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: service.duration_minutes,
          price_cents: service.base_price_cents,
          vehicle_description: "Blue Outback",
          service_address: "1 Cedar"
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

  describe "auth" do
    test "unauthenticated → /sign-in", %{conn: conn, tenant: tenant, appt: appt} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/appointments/#{appt.id}")
    end

    test "another customer in same tenant → bounce", ctx do
      {:ok, stranger} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "s-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, stranger)

      assert {:error, {:live_redirect, %{to: "/appointments"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/appointments/#{ctx.appt.id}")
    end
  end

  describe "view" do
    test "owning customer sees their own appointment", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      assert html =~ "Blue Outback"
      assert html =~ "Basic Wash"
    end

    test "admin sees the same appointment + admin actions", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      assert html =~ "Blue Outback"
      # Admin sees the Confirm button (status is pending)
      assert html =~ "Confirm"
    end
  end

  describe "actions" do
    test "owning customer can cancel through the reason form", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      render_click(lv, "show_cancel_form")

      lv
      |> form("#cancel-appointment-form", %{
        "cancel" => %{"reason" => "schedule_conflict", "details" => ""}
      })
      |> render_submit()

      reloaded = Ash.get!(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :cancelled
    end

    test "admin can resend the booking confirmation email", ctx do
      import Swoosh.TestAssertions

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      lv |> element("button[phx-click='resend_email']") |> render_click()

      assert_email_sent(fn email ->
        assert email.subject =~ ctx.tenant.display_name
        # The booker is a regular customer; the email goes to them.
        assert email.to == [{ctx.customer.name, to_string(ctx.customer.email)}]
      end)
    end

    test "non-admin doesn't see the resend button", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      refute html =~ ~s(phx-click="resend_email")
    end

    test "admin can refund a paid appointment", ctx do
      # Set up: tenant has Stripe Connect, appointment is paid + confirmed
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{
        stripe_account_id: "acct_refund_#{System.unique_integer([:positive])}",
        stripe_account_status: :enabled
      })
      |> Ash.update!(authorize?: false)

      pi_id = "pi_refundable_#{System.unique_integer([:positive])}"

      ctx.appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: pi_id})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      DrivewayOS.Billing.StripeClientMock
      |> expect(:refund_payment_intent, fn _connect_account, ^pi_id ->
        {:ok, %{id: "re_test_999", status: "succeeded"}}
      end)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      html =
        lv
        |> element("button[phx-click='refund']")
        |> render_click()

      # Optimistic local state — we flip immediately on Stripe success.
      # The real charge.refunded webhook will land later and confirm.
      reloaded = Ash.get!(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.payment_status == :refunded
      assert html =~ "Refund"
    end

    test "non-admin doesn't see a refund button", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{
        stripe_account_id: "acct_x_#{System.unique_integer([:positive])}",
        stripe_account_status: :enabled
      })
      |> Ash.update!(authorize?: false)

      ctx.appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: "pi_x"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      refute html =~ ~s(phx-click="refund")
    end

    test "admin can confirm", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      lv |> element("button[phx-click='confirm']") |> render_click()

      reloaded = Ash.get!(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :confirmed
    end
  end

  describe "customer cancellation with reason" do
    test "Cancel opens the inline reason form", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      html = render_click(lv, "show_cancel_form")

      assert html =~ "cancel-appointment-form"
      assert html =~ "Schedule conflict"
      assert html =~ "Bad weather"
    end

    test "submitting the form cancels with a structured reason", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      render_click(lv, "show_cancel_form")

      lv
      |> form("#cancel-appointment-form", %{
        "cancel" => %{
          "reason" => "weather",
          "details" => "Forecast says thunderstorms"
        }
      })
      |> render_submit()

      reloaded = Ash.get!(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :cancelled
      assert reloaded.cancellation_reason =~ "Bad weather"
      assert reloaded.cancellation_reason =~ "thunderstorms"
    end

    test "admin cancel still uses the bare confirm + 'Cancelled by admin' reason", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      lv |> element("button[phx-click='cancel']") |> render_click()

      reloaded = Ash.get!(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :cancelled
      assert reloaded.cancellation_reason == "Cancelled by admin"
    end
  end
end
