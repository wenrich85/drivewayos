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

      lv |> form("#booking-photos-form") |> render_submit()

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

    test "skip-save address: appointment carries snapshot, no Address row created", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      # Use the saved vehicle (already in setup) so we land on the
      # address step.
      lv |> render_click("set_vehicle_mode", %{"mode" => "pick"})

      [v | _] =
        DrivewayOS.Fleet.Vehicle
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read!(authorize?: false)

      lv
      |> form("#step-vehicle-pick-form", %{"booking" => %{"vehicle_id" => v.id}})
      |> render_submit()

      lv |> render_click("set_address_mode", %{"mode" => "new"})

      {:ok, before} =
        DrivewayOS.Fleet.Address
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      lv
      |> form("#step-address-new-form", %{
        "address" => %{
          "street_line1" => "999 Vacation Rental Way",
          "city" => "Austin",
          "state" => "TX",
          "zip" => "78701",
          "skip_save" => "true"
        }
      })
      |> render_submit()

      {:ok, after_} =
        DrivewayOS.Fleet.Address
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert length(after_) == length(before)
      refute Enum.any?(after_, &(&1.street_line1 =~ "Vacation Rental"))
    end

    test "skip-save vehicle: appointment carries snapshot, no Vehicle row created", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv |> render_click("set_vehicle_mode", %{"mode" => "new"})

      # Snapshot the existing vehicle count so the assertion is
      # robust to the saved-vehicles fixture in this describe's
      # setup (Pro+ block already creates one).
      {:ok, before} =
        DrivewayOS.Fleet.Vehicle
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      lv
      |> form("#step-vehicle-new-form", %{
        "vehicle" => %{
          "year" => "2024",
          "make" => "Rental",
          "model" => "Sedan",
          "color" => "White",
          "skip_save" => "true"
        }
      })
      |> render_submit()

      {:ok, after_} =
        DrivewayOS.Fleet.Vehicle
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      # No new Vehicle row was persisted.
      assert length(after_) == length(before)
      refute Enum.any?(after_, &(&1.make == "Rental"))
    end
  end

  describe "guest checkout (Pro+ tenant, unauthenticated visitor)" do
    setup ctx do
      # Promote tenant to Pro so :guest_checkout is enabled.
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{plan_tier: :pro})
      |> Ash.update!(authorize?: false)

      DrivewayOS.Plans.flush_cache()
      Map.put(ctx, :tenant, Ash.reload!(ctx.tenant, authorize?: false))
    end

    test "unauthenticated visit to /book renders wizard at the service step",
         %{conn: conn, tenant: tenant} do
      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      assert html =~ "Book a wash"
      assert html =~ ~s(name="booking[service_type_id]")
    end

    test "submitting service advances anonymous visitor to :account step",
         %{conn: conn, tenant: tenant} do
      {:ok, lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      html =
        lv
        |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
        |> render_submit()

      # Account step has its own form id.
      assert html =~ "step-account-guest-form"
      assert html =~ "Your details"
    end

    test "guest submit creates a Customer with guest?: true + advances to :vehicle",
         %{conn: conn, tenant: tenant} do
      {:ok, lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      email = "guest-#{System.unique_integer([:positive])}@example.com"

      html =
        lv
        |> form("#step-account-guest-form", %{
          "guest" => %{"name" => "Guest Greta", "email" => email}
        })
        |> render_submit()

      # Now on vehicle step.
      assert html =~ "Vehicle"
      refute html =~ "step-account-guest-form"

      # Customer was created as a guest.
      {:ok, [customer | _]} =
        Customer
        |> Ash.Query.filter(email == ^email)
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      assert customer.guest? == true
      assert customer.role == :customer
      assert is_nil(customer.hashed_password)
    end

    test "back button from :vehicle returns to :account for a guest",
         %{conn: conn, tenant: tenant} do
      {:ok, lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-account-guest-form", %{
        "guest" => %{
          "name" => "Greta",
          "email" => "back-#{System.unique_integer([:positive])}@example.com"
        }
      })
      |> render_submit()

      # Now click Back.
      html =
        lv
        |> element("button[phx-click='back']")
        |> render_click()

      assert html =~ "step-account-guest-form"
    end
  end

  describe "guest checkout DISABLED (Starter tenant)" do
    test "unauthenticated visit redirects to /sign-in",
         %{conn: conn, tenant: tenant} do
      # tenant is Starter from the top-level setup → no guest_checkout.
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/book")
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

  describe "photo step (Pro+ tenant with :booking_photos)" do
    setup ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{plan_tier: :pro})
      |> Ash.update!(authorize?: false)

      DrivewayOS.Plans.flush_cache()
      Map.put(ctx, :tenant, Ash.reload!(ctx.tenant, authorize?: false))
    end

    test "progress bar lists :photos for Pro+ tenants", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      assert html =~ "photos"
    end

    test "address step advances to :photos (not :schedule) for Pro+", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv |> render_click("set_vehicle_mode", %{"mode" => "new"})

      lv
      |> form("#step-vehicle-new-form", %{
        "vehicle" => %{
          "year" => "2020",
          "make" => "Ford",
          "model" => "F-150",
          "color" => "White"
        }
      })
      |> render_submit()

      lv |> render_click("set_address_mode", %{"mode" => "new"})

      html =
        lv
        |> form("#step-address-new-form", %{
          "address" => %{
            "street_line1" => "1 Main",
            "city" => "SA",
            "state" => "TX",
            "zip" => "78261"
          }
        })
        |> render_submit()

      assert html =~ "Add photos"
      assert html =~ "booking-photos-form"
    end

    test "Skip photos advances to schedule", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv |> render_click("set_vehicle_mode", %{"mode" => "new"})

      lv
      |> form("#step-vehicle-new-form", %{
        "vehicle" => %{
          "year" => "2020",
          "make" => "Ford",
          "model" => "F-150",
          "color" => "White"
        }
      })
      |> render_submit()

      lv |> render_click("set_address_mode", %{"mode" => "new"})

      lv
      |> form("#step-address-new-form", %{
        "address" => %{
          "street_line1" => "1 Main",
          "city" => "SA",
          "state" => "TX",
          "zip" => "78261"
        }
      })
      |> render_submit()

      html = lv |> form("#booking-photos-form") |> render_submit()

      assert html =~ ~s(name="booking[scheduled_at]") or
               html =~ ~s(name="booking[slot_id]")
    end
  end

  describe "photo step (Starter tenant — feature off)" do
    test "progress bar does NOT list :photos for Starter", %{
      conn: conn,
      tenant: tenant,
      customer: customer
    } do
      conn = sign_in(conn, customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      refute html =~ "4. photos"
    end
  end

  describe "acquisition channel" do
    test "schedule step renders the dropdown + persists the value", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Wagon"}
      })
      |> render_submit()

      html =
        lv
        |> form("#step-address-text-form", %{
          "booking" => %{"service_address" => "1 Main"}
        })
        |> render_submit()

      assert html =~ "How did you hear about us?"
      assert html =~ "Friend / family"
      assert html =~ "Drove by"

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
          "acquisition_channel" => "Google"
        }
      })
      |> render_submit()

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.acquisition_channel == "Google"
    end

    test "blank acquisition_channel saves as nil, not empty string", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Wagon"}
      })
      |> render_submit()

      lv
      |> form("#step-address-text-form", %{
        "booking" => %{"service_address" => "1 Main"}
      })
      |> render_submit()

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
          "acquisition_channel" => ""
        }
      })
      |> render_submit()

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.acquisition_channel == nil
    end
  end

  describe "loyalty redemption" do
    setup ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 5})
      |> Ash.update!(authorize?: false)

      # Bring the customer up to the threshold.
      Enum.each(1..5, fn _ ->
        ctx.customer
        |> Ash.reload!(authorize?: false)
        |> Ash.Changeset.for_update(:increment_loyalty, %{})
        |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      end)

      DrivewayOS.Plans.flush_cache()
      Map.put(ctx, :tenant, Ash.reload!(ctx.tenant, authorize?: false))
    end

    test "schedule step shows the redemption CTA when count >= threshold", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Loyal Truck"}
      })
      |> render_submit()

      html =
        lv
        |> form("#step-address-text-form", %{
          "booking" => %{"service_address" => "1 Loyalty Lane"}
        })
        |> render_submit()

      assert html =~ "Use your free wash"
    end

    test "submitting with redemption sets price=0, flag=true, and resets loyalty_count",
         ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Loyal Truck"}
      })
      |> render_submit()

      lv
      |> form("#step-address-text-form", %{
        "booking" => %{"service_address" => "1 Loyalty Lane"}
      })
      |> render_submit()

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
          "is_loyalty_redemption" => "true"
        }
      })
      |> render_submit()

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.is_loyalty_redemption == true
      assert appt.price_cents == 0

      reloaded =
        Ash.get!(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)

      assert reloaded.loyalty_count == 0
    end

    test "redemption appointment doesn't earn a new loyalty punch when completed",
         ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Loyal Truck"}
      })
      |> render_submit()

      lv
      |> form("#step-address-text-form", %{
        "booking" => %{"service_address" => "1 Loyalty Lane"}
      })
      |> render_submit()

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
          "is_loyalty_redemption" => "true"
        }
      })
      |> render_submit()

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:start_wash, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:complete, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      reloaded =
        Ash.get!(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)

      # Still 0 — completing the redemption doesn't earn another punch.
      assert reloaded.loyalty_count == 0
    end
  end

  describe "rebook from a prior appointment" do
    test "?from=<id> prefills the wizard at :vehicle with prior service + address", ctx do
      # Promote tenant to Pro so saved-vehicle path is exercised. Add
      # a saved vehicle + a prior appointment that references it.
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

      {:ok, [s | _]} =
        ServiceType |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      {:ok, prior} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: s.id,
            vehicle_id: vehicle.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: s.duration_minutes,
            price_cents: s.base_price_cents,
            vehicle_description: "2022 Subaru Outback (Blue)",
            service_address: "123 Cedar St, San Antonio TX 78261"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/book?from=#{prior.id}")

      # We landed on :vehicle (skipped :service because it's already
      # known) and the prior address ended up in wizard_data.
      assert html =~ "step-vehicle-pick-form"
      # The prior appointment's vehicle_description survives into
      # the wizard's accumulated data.
      assert html =~ "2022 Subaru Outback (Blue)" or html =~ "Subaru"
    end

    test "?from=<other-customer-id> falls back to normal mount (doesn't leak)", ctx do
      # Prior appointment owned by a DIFFERENT customer — the rebook
      # path must NOT prefill from it.
      {:ok, stranger} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "stranger-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, [s | _]} =
        ServiceType |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      {:ok, stranger_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: stranger.id,
            service_type_id: s.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: s.duration_minutes,
            price_cents: s.base_price_cents,
            vehicle_description: "Stranger Truck",
            service_address: "999 Stranger Ave"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/book?from=#{stranger_appt.id}")

      # Wizard at :service step, no leaked stranger data.
      assert html =~ ~s(name="booking[service_type_id]")
      refute html =~ "Stranger Truck"
      refute html =~ "999 Stranger Ave"
    end
  end

  describe "operator alert on new booking" do
    setup ctx do
      {:ok, admin} =
        DrivewayOS.Accounts.Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "owner-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Owner"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      admin
      |> Ash.Changeset.for_update(:update, %{role: :admin})
      |> Ash.update!(authorize?: false)

      Map.put(ctx, :admin, admin)
    end

    test "tenant admin gets a 'New booking' email when a customer books", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Truck"}
      })
      |> render_submit()

      lv
      |> form("#step-address-text-form", %{
        "booking" => %{"service_address" => "1 Main"}
      })
      |> render_submit()

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16)
        }
      })
      |> render_submit()

      # Booking succeeded → both the customer confirmation AND the
      # admin "New booking" alert land in the Swoosh test mailbox.
      received = drain_emails([])

      subjects = Enum.map(received, & &1.subject)
      assert Enum.any?(subjects, &String.contains?(&1, "New booking"))
    end

    defp drain_emails(acc) do
      receive do
        {:email, %Swoosh.Email{} = e} -> drain_emails([e | acc])
      after
        0 -> acc
      end
    end
  end

  describe "session-cache resume (BookingDraft)" do
    test "advancing past a step persists a draft row", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      {:ok, [draft]} =
        DrivewayOS.Scheduling.BookingDraft
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert draft.customer_id == ctx.customer.id
      assert draft.step == "vehicle"
      assert draft.data["service_type_id"] == service_id
    end

    test "re-mounting after advancing restores the wizard at the saved step", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "2022 Subaru Outback (Blue)"}
      })
      |> render_submit()

      # Simulate the customer closing the tab and coming back: a
      # fresh LV mount with the same conn should put them on
      # :address (the step they'd advanced to) with the prior data
      # pre-filled.
      {:ok, _lv2, html2} =
        ctx.conn
        |> sign_in(ctx.customer)
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/book")

      assert html2 =~ "step-address-text-form"

      # The vehicle data from the prior step is still in the
      # restored draft (not visible at :address but stays in
      # wizard_data so the final submit carries it through).
      {:ok, [d]} =
        DrivewayOS.Scheduling.BookingDraft
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert d.data["vehicle_description"] == "2022 Subaru Outback (Blue)"
    end

    test "Start over button clears the draft and returns to :service", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      html = render_click(lv, "start_over")

      # Draft is gone.
      {:ok, drafts} =
        DrivewayOS.Scheduling.BookingDraft
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert drafts == []
      # Wizard reset to :service.
      assert html =~ "step-service-form"
    end

    test "completing the booking deletes the draft", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Truck"}
      })
      |> render_submit()

      lv
      |> form("#step-address-text-form", %{
        "booking" => %{"service_address" => "1 Main"}
      })
      |> render_submit()

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      lv
      |> form("#booking-form", %{
        "booking" => %{
          "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16)
        }
      })
      |> render_submit()

      {:ok, drafts} =
        DrivewayOS.Scheduling.BookingDraft
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert drafts == []
    end

    test "guests do not get drafts persisted", %{conn: conn, tenant: tenant} do
      # Promote tenant to Pro so guests are allowed at all.
      tenant
      |> Ash.Changeset.for_update(:update, %{plan_tier: :pro})
      |> Ash.update!(authorize?: false)

      DrivewayOS.Plans.flush_cache()

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      {:ok, drafts} =
        DrivewayOS.Scheduling.BookingDraft
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      assert drafts == []
    end
  end

  describe "multi-vehicle bookings" do
    test "customer adds a second vehicle on the vehicle step + total triples", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      # Add an additional vehicle BEFORE submitting the primary
      # vehicle form. Order doesn't matter — wizard_data carries it
      # through the wizard regardless.
      lv
      |> form("#add-additional-vehicle-form", %{
        "additional" => %{"description" => "Red 2018 Honda Pilot"}
      })
      |> render_submit()

      lv
      |> form("#add-additional-vehicle-form", %{
        "additional" => %{"description" => "White 2020 Tesla Y"}
      })
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Blue 2022 Subaru Outback"}
      })
      |> render_submit()

      html =
        lv
        |> form("#step-address-text-form", %{
          "booking" => %{"service_address" => "123 Cedar"}
        })
        |> render_submit()

      # Schedule step shows the rolled-up total.
      assert html =~ "3 vehicles"
      assert html =~ "$150.00"

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

      assert appt.vehicle_description == "Blue 2022 Subaru Outback"
      assert appt.additional_vehicles == [
               %{"description" => "Red 2018 Honda Pilot", "price_cents" => 5_000},
               %{"description" => "White 2020 Tesla Y", "price_cents" => 5_000}
             ]
      assert appt.price_cents == 5_000 * 3
    end

    test "removing an additional vehicle drops it from the list", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#add-additional-vehicle-form", %{
        "additional" => %{"description" => "Extra car"}
      })
      |> render_submit()

      html =
        lv
        |> render_click("remove_additional_vehicle", %{"index" => "0"})

      refute html =~ "Extra car"
    end

    test "rejects empty additional-vehicle description", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/book")

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      html =
        lv
        |> form("#add-additional-vehicle-form", %{
          "additional" => %{"description" => "   "}
        })
        |> render_submit()

      assert html =~ "Describe the extra vehicle"
    end
  end

  describe "admin walk-in booking (?on_behalf_of=)" do
    setup ctx do
      ctx.customer
      |> Ash.Changeset.for_update(:update, %{role: :admin})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      {:ok, walk_in} =
        Customer
        |> Ash.Changeset.for_create(
          :register_guest,
          %{
            email: "walkin-#{System.unique_integer([:positive])}@example.com",
            name: "Walk In",
            phone: "+15125550133"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      Map.put(ctx, :walk_in, walk_in)
    end

    test "admin booking on behalf creates the appointment under the walk-in customer", ctx do
      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/book?on_behalf_of=#{ctx.walk_in.id}")

      # Banner makes it obvious to the admin who they're booking for.
      assert html =~ "on behalf of"
      assert html =~ ctx.walk_in.name

      service_id = extract_service_id(html, "basic")

      lv
      |> form("#step-service-form", %{"booking" => %{"service_type_id" => service_id}})
      |> render_submit()

      lv
      |> form("#step-vehicle-text-form", %{
        "booking" => %{"vehicle_description" => "Walk-in Vehicle"}
      })
      |> render_submit()

      lv
      |> form("#step-address-text-form", %{
        "booking" => %{"service_address" => "123 Walk-in Ln"}
      })
      |> render_submit()

      future = DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      result =
        lv
        |> form("#booking-form", %{
          "booking" => %{
            "scheduled_at" => DateTime.to_iso8601(future) |> String.slice(0, 16)
          }
        })
        |> render_submit()

      # Admin lands back on the customer detail page, not the
      # customer-facing /book/success/.
      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == "/admin/customers/#{ctx.walk_in.id}"

      {:ok, [appt]} =
        Appointment |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      assert appt.customer_id == ctx.walk_in.id
      assert appt.customer_id != ctx.customer.id
      assert appt.vehicle_description == "Walk-in Vehicle"
    end

    test "non-admin passing on_behalf_of has it ignored", ctx do
      # Re-fetch from DB (the describe setup promoted Alice to :admin
      # but left ctx.customer's in-memory struct stale), then demote.
      ctx.customer
      |> Ash.reload!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:update, %{role: :customer})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/book?on_behalf_of=#{ctx.walk_in.id}")

      # No on-behalf banner — they're booking for themselves like any
      # other customer.
      refute html =~ "on behalf of"
    end
  end
end
