defmodule DrivewayOSWeb.BookingSuccessLiveTest do
  @moduledoc """
  /book/success/:id — confirmation landing after a booking.

  Two paths:
    * Signed-in customer who just booked — owns the appointment.
    * Anonymous guest (Pro+ tenants only) — no session token, but
      gets to view the receipt because the appt's customer is
      `guest?: true`. Possessing the UUID-id is proof.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "succ-#{System.unique_integer([:positive])}",
        display_name: "Success Test",
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
        vehicle_description: "Test Truck",
        service_address: "1 Test Lane"
      },
      tenant: tenant.id
    )
    |> Ash.create!(authorize?: false)
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  describe "signed-in customer" do
    test "sees the booking summary", %{conn: conn, tenant: tenant} do
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

      {:ok, _lv, html} =
        conn
        |> sign_in(customer)
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> live(~p"/book/success/#{appt.id}")

      assert html =~ "Your booking is in"
      assert html =~ "Test Truck"
      # Signed-in customers see the My-appointments link.
      assert html =~ "My appointments"
      # Receipt names what the customer actually booked.
      assert html =~ "Basic Wash"
    end

    test "redirects when the appointment belongs to a different customer", %{
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

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> sign_in(alice)
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/book/success/#{bob_appt.id}")
    end
  end

  describe "self-serve subscribe" do
    test "signed-in non-guest customer can subscribe from the success page", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "subme-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "SubMe"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      appt = book_for(tenant, customer)

      {:ok, lv, html} =
        conn
        |> sign_in(customer)
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> live(~p"/book/success/#{appt.id}")

      assert html =~ "Make it recurring?"

      render_click(lv, "show_subscribe_form")

      lv
      |> form("#subscribe-form", %{"sub" => %{"frequency" => "biweekly"}})
      |> render_submit()

      {:ok, [sub]} =
        DrivewayOS.Scheduling.Subscription
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      assert sub.customer_id == customer.id
      assert sub.frequency == :biweekly
      # Recurring schedule starts AFTER the just-booked appointment so
      # the very next-cycle date doesn't double-book.
      assert DateTime.diff(sub.starts_at, appt.scheduled_at, :day) == 14
    end

    test "Starter tenant does NOT show the subscribe CTA (feature gated)", %{conn: conn} do
      {:ok, starter_tenant} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "starsucc-#{System.unique_integer([:positive])}",
          display_name: "Starter Success",
          plan_tier: :starter
        })
        |> Ash.create(authorize?: false)

      {:ok, _service} =
        ServiceType
        |> Ash.Changeset.for_create(
          :create,
          %{slug: "basic", name: "Basic Wash", base_price_cents: 5_000, duration_minutes: 45},
          tenant: starter_tenant.id
        )
        |> Ash.create(authorize?: false)

      DrivewayOS.Plans.flush_cache()

      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "starsub-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "StarSub"
          },
          tenant: starter_tenant.id
        )
        |> Ash.create(authorize?: false)

      appt = book_for(starter_tenant, customer)

      {:ok, _lv, html} =
        conn
        |> sign_in(customer)
        |> Map.put(:host, "#{starter_tenant.slug}.lvh.me")
        |> live(~p"/book/success/#{appt.id}")

      refute html =~ "Make it recurring?"
    end

    test "guest does NOT see the subscribe CTA", %{conn: conn, tenant: tenant} do
      {:ok, guest} =
        Customer
        |> Ash.Changeset.for_create(
          :register_guest,
          %{name: "Guest", email: "g-sub@example.com"},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      appt = book_for(tenant, guest)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> live(~p"/book/success/#{appt.id}")

      refute html =~ "Make it recurring?"
    end
  end

  describe "guest (no session)" do
    test "can view a receipt for a guest appointment", %{conn: conn, tenant: tenant} do
      {:ok, guest} =
        Customer
        |> Ash.Changeset.for_create(
          :register_guest,
          %{name: "Guest", email: "g@example.com"},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      appt = book_for(tenant, guest)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> live(~p"/book/success/#{appt.id}")

      assert html =~ "Your booking is in"
      assert html =~ "Test Truck"
      # Guests get a Create-account CTA, not the My-appointments link.
      assert html =~ "Create account"
      refute html =~ "My appointments"
    end

    test "cannot view a receipt for a NON-guest customer's appointment", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, alice} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "a2@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Alice"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      appt = book_for(tenant, alice)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/book/success/#{appt.id}")
    end
  end
end
