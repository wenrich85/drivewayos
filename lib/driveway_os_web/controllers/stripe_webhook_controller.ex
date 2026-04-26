defmodule DrivewayOSWeb.StripeWebhookController do
  @moduledoc """
  Receives Stripe webhook events and dispatches to per-tenant
  handlers.

  Tenant resolution: every Stripe Connect event carries the
  connected account id in the `account` field of the event (and
  the `Stripe-Account` header). We use that to look up the right
  tenant — there's no session, no JWT, just the API mapping.

  Signature verification: every event is signed with the platform's
  webhook signing secret. We forward the raw body + Stripe-Signature
  header to the StripeClient (mockable in tests) for HMAC checking.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Billing.StripeClient
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.Appointment

  require Ash.Query

  def handle(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""

    [signature | _] =
      case get_req_header(conn, "stripe-signature") do
        [] -> [""]
        list -> list
      end

    secret = Application.fetch_env!(:driveway_os, :stripe_webhook_secret)

    case StripeClient.construct_event(raw_body, signature, secret) do
      {:ok, event} ->
        :ok = process_event(event)
        send_resp(conn, 200, "ok")

      {:error, _reason} ->
        send_resp(conn, 400, "invalid signature")
    end
  end

  # --- Event dispatch ---

  defp process_event(%{"type" => "checkout.session.completed", "account" => account_id} = event) do
    case Platform.get_tenant_by_stripe_account(account_id) do
      {:ok, tenant} ->
        session = get_in(event, ["data", "object"]) || %{}
        session_id = session["id"]
        payment_intent = session["payment_intent"]

        case Appointment
             |> Ash.Query.for_read(:by_stripe_session, %{session_id: session_id})
             |> Ash.Query.set_tenant(tenant.id)
             |> Ash.read(authorize?: false) do
          {:ok, [appt]} ->
            updated =
              appt
              |> Ash.Changeset.for_update(:mark_paid, %{
                stripe_payment_intent_id: payment_intent
              })
              |> Ash.update!(authorize?: false, tenant: tenant.id)

            send_paid_confirmation(tenant, updated)
            :ok

          _ ->
            # No appointment matched — fine. Could be a different
            # checkout session (e.g. SaaS subscription), or stale.
            :ok
        end

      _ ->
        :ok
    end
  end

  defp process_event(%{"type" => "account.updated", "data" => %{"object" => obj}} = _event) do
    account_id = obj["id"]

    case Platform.get_tenant_by_stripe_account(account_id) do
      {:ok, tenant} ->
        new_status = derive_account_status(obj)

        tenant
        |> Ash.Changeset.for_update(:update, %{stripe_account_status: new_status})
        |> Ash.update!(authorize?: false)

        :ok

      _ ->
        :ok
    end
  end

  defp process_event(%{"type" => "charge.refunded", "account" => account_id, "data" => data}) do
    case Platform.get_tenant_by_stripe_account(account_id) do
      {:ok, tenant} ->
        pi_id = get_in(data, ["object", "payment_intent"])

        if is_binary(pi_id) do
          case Appointment
               |> Ash.Query.for_read(:by_payment_intent, %{payment_intent_id: pi_id})
               |> Ash.Query.set_tenant(tenant.id)
               |> Ash.read(authorize?: false) do
            {:ok, [appt | _]} ->
              # Idempotent: if the admin-side refund button already
              # flipped this row, the second flip is a no-op. We
              # still log an audit entry — the Stripe-initiated
              # path is distinct from the admin path even though
              # the resulting state matches.
              if appt.payment_status != :refunded do
                appt
                |> Ash.Changeset.for_update(:mark_refunded, %{})
                |> Ash.update!(authorize?: false, tenant: tenant.id)
              end

              Platform.log_audit!(%{
                action: :appointment_refunded,
                tenant_id: tenant.id,
                target_type: "Appointment",
                target_id: appt.id,
                payload: %{
                  "source" => "stripe_webhook",
                  "stripe_payment_intent_id" => pi_id,
                  "amount_refunded_cents" => get_in(data, ["object", "amount_refunded"])
                }
              })

            _ ->
              :ok
          end
        end

        :ok

      _ ->
        :ok
    end
  end

  defp process_event(
         %{"type" => "payment_intent.payment_failed", "account" => account_id, "data" => data}
       ) do
    case Platform.get_tenant_by_stripe_account(account_id) do
      {:ok, tenant} ->
        pi_id = get_in(data, ["object", "id"])

        if is_binary(pi_id) do
          case Appointment
               |> Ash.Query.for_read(:by_payment_intent, %{payment_intent_id: pi_id})
               |> Ash.Query.set_tenant(tenant.id)
               |> Ash.read(authorize?: false) do
            {:ok, [appt | _]} ->
              appt
              |> Ash.Changeset.for_update(:mark_payment_failed, %{})
              |> Ash.update!(authorize?: false, tenant: tenant.id)

              Platform.log_audit!(%{
                action: :appointment_payment_failed,
                tenant_id: tenant.id,
                target_type: "Appointment",
                target_id: appt.id,
                payload: %{
                  "source" => "stripe_webhook_payment_failed",
                  "stripe_payment_intent_id" => pi_id,
                  "failure_message" =>
                    get_in(data, ["object", "last_payment_error", "message"]) || "unknown"
                }
              })

            _ ->
              :ok
          end
        end

        :ok

      _ ->
        :ok
    end
  end

  defp process_event(_unknown_event), do: :ok

  # Map a Stripe Account object's flags to our internal status enum.
  # `:enabled`     — tenant can take charges + receive payouts
  # `:restricted`  — Stripe disabled them for some reason
  # `:pending`     — partial onboarding (details_submitted but
  #                  not yet charges/payouts enabled)
  # `:none`        — fresh, no onboarding info yet
  defp derive_account_status(%{
         "charges_enabled" => true,
         "payouts_enabled" => true,
         "details_submitted" => true
       }),
       do: :enabled

  defp derive_account_status(%{"requirements" => %{"disabled_reason" => reason}})
       when is_binary(reason),
       do: :restricted

  defp derive_account_status(%{"details_submitted" => true}), do: :pending
  defp derive_account_status(_), do: :none

  # Best-effort confirmation email after payment lands. We rescue
  # so a mailer hiccup never causes the webhook to fail (Stripe
  # would then retry and re-mark-paid, which is benign but noisy).
  defp send_paid_confirmation(tenant, appt) do
    with {:ok, customer} <-
           Ash.get(DrivewayOS.Accounts.Customer, appt.customer_id,
             tenant: tenant.id,
             authorize?: false
           ),
         {:ok, service} <-
           Ash.get(DrivewayOS.Scheduling.ServiceType, appt.service_type_id,
             tenant: tenant.id,
             authorize?: false
           ) do
      tenant
      |> BookingEmail.confirmation(customer, appt, service)
      |> Mailer.deliver()
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
