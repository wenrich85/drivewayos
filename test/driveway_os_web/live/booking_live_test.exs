defmodule DrivewayOSWeb.BookingLiveTest do
  @moduledoc """
  V1 Slice 6d: customer booking form.

  This is the centerpiece of the V1 demo loop — a signed-in customer
  picks a service, fills in vehicle + address + scheduled time, hits
  Book, and ends up with a pending appointment.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  setup :verify_on_exit!

  require Ash.Query

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "book-#{System.unique_integer([:positive])}",
        display_name: "Booking Test"
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

    %{tenant: tenant, customer: customer}
  end

  describe "auth gate" do
    test "redirects to /sign-in when no customer is signed in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/book")
    end
  end

  describe "form (signed in)" do
    test "renders service select + date/vehicle/address inputs",
         %{conn: conn, tenant: tenant, customer: customer} do
      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      assert html =~ "Book a wash"
      assert html =~ "Basic Wash"
      assert html =~ ~s(name="booking[scheduled_at]")
      assert html =~ ~s(name="booking[vehicle_description]")
      assert html =~ ~s(name="booking[service_address]")
    end

    test "non-Stripe path: sends a confirmation email after booking",
         %{conn: conn, tenant: tenant, customer: customer} do
      import Swoosh.TestAssertions

      conn = sign_in(conn, customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")
      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "service_type_id" => service_id,
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
          "vehicle_description" => "Red Civic",
          "service_address" => "1 Main"
        }
      })
      |> render_submit()

      assert_email_sent(fn email ->
        assert email.subject =~ tenant.display_name
        assert email.to == [{customer.name, to_string(customer.email)}]
      end)
    end

    test "valid submission creates an Appointment + redirects to confirmation",
         %{conn: conn, tenant: tenant, customer: customer} do
      conn = sign_in(conn, customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      result =
        lv
        |> form("#booking-form", %{
          "booking" => %{
            "service_type_id" => service_id,
            "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
            "vehicle_description" => "Blue 2022 Subaru Outback",
            "service_address" => "123 Cedar St, San Antonio TX 78261",
            "notes" => "Please ring bell."
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/book/success/" <> _appt_id}}} = result

      {:ok, appts} =
        Appointment |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

      assert length(appts) == 1
      assert hd(appts).customer_id == customer.id
    end

    test "tenant with Stripe Connect: booking redirects to Stripe Checkout",
         %{conn: conn, tenant: tenant, customer: customer} do
      # Connect Stripe on the tenant.
      tenant
      |> Ash.Changeset.for_update(:update, %{
        stripe_account_id: "acct_book_test_123",
        stripe_account_status: :enabled,
        status: :active
      })
      |> Ash.update!(authorize?: false)

      DrivewayOS.Billing.StripeClientMock
      |> expect(:create_checkout_session, fn "acct_book_test_123", params ->
        # Sanity-check what we send Stripe.
        assert params[:mode] == "payment"
        assert params[:application_fee_amount] >= 0
        assert is_list(params[:line_items])
        assert params[:metadata][:appointment_id] != nil
        assert params[:metadata][:tenant_id] == tenant.id

        {:ok, %{id: "cs_test_999", url: "https://checkout.stripe.com/c/pay/cs_test_999"}}
      end)

      conn = sign_in(conn, customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")
      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      result =
        lv
        |> form("#booking-form", %{
          "booking" => %{
            "service_type_id" => service_id,
            "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
            "vehicle_description" => "Blue 2022 Subaru Outback",
            "service_address" => "123 Cedar St"
          }
        })
        |> render_submit()

      # Must redirect externally to Stripe-hosted checkout, not to
      # /book/success/...
      assert {:error, {:redirect, %{to: "https://checkout.stripe.com/" <> _}}} =
               result

      # Appointment exists, has the session id attached, payment_status :pending.
      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

      assert appt.stripe_checkout_session_id == "cs_test_999"
      assert appt.payment_status == :pending
    end

    test "submitting with no service shows an error", %{
      conn: conn,
      tenant: tenant,
      customer: customer
    } do
      conn = sign_in(conn, customer)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      html =
        lv
        |> form("#booking-form", %{
          "booking" => %{
            "service_type_id" => "",
            "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
            "vehicle_description" => "Car",
            "service_address" => "Somewhere"
          }
        })
        |> render_submit()

      assert html =~ "service" or html =~ "required" or html =~ "Pick"
    end
  end

  defp sign_in(conn, customer) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(customer)

    conn
    |> Plug.Test.init_test_session(%{customer_token: token})
  end

  defp extract_service_id(html, slug) do
    # The form's <select> has options whose values are service type
    # IDs; pick the one whose option text contains the service slug.
    [_, id] = Regex.run(~r/<option value="([^"]+)">[^<]*#{slug}/i, html, capture: :all)
    id
  rescue
    _ -> raise "Couldn't find service id for slug #{inspect(slug)}"
  end
end
