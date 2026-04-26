defmodule DrivewayOSWeb.StripeWebhookControllerTest do
  @moduledoc """
  Stripe webhook → tenant resolution → appointment update.

  POST /webhooks/stripe is hit by Stripe Connect for events on a
  connected account; the `stripe-account` header tells us which
  tenant. Signature verification is mocked through the
  `StripeClient.construct_event/3` boundary so tests don't need a
  real signing secret.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.Appointment

  require Ash.Query

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: _admin}} =
      Platform.provision_tenant(%{
        slug: "swh-#{System.unique_integer([:positive])}",
        display_name: "Webhook Test Shop",
        admin_email: "wh-#{System.unique_integer([:positive])}@example.com",
        admin_name: "WH",
        admin_password: "Password123!"
      })

    tenant
    |> Ash.Changeset.for_update(:update, %{
      stripe_account_id: "acct_wh_test_#{System.unique_integer([:positive])}",
      stripe_account_status: :enabled,
      status: :active
    })
    |> Ash.update!(authorize?: false)

    tenant = Platform.get_tenant_by_slug!(tenant.slug)

    %{tenant: tenant}
  end

  describe "POST /webhooks/stripe" do
    test "valid checkout.session.completed marks the appointment paid",
         %{conn: conn, tenant: tenant} do
      # Set up an unpaid appointment with a known session id
      {:ok, [service | _]} =
        DrivewayOS.Scheduling.ServiceType
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, [admin | _]} =
        DrivewayOS.Accounts.Customer
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: admin.id,
            service_type_id: service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: service.duration_minutes,
            price_cents: service.base_price_cents,
            vehicle_description: "Test Vehicle",
            service_address: "1 Test Lane"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      session_id = "cs_webhook_#{System.unique_integer([:positive])}"

      appt
      |> Ash.Changeset.for_update(:attach_stripe_session, %{
        stripe_checkout_session_id: session_id,
        payment_status: :pending
      })
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      # Mock signature verification
      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _payload, _signature, _secret ->
        {:ok,
         %{
           "type" => "checkout.session.completed",
           "account" => tenant.stripe_account_id,
           "data" => %{
             "object" => %{
               "id" => session_id,
               "payment_intent" => "pi_test_123"
             }
           }
         }}
      end)

      conn =
        conn
        |> put_req_header("stripe-signature", "t=fake,v1=fake")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "lvh.me")
        |> post("/webhooks/stripe", "{}")

      assert conn.status == 200

      reloaded = Ash.get!(Appointment, appt.id, tenant: tenant.id, authorize?: false)
      assert reloaded.payment_status == :paid
      assert reloaded.status == :confirmed
      assert reloaded.stripe_payment_intent_id == "pi_test_123"

      # Confirmation email goes out from the webhook on the Stripe path
      # (BookingLive defers email until payment is confirmed).
      import Swoosh.TestAssertions
      assert_email_sent(fn email -> assert email.subject =~ tenant.display_name end)
    end

    test "invalid signature returns 400", %{conn: conn} do
      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _, _, _ -> {:error, :bad_signature} end)

      conn =
        conn
        |> put_req_header("stripe-signature", "garbage")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "lvh.me")
        |> post("/webhooks/stripe", "{}")

      assert conn.status == 400
    end

    test "account.updated maps charges_enabled → :enabled", %{conn: conn, tenant: tenant} do
      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _, _, _ ->
        {:ok,
         %{
           "type" => "account.updated",
           "account" => tenant.stripe_account_id,
           "data" => %{
             "object" => %{
               "id" => tenant.stripe_account_id,
               "charges_enabled" => true,
               "payouts_enabled" => true,
               "details_submitted" => true,
               "requirements" => %{"disabled_reason" => nil}
             }
           }
         }}
      end)

      # First put the tenant into a non-:enabled state so we can prove the bump.
      tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_status: :pending})
      |> Ash.update!(authorize?: false)

      conn =
        conn
        |> put_req_header("stripe-signature", "fake")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "lvh.me")
        |> post("/webhooks/stripe", "{}")

      assert conn.status == 200

      reloaded = DrivewayOS.Platform.get_tenant_by_slug!(tenant.slug)
      assert reloaded.stripe_account_status == :enabled
    end

    test "account.updated with disabled_reason → :restricted",
         %{conn: conn, tenant: tenant} do
      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _, _, _ ->
        {:ok,
         %{
           "type" => "account.updated",
           "account" => tenant.stripe_account_id,
           "data" => %{
             "object" => %{
               "id" => tenant.stripe_account_id,
               "charges_enabled" => false,
               "payouts_enabled" => false,
               "details_submitted" => true,
               "requirements" => %{"disabled_reason" => "requirements.past_due"}
             }
           }
         }}
      end)

      conn =
        conn
        |> put_req_header("stripe-signature", "fake")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "lvh.me")
        |> post("/webhooks/stripe", "{}")

      assert conn.status == 200

      reloaded = DrivewayOS.Platform.get_tenant_by_slug!(tenant.slug)
      assert reloaded.stripe_account_status == :restricted
    end

    test "charge.refunded marks the appointment :refunded",
         %{conn: conn, tenant: tenant} do
      {:ok, [service | _]} =
        DrivewayOS.Scheduling.ServiceType
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, [admin | _]} =
        DrivewayOS.Accounts.Customer
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: admin.id,
            service_type_id: service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: service.duration_minutes,
            price_cents: service.base_price_cents,
            vehicle_description: "RX",
            service_address: "1 Drive"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      pi_id = "pi_refund_test_#{System.unique_integer([:positive])}"

      appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: pi_id})
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _, _, _ ->
        {:ok,
         %{
           "type" => "charge.refunded",
           "account" => tenant.stripe_account_id,
           "data" => %{
             "object" => %{
               "payment_intent" => pi_id,
               "amount_refunded" => service.base_price_cents
             }
           }
         }}
      end)

      conn =
        conn
        |> put_req_header("stripe-signature", "fake")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "lvh.me")
        |> post("/webhooks/stripe", "{}")

      assert conn.status == 200

      reloaded = Ash.get!(Appointment, appt.id, tenant: tenant.id, authorize?: false)
      assert reloaded.payment_status == :refunded
    end

    test "charge.refunded writes an audit log entry tagged stripe_webhook",
         %{conn: conn, tenant: tenant} do
      {:ok, [service | _]} =
        DrivewayOS.Scheduling.ServiceType
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, [admin | _]} =
        DrivewayOS.Accounts.Customer
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: admin.id,
            service_type_id: service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: service.duration_minutes,
            price_cents: service.base_price_cents,
            vehicle_description: "Audit RX",
            service_address: "1 Audit Drive"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      pi_id = "pi_audit_#{System.unique_integer([:positive])}"

      appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: pi_id})
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _, _, _ ->
        {:ok,
         %{
           "type" => "charge.refunded",
           "account" => tenant.stripe_account_id,
           "data" => %{
             "object" => %{"payment_intent" => pi_id, "amount_refunded" => 5000}
           }
         }}
      end)

      conn
      |> put_req_header("stripe-signature", "fake")
      |> put_req_header("content-type", "application/json")
      |> Map.put(:host, "lvh.me")
      |> post("/webhooks/stripe", "{}")

      {:ok, [entry | _]} =
        DrivewayOS.Platform.AuditLog
        |> Ash.Query.filter(action == :appointment_refunded and target_id == ^appt.id)
        |> Ash.read(authorize?: false)

      assert entry.payload["source"] == "stripe_webhook"
      assert entry.payload["stripe_payment_intent_id"] == pi_id
    end

    test "payment_intent.payment_failed marks appointment :failed + audit",
         %{conn: conn, tenant: tenant} do
      {:ok, [service | _]} =
        DrivewayOS.Scheduling.ServiceType
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, [admin | _]} =
        DrivewayOS.Accounts.Customer
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      pi_id = "pi_fail_#{System.unique_integer([:positive])}"

      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: admin.id,
            service_type_id: service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: service.duration_minutes,
            price_cents: service.base_price_cents,
            vehicle_description: "Fail RX",
            service_address: "1 Fail Drive"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: pi_id})
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _, _, _ ->
        {:ok,
         %{
           "type" => "payment_intent.payment_failed",
           "account" => tenant.stripe_account_id,
           "data" => %{
             "object" => %{
               "id" => pi_id,
               "last_payment_error" => %{"message" => "Your card was declined."}
             }
           }
         }}
      end)

      conn =
        conn
        |> put_req_header("stripe-signature", "fake")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "lvh.me")
        |> post("/webhooks/stripe", "{}")

      assert conn.status == 200

      reloaded = Ash.get!(Appointment, appt.id, tenant: tenant.id, authorize?: false)
      assert reloaded.payment_status == :failed

      {:ok, [entry | _]} =
        DrivewayOS.Platform.AuditLog
        |> Ash.Query.filter(
          action == :appointment_payment_failed and target_id == ^appt.id
        )
        |> Ash.read(authorize?: false)

      assert entry.payload["failure_message"] == "Your card was declined."
    end

    test "unknown event type returns 200 (no-op)", %{conn: conn, tenant: tenant} do
      DrivewayOS.Billing.StripeClientMock
      |> expect(:construct_event, fn _, _, _ ->
        {:ok,
         %{
           "type" => "customer.subscription.created",
           "account" => tenant.stripe_account_id,
           "data" => %{"object" => %{}}
         }}
      end)

      conn =
        conn
        |> put_req_header("stripe-signature", "fake")
        |> put_req_header("content-type", "application/json")
        |> Map.put(:host, "lvh.me")
        |> post("/webhooks/stripe", "{}")

      assert conn.status == 200
    end
  end
end
