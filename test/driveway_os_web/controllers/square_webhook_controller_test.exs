defmodule DrivewayOSWeb.SquareWebhookControllerTest do
  @moduledoc """
  Square webhook → appointment lookup by `square_order_id` → mark_paid.

  Square signs each event with HMAC-SHA256 over `full_url <> raw_body`,
  base64-encoded, sent in the `x-square-hmacsha256-signature` header.
  Tests sign payloads with the configured `:square_webhook_signature_key`
  (set in `config/test.exs`).
  """
  use DrivewayOSWeb.ConnCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.Appointment

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "swh-#{System.unique_integer([:positive])}",
        display_name: "Square WH Test",
        admin_email: "swh-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    appt = create_appointment_with_square_order!(tenant, admin, "ord-test-1")

    %{tenant: tenant, admin: admin, appt: appt}
  end

  test "POST /webhooks/square verifies signature and marks appointment paid", ctx do
    raw_body = build_payment_completed_event("ord-test-1")
    signature = sign_body(raw_body, "/webhooks/square")

    conn =
      build_conn()
      |> put_req_header("x-square-hmacsha256-signature", signature)
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/square", raw_body)

    assert response(conn, 200)

    {:ok, refreshed} =
      Ash.get(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)

    assert refreshed.payment_status == :paid
  end

  test "POST /webhooks/square rejects bad signature" do
    raw_body = build_payment_completed_event("ord-test-1")

    conn =
      build_conn()
      |> put_req_header("x-square-hmacsha256-signature", "totally-wrong")
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/square", raw_body)

    assert response(conn, 400)
  end

  test "POST /webhooks/square ignores unknown order_id (returns 200, no-op)" do
    raw_body = build_payment_completed_event("ord-does-not-exist")
    signature = sign_body(raw_body, "/webhooks/square")

    conn =
      build_conn()
      |> put_req_header("x-square-hmacsha256-signature", signature)
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/square", raw_body)

    assert response(conn, 200)
  end

  defp build_payment_completed_event(order_id) do
    Jason.encode!(%{
      "type" => "payment.updated",
      "data" => %{
        "object" => %{
          "payment" => %{
            "order_id" => order_id,
            "status" => "COMPLETED",
            "id" => "pay_1"
          }
        }
      }
    })
  end

  defp sign_body(body, path) do
    # Square HMAC: base64(HMAC-SHA256(SIGNATURE_KEY, full_url + body))
    # ConnCase's build_conn defaults to host "www.example.com" on http port 80.
    full_url = "http://www.example.com#{path}"
    key = Application.fetch_env!(:driveway_os, :square_webhook_signature_key)

    :crypto.mac(:hmac, :sha256, key, full_url <> body)
    |> Base.encode64()
  end

  defp create_appointment_with_square_order!(tenant, admin, order_id) do
    {:ok, [service | _]} =
      DrivewayOS.Scheduling.ServiceType
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

    appt
    |> Ash.Changeset.for_update(:attach_stripe_session, %{
      square_order_id: order_id,
      payment_status: :pending
    })
    |> Ash.update!(authorize?: false, tenant: tenant.id)
  end
end
