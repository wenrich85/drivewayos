defmodule DrivewayOSWeb.AdminAppointmentsExportController do
  @moduledoc """
  CSV export of every appointment in the current tenant for
  accounting + bookkeeping. One column per row of the scheduled
  table the operator already sees on /admin/appointments, plus a
  rolled-up "vehicles" column that flattens the multi-vehicle list.

  Auth: must be a tenant-scoped customer with role :admin. Any
  other state — anonymous, non-admin, cross-tenant — returns 404
  rather than leaking auth detail.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  def appointments(conn, _params) do
    tenant = conn.assigns[:current_tenant]
    me = conn.assigns[:current_customer]

    with %{} = tenant <- tenant,
         %Customer{role: :admin} <- me,
         {:ok, appts} <- read_appointments(tenant.id),
         {:ok, customer_map, service_map} <- read_lookups(tenant.id) do
      csv = build_csv(appts, customer_map, service_map)
      filename = "appointments-#{tenant.slug}-#{Date.utc_today()}.csv"

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename}")
      )
      |> send_resp(200, csv)
    else
      _ -> send_resp(conn, 404, "Not found.")
    end
  end

  defp read_appointments(tenant_id) do
    Appointment
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.Query.sort(scheduled_at: :desc)
    |> Ash.read(authorize?: false)
  end

  defp read_lookups(tenant_id) do
    with {:ok, customers} <-
           Customer |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false),
         {:ok, services} <-
           ServiceType |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false) do
      {:ok, Map.new(customers, &{&1.id, &1}), Map.new(services, &{&1.id, &1})}
    end
  end

  @columns [
    "Scheduled at",
    "Customer",
    "Email",
    "Phone",
    "Service",
    "Vehicles",
    "Address",
    "Status",
    "Payment",
    "Total",
    "Channel",
    "Booked at"
  ]

  defp build_csv(appts, customer_map, service_map) do
    rows = Enum.map(appts, &row(&1, customer_map, service_map))

    [@columns | rows]
    |> Enum.map_join("\r\n", &encode_row/1)
  end

  defp row(a, customer_map, service_map) do
    customer = Map.get(customer_map, a.customer_id, %{name: "—", email: "", phone: ""})
    service = Map.get(service_map, a.service_type_id, %{name: "—"})
    extra_descs = Enum.map(a.additional_vehicles || [], & &1["description"])
    vehicles = [a.vehicle_description | extra_descs] |> Enum.join("; ")

    [
      DateTime.to_iso8601(a.scheduled_at),
      customer.name,
      to_string(customer.email),
      customer.phone || "",
      service.name,
      vehicles,
      a.service_address,
      Atom.to_string(a.status),
      Atom.to_string(a.payment_status || :unpaid),
      :erlang.float_to_binary(a.price_cents / 100, decimals: 2),
      a.acquisition_channel || "",
      DateTime.to_iso8601(a.inserted_at)
    ]
  end

  defp encode_row(cells), do: Enum.map_join(cells, ",", &encode_cell/1)

  # RFC 4180: a cell containing comma, quote, CR, or LF gets quoted
  # and embedded quotes doubled. Everything else passes through bare.
  defp encode_cell(value) do
    s = to_string(value)

    if needs_quoting?(s) do
      ~s(") <> String.replace(s, ~s("), ~s("")) <> ~s(")
    else
      s
    end
  end

  defp needs_quoting?(s) do
    String.contains?(s, [",", ~s("), "\r", "\n"])
  end
end
