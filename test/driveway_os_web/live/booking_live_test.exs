defmodule DrivewayOSWeb.BookingLiveTest do
  @moduledoc """
  Booking-wizard LV tests.

  The wizard is a 4-step flow (service → vehicle → address →
  schedule). For Starter-tier tenants the vehicle + address steps
  use free-text inputs; Pro+ tenants pick from saved rows or add
  new ones inline.

  Setup uses Starter so the free-text path is the default; Pro+
  behavior gets its own dedicated tests.
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
        display_name: "Booking Test",
        plan_tier: :starter
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

  describe "wizard step 1 — service" do
    test "initial render shows service select", %{conn: conn, tenant: tenant, customer: customer} do
      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      assert html =~ "Book a wash"
      assert html =~ "Basic Wash"
      assert html =~ ~s(name="booking[service_type_id]")
    end

    test "submitting empty service shows error", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      html =
        lv
        |> form("#step-service-form", %{"booking" => %{"service_type_id" => ""}})
        |> render_submit()

      assert html =~ "Pick a service"
    end

    test "submitting valid service advances to vehicle step", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      html =
        lv
        |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
        |> render_submit()

      # Now on vehicle step (Starter tenant → free-text).
      assert html =~ ~s(name="booking[vehicle_description]")
    end
  end

  describe "wizard step 2 — vehicle (Starter free-text)" do
    test "free-text submit advances to address step", ctx do
      lv = walk_to(:vehicle, ctx)

      html =
        lv
        |> form("#step-vehicle-text-form", %{
          "booking" => %{"vehicle_description" => "Red Civic"}
        })
        |> render_submit()

      assert html =~ ~s(name="booking[service_address]")
    end

    test "empty vehicle description is rejected", ctx do
      lv = walk_to(:vehicle, ctx)

      html =
        lv
        |> form("#step-vehicle-text-form", %{
          "booking" => %{"vehicle_description" => ""}
        })
        |> render_submit()

      assert html =~ "Describe your vehicle"
    end
  end

  describe "wizard step 3 — address (Starter free-text)" do
    test "free-text submit advances to schedule step", ctx do
      lv = walk_to(:address, ctx)

      html =
        lv
        |> form("#step-address-text-form", %{
          "booking" => %{"service_address" => "123 Main"}
        })
        |> render_submit()

      assert html =~ ~s(name="booking[scheduled_at]") or
               html =~ ~s(name="booking[slot_id]")
    end
  end

  describe "wizard step 4 — schedule + final submit" do
    test "valid submission creates an Appointment + redirects to confirmation",
         ctx do
      lv = walk_to(:schedule, ctx)
      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      result =
        lv
        |> form("#booking-form", %{
          "booking" => %{
            "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
            "notes" => "Please ring bell."
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/book/success/" <> _appt_id}}} = result

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.customer_id == ctx.customer.id
      # Snapshot strings persisted from prior steps.
      assert appt.vehicle_description == "Blue 2022 Subaru Outback"
      assert appt.service_address == "123 Cedar St, San Antonio TX 78261"
      # Starter tenants don't link saved rows.
      assert is_nil(appt.vehicle_id)
      assert is_nil(appt.address_id)
    end

    test "non-Stripe path: sends a confirmation email after booking", ctx do
      import Swoosh.TestAssertions

      lv = walk_to(:schedule, ctx)
      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16)
        }
      })
      |> render_submit()

      assert_email_sent(fn email ->
        assert email.subject =~ ctx.tenant.display_name
        assert email.to == [{ctx.customer.name, to_string(ctx.customer.email)}]
      end)
    end

    test "tenant with Stripe Connect: booking redirects to Stripe Checkout", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{
        stripe_account_id: "acct_book_test_123",
        stripe_account_status: :enabled,
        status: :active
      })
      |> Ash.update!(authorize?: false)

      DrivewayOS.Billing.StripeClientMock
      |> expect(:create_checkout_session, fn "acct_book_test_123", params ->
        assert params[:mode] == "payment"
        assert params[:application_fee_amount] >= 0
        assert is_list(params[:line_items])
        assert params[:metadata][:appointment_id] != nil
        assert params[:metadata][:tenant_id] == ctx.tenant.id

        {:ok, %{id: "cs_test_999", url: "https://checkout.stripe.com/c/pay/cs_test_999"}}
      end)

      lv = walk_to(:schedule, ctx)
      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      result =
        lv
        |> form("#booking-form", %{
          "booking" => %{
            "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16)
          }
        })
        |> render_submit()

      assert {:error, {:redirect, %{to: "https://checkout.stripe.com/" <> _}}} = result

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.stripe_checkout_session_id == "cs_test_999"
      assert appt.payment_status == :pending
    end

    test "with block templates: schedule step shows slot picker", ctx do
      today_dow = Integer.mod(Date.day_of_week(Date.utc_today(), :sunday) - 1, 7)

      {:ok, _bt} =
        DrivewayOS.Scheduling.BlockTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Daily morning",
            day_of_week: today_dow,
            start_time: ~T[09:00:00],
            duration_minutes: 60,
            capacity: 1
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      lv = walk_to(:schedule, ctx)
      html = render(lv)

      assert html =~ ~s(name="booking[slot_id]")
      assert html =~ "Daily morning"
    end
  end

  describe "Pro+ tier — saved vehicles + addresses" do
    setup ctx do
      # Promote the tenant to Pro for these tests.
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{plan_tier: :pro})
      |> Ash.update!(authorize?: false)

      DrivewayOS.Plans.flush_cache()

      {:ok, vehicle} =
        DrivewayOS.Fleet.Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            year: 2022,
            make: "Subaru",
            model: "Outback",
            color: "Blue"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, address} =
        DrivewayOS.Fleet.Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            street_line1: "123 Cedar St",
            city: "San Antonio",
            state: "TX",
            zip: "78261"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      tenant = Ash.reload!(ctx.tenant, authorize?: false)
      Map.merge(ctx, %{tenant: tenant, vehicle: vehicle, address: address})
    end

    test "vehicle step shows saved-picker by default + lets customer pick",
         ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      html = render(lv)
      # Pro mode: shows a saved-vehicle radio picker, NOT free-text.
      assert html =~ "step-vehicle-pick-form"
      assert html =~ "2022 Subaru Outback (Blue)"
    end

    test "selecting a saved vehicle persists vehicle_id on the appointment",
         ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-pick-form", %{"booking" => %{"vehicle_id" => ctx.vehicle.id}})
      |> render_submit()

      lv
      |> form("#step-address-pick-form", %{"booking" => %{"address_id" => ctx.address.id}})
      |> render_submit()

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16)
        }
      })
      |> render_submit()

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.vehicle_id == ctx.vehicle.id
      assert appt.address_id == ctx.address.id
      # Snapshot strings populated from the saved rows' display labels.
      assert appt.vehicle_description == "2022 Subaru Outback (Blue)"
      assert appt.service_address == "123 Cedar St, San Antonio TX 78261"
    end

    test "Add new vehicle inline creates a Vehicle row + uses it for the booking",
         ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      # Switch to "Add new" mode, fill the form.
      lv |> render_click("set_vehicle_mode", %{"mode" => "new"})

      lv
      |> form("#step-vehicle-new-form", %{
        "vehicle" => %{
          "year" => "2018",
          "make" => "Toyota",
          "model" => "Tacoma",
          "color" => "Silver"
        }
      })
      |> render_submit()

      # The new vehicle was created.
      {:ok, vehicles} =
        DrivewayOS.Fleet.Vehicle
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert Enum.any?(vehicles, &(&1.make == "Toyota" and &1.model == "Tacoma"))
    end
  end

  # --- Helpers ---

  defp sign_in(conn, customer) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  defp extract_service_id(html, slug) do
    [_, id] = Regex.run(~r/<option value="([^"]+)">[^<]*#{slug}/i, html, capture: :all)
    id
  rescue
    _ -> raise "Couldn't find service id for slug #{inspect(slug)}"
  end

  # Walk the wizard to a target step. Tests start at :service and
  # the helper picks valid defaults at each prior step. Returns the
  # LV pid ready for the test to interact with the target step.
  defp walk_to(target_step, ctx) when target_step in [:vehicle, :address, :schedule] do
    conn = sign_in(ctx.conn, ctx.customer)

    {:ok, lv, html} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

    service_id = extract_service_id(html, "basic")

    lv
    |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
    |> render_submit()

    if target_step == :vehicle, do: lv, else: walk_past_vehicle(lv, target_step)
  end

  defp walk_past_vehicle(lv, target_step) do
    lv
    |> form("#step-vehicle-text-form", %{
      "booking" => %{"vehicle_description" => "Blue 2022 Subaru Outback"}
    })
    |> render_submit()

    if target_step == :address, do: lv, else: walk_past_address(lv)
  end

  defp walk_past_address(lv) do
    lv
    |> form("#step-address-text-form", %{
      "booking" => %{"service_address" => "123 Cedar St, San Antonio TX 78261"}
    })
    |> render_submit()

    lv
  end
end
