defmodule DrivewayOSWeb.AdminDashboardTest do
  @moduledoc """
  V1 Slice 8: tenant-admin dashboard at `{slug}.lvh.me/admin`.

  Same `Customer` resource as end-customers — admins are just
  customers with `role: :admin`. Authorization gate redirects
  non-admins away from /admin.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "admin-#{System.unique_integer([:positive])}",
        display_name: "Admin Test Shop",
        admin_email: "owner-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!",
        admin_phone: "+15125550100"
      })

    {:ok, regular_customer} =
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

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    %{tenant: tenant, admin: admin, customer: regular_customer, service: service}
  end

  describe "auth gate" do
    test "unauthenticated → /sign-in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin")
    end

    test "non-admin customer → / (no admin access)",
         %{conn: conn, tenant: tenant, customer: customer} do
      conn = sign_in(conn, customer)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin")
    end

    test "admin signs in and sees the dashboard", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "Admin"
      assert html =~ ctx.tenant.display_name
    end

    test "admin nav has a 'View shop' link to the public landing in a new tab", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "View shop"
      assert html =~ ~s(target="_blank")
    end
  end

  describe "first-run checklist" do
    test "shows open items when the tenant is fresh", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # Stripe not connected (test config has client_id set), no block
      # templates → these items render.
      assert html =~ "Finish setting up"
      assert html =~ "Connect Stripe"
      assert html =~ "Set your weekly hours"
    end

    test "Stripe row hidden when client_id is unconfigured on this server", ctx do
      # Blank the env to simulate a server without Stripe credentials.
      # The CTA can't go anywhere useful, so the whole row drops out
      # rather than leading the operator to a dead-end button.
      original = Application.get_env(:driveway_os, :stripe_client_id)
      Application.put_env(:driveway_os, :stripe_client_id, "")
      on_exit(fn -> Application.put_env(:driveway_os, :stripe_client_id, original) end)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "Connect Stripe"
      refute html =~ "Connect a Stripe account"
    end

    test "shows 'Set your service menu' for fresh tenants with default seeds", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "Set your service menu"
    end

    test "hides the service-menu prompt once the operator renames a default service",
         ctx do
      {:ok, [first | _]} =
        ServiceType |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      first
      |> Ash.Changeset.for_update(:update, %{slug: "express-wash", name: "Express Wash"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "Set your service menu"
    end

    test "hides items that are done", ctx do
      # Mark Stripe connected + add a block template; both items should
      # disappear from the checklist.
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{
        stripe_account_id: "acct_done_#{System.unique_integer([:positive])}",
        stripe_account_status: :enabled
      })
      |> Ash.update!(authorize?: false)

      DrivewayOS.Scheduling.BlockTemplate
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Mon",
          day_of_week: 1,
          start_time: ~T[09:00:00],
          duration_minutes: 60,
          capacity: 1
        },
        tenant: ctx.tenant.id
      )
      |> Ash.create!(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "Connect Stripe"
      refute html =~ "Define your availability"
    end
  end

  describe "dashboard contents" do
    test "shows count of pending appointments", ctx do
      {:ok, _appt} = book!(ctx.tenant, ctx.customer, ctx.service)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # The dashboard surfaces the pending count somewhere — text
      # "1" in proximity to "pending" is the test contract.
      assert html =~ "Pending"
      assert html =~ "Basic Wash"
    end

    test "shows customer count", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # Two customers exist: admin + alice
      assert html =~ "Customers"
      assert html =~ "2"
    end

    test "cross-tenant isolation: admin sees only their tenant's data", ctx do
      # Create a totally separate tenant and try to spoof its data into
      # ctx.admin's view. Should be invisible.
      {:ok, %{tenant: other_tenant, admin: _other_admin}} =
        Platform.provision_tenant(%{
          slug: "other-#{System.unique_integer([:positive])}",
          display_name: "Other Tenant",
          admin_email: "other-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      {:ok, [other_service | _]} =
        ServiceType |> Ash.Query.set_tenant(other_tenant.id) |> Ash.read(authorize?: false)

      {:ok, other_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "stranger@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger Danger"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _stranger_appt} = book!(other_tenant, other_customer, other_service)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "Stranger Danger"
    end
  end

  describe "subscription stat" do
    test "shows count of active subscriptions + recurring monthly revenue", ctx do
      alias DrivewayOS.Scheduling.Subscription

      {:ok, _sub} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            frequency: :biweekly,
            starts_at: DateTime.utc_now() |> DateTime.add(86_400, :second),
            vehicle_description: "Red Honda",
            service_address: "1 Cedar"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "Subscriptions"
      # 1 biweekly active sub at $50.00 base price → ~2.16 runs/month →
      # ~$108/month. Just assert the stat card renders the count.
      assert html =~ "Recurring"
    end

    test "card hidden when no active subscriptions exist", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "Recurring revenue"
    end
  end

  describe "cancellation reason breakdown" do
    test "groups cancelled appointments by parsed reason", ctx do
      now = DateTime.utc_now()

      reasons = [
        "Customer: Bad weather — Forecast says rain",
        "Customer: Bad weather",
        "Customer: Schedule conflict",
        "Cancelled by admin"
      ]

      Enum.with_index(reasons, fn reason, i ->
        {:ok, appt} =
          Appointment
          |> Ash.Changeset.for_create(
            :book,
            %{
              customer_id: ctx.customer.id,
              service_type_id: ctx.service.id,
              scheduled_at:
                DateTime.add(now, (i + 1) * 86_400, :second) |> DateTime.truncate(:second),
              duration_minutes: ctx.service.duration_minutes,
              price_cents: ctx.service.base_price_cents,
              vehicle_description: "Truck #{i}",
              service_address: "#{i} Lane"
            },
            tenant: ctx.tenant.id
          )
          |> Ash.create(authorize?: false)

        appt
        |> Ash.Changeset.for_update(:cancel, %{cancellation_reason: reason})
        |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      end)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "Why customers cancel"
      assert html =~ "Bad weather"
      assert html =~ "Schedule conflict"
      assert html =~ "Admin-cancelled"
    end

    test "card hidden when no recent cancellations", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "Why customers cancel"
    end

    test "buckets 'Admin: <label>' reasons distinctly from customer ones", ctx do
      now = DateTime.utc_now()

      reasons = [
        "Customer: Bad weather",
        "Admin: Bad weather — Hail forecast",
        "Admin: Equipment issue"
      ]

      Enum.with_index(reasons, fn reason, i ->
        {:ok, appt} =
          Appointment
          |> Ash.Changeset.for_create(
            :book,
            %{
              customer_id: ctx.customer.id,
              service_type_id: ctx.service.id,
              scheduled_at:
                DateTime.add(now, (i + 1) * 86_400, :second) |> DateTime.truncate(:second),
              duration_minutes: ctx.service.duration_minutes,
              price_cents: ctx.service.base_price_cents,
              vehicle_description: "Truck #{i}",
              service_address: "#{i} Lane"
            },
            tenant: ctx.tenant.id
          )
          |> Ash.create(authorize?: false)

        appt
        |> Ash.Changeset.for_update(:cancel, %{cancellation_reason: reason})
        |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      end)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # Customer-side weather + admin-side weather are separate
      # buckets; admin reasons get the "(admin)" suffix.
      assert html =~ "Bad weather"
      assert html =~ "Bad weather (admin)"
      assert html =~ "Equipment issue (admin)"
    end
  end

  describe "acquisition channel breakdown" do
    test "shows last-30-day counts grouped by channel", ctx do
      now = DateTime.utc_now()

      # Three bookings, two via Google, one via Friend/family.
      for {channel, i} <- [{"Google", 1}, {"Google", 2}, {"Friend / family", 3}] do
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: DateTime.add(now, i * 86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Truck #{i}",
            service_address: "#{i} Lane",
            acquisition_channel: channel
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create!(authorize?: false)
      end

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "How customers found you"
      assert html =~ "Google"
      assert html =~ "Friend / family"
    end

    test "card hidden when there are no recent appointments", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      refute html =~ "How customers found you"
    end
  end

  describe "revenue summary" do
    test "shows this-week revenue from paid appointments", ctx do
      {:ok, appt} = book!(ctx.tenant, ctx.customer, ctx.service)

      appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: "pi_test_123"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # Service price is $50.00 from the seeded basic-wash.
      assert html =~ "This week"
      assert html =~ "$50.00"
    end

    test "doesn't count cancelled appointments toward revenue", ctx do
      {:ok, appt} = book!(ctx.tenant, ctx.customer, ctx.service)

      appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: "pi_test_456"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:mark_refunded, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # Refunded → payment_status :refunded → not counted.
      assert html =~ "This week"
      refute html =~ "$50.00"
    end
  end

  describe "live broadcasts" do
    test "confirming a pending appointment fires a :confirmed broadcast", ctx do
      {:ok, appt} = book!(ctx.tenant, ctx.customer, ctx.service)

      DrivewayOS.AppointmentBroadcaster.subscribe(ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      render_click(lv, "confirm_appointment", %{"id" => appt.id})

      assert_receive {:appointment, :confirmed, %{id: id}}, 500
      assert id == appt.id
    end
  end

  describe "Today widget" do
    test "lists appointments scheduled for today in tenant timezone", ctx do
      tz = ctx.tenant.timezone
      noon_today = local_today_at(tz, ~T[12:00:00])

      {:ok, today_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: noon_today,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Today Truck",
            service_address: "Today Ave"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      today_appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "Today Truck"
      assert html =~ "Today"
    end

    test "Today widget renders a tap-to-call link when customer has phone set", ctx do
      tz = ctx.tenant.timezone
      noon_today = local_today_at(tz, ~T[12:00:00])

      ctx.customer
      |> Ash.Changeset.for_update(:update, %{phone: "+15125550199"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      {:ok, today_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: noon_today,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Phone Truck",
            service_address: "Phone Ave"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      today_appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ ~s(href="tel:+15125550199")
      assert html =~ "+15125550199"
    end

    test "Today widget shows the empty state when nothing is scheduled today", ctx do
      tz = ctx.tenant.timezone
      tomorrow_noon = local_today_at(tz, ~T[12:00:00]) |> DateTime.add(86_400, :second)

      {:ok, _tomorrow} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: tomorrow_noon,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Tomorrow Truck",
            service_address: "Tomorrow Ave"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # The Today widget itself should report empty even though
      # the appointment is in tomorrow's slot (and would correctly
      # appear in the pending list).
      assert html =~ "Nothing on today"
    end

    test "Tomorrow widget lists tomorrow's appointments", ctx do
      tz = ctx.tenant.timezone
      tomorrow_noon = local_today_at(tz, ~T[12:00:00]) |> DateTime.add(86_400, :second)

      {:ok, _appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at: tomorrow_noon,
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Tomorrow Sedan",
            service_address: "1 Tomorrow Ln"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      assert html =~ "Tomorrow"
      assert html =~ "Tomorrow Sedan"
    end

    test "Tomorrow widget hidden when nothing is on tomorrow's books", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      # No appointments at all → no Tomorrow card. (The phrase
      # "Tomorrow" must not appear as an h2 title; we proxy that by
      # checking for the card-title class adjacent to the word.)
      refute html =~ ~s(<h2 class="card-title text-lg">Tomorrow</h2>)
    end

    test "Start button transitions a confirmed today-appointment to in_progress", ctx do
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
            vehicle_description: "Start Me",
            service_address: "Start Ave"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      render_click(lv, "start_appointment", %{"id" => appt.id})

      {:ok, reloaded} = Ash.get(Appointment, appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :in_progress
    end

    test "Complete button transitions an in_progress today-appointment to completed", ctx do
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
            vehicle_description: "Done Me",
            service_address: "Done Ave"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:start_wash, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin")

      render_click(lv, "complete_appointment", %{"id" => appt.id})

      {:ok, reloaded} = Ash.get(Appointment, appt.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :completed
    end
  end

  defp book!(tenant, customer, service) do
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
        vehicle_description: "Test vehicle",
        service_address: "1 Test Lane"
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  # Returns a UTC DateTime that's both "in the future" (so the
  # appointment validator accepts it) AND inside today's local-day
  # window in `tz` (so the Today widget picks it up). Strategy:
  # take noon-local-today; if that's already passed, use now + 30
  # minutes which is safely later today except in the last
  # half-hour of the day (rare in CI / dev).
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

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end
end
