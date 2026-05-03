defmodule DrivewayOSWeb.SquareWebhookController do
  @moduledoc """
  Receives Square webhook events.

  Signature verification: Square signs each event with HMAC-SHA256.
  The signed payload is `full_request_url <> raw_body` (base64
  output). Header: `x-square-hmacsha256-signature`. The raw body
  is preserved by `DrivewayOSWeb.CacheBodyReader` (registered as
  the Plug.Parsers body_reader in endpoint.ex).

  V1 only handles `payment.updated` with status COMPLETED — looks
  up the matching Appointment by `square_order_id` and calls
  `Appointment.mark_paid`. Phase 3's after_action chain on `:mark_paid`
  fires the Accounting.SyncWorker for tenants with Zoho connected.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Scheduling.Appointment

  require Ash.Query

  def handle(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""

    signature =
      case get_req_header(conn, "x-square-hmacsha256-signature") do
        [s | _] -> s
        _ -> ""
      end

    full_url = build_full_url(conn)
    key = Application.fetch_env!(:driveway_os, :square_webhook_signature_key)

    if valid_signature?(full_url <> raw_body, signature, key) do
      case Jason.decode(raw_body) do
        {:ok, event} ->
          process_event(event)
          send_resp(conn, 200, "ok")

        _ ->
          send_resp(conn, 400, "invalid body")
      end
    else
      send_resp(conn, 400, "invalid signature")
    end
  end

  # --- Event dispatch ---

  defp process_event(%{
         "type" => "payment.updated",
         "data" => %{"object" => %{"payment" => payment}}
       }) do
    if payment["status"] == "COMPLETED" do
      mark_paid(payment["order_id"], payment["id"])
    end

    :ok
  end

  defp process_event(_), do: :ok

  defp mark_paid(nil, _), do: :ok

  defp mark_paid(order_id, _payment_id) do
    # Find the Appointment by square_order_id across all tenants — we
    # don't know which tenant owns this order without checking. Use a
    # cross-tenant read via the Repo since Ash's tenant scoping
    # requires knowing the tenant up front, and the order_id is
    # globally unique per Square's design.
    case find_appointment_by_order_id(order_id) do
      {:ok, appt} ->
        appt
        |> Ash.Changeset.for_update(:mark_paid, %{square_order_id: order_id})
        |> Ash.update!(authorize?: false, tenant: appt.tenant_id)

      :error ->
        :ok
    end
  end

  defp find_appointment_by_order_id(order_id) do
    case DrivewayOS.Repo.get_by(Appointment, square_order_id: order_id) do
      nil -> :error
      appt -> {:ok, appt}
    end
  end

  defp valid_signature?(payload, candidate, key)
       when is_binary(candidate) and candidate != "" do
    expected = :crypto.mac(:hmac, :sha256, key, payload) |> Base.encode64()
    Plug.Crypto.secure_compare(expected, candidate)
  end

  defp valid_signature?(_, _, _), do: false

  defp build_full_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host

    port_part =
      cond do
        scheme == "https" and conn.port == 443 -> ""
        scheme == "http" and conn.port == 80 -> ""
        true -> ":#{conn.port}"
      end

    "#{scheme}://#{host}#{port_part}#{conn.request_path}"
  end
end
