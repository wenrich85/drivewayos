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
            appt
            |> Ash.Changeset.for_update(:mark_paid, %{
              stripe_payment_intent_id: payment_intent
            })
            |> Ash.update!(authorize?: false, tenant: tenant.id)

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

  defp process_event(_unknown_event), do: :ok
end
