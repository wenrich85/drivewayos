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

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

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
    test "owning customer can cancel", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/appointments/#{ctx.appt.id}")

      lv |> element("button[phx-click='cancel']") |> render_click()

      reloaded = Ash.get!(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :cancelled
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
end
