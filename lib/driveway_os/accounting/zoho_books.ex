defmodule DrivewayOS.Accounting.ZohoBooks do
  @moduledoc """
  Zoho Books `Accounting.Provider` impl.

  Each callback takes the `AccountingConnection` and pulls the
  access_token + organization_id from it. HTTP is delegated to
  `ZohoClient.impl()` (production = `ZohoClient.Http`, tests = Mox).

  Shape ported from
  `MobileCarWash.Accounting.ZohoBooks` (single-tenant) — the three
  surgical multi-tenant edits per spec decision #2 are:
    1. tokens come from connection, not Application config
    2. organization_id comes from connection, not Application config
    3. invoice notes are caller-supplied (facade injects tenant.display_name)
  """
  @behaviour DrivewayOS.Accounting.Provider

  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform.AccountingConnection

  @impl true
  def create_contact(%AccountingConnection{} = conn, params) do
    body = %{
      "contact_name" => params.name,
      "email" => params.email,
      "phone" => params[:phone],
      "contact_type" => "customer"
    }

    case ZohoClient.impl().api_post(conn.access_token, conn.external_org_id, "/contacts", body) do
      {:ok, %{"contact" => contact}} -> {:ok, contact}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def find_contact_by_email(%AccountingConnection{} = conn, email) when is_binary(email) do
    case ZohoClient.impl().api_get(
           conn.access_token,
           conn.external_org_id,
           "/contacts",
           email: email
         ) do
      {:ok, %{"contacts" => [contact | _]}} -> {:ok, contact}
      {:ok, %{"contacts" => []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_invoice(%AccountingConnection{} = conn, params) do
    line_items =
      Enum.map(params.line_items, fn item ->
        %{
          "name" => item.name,
          "rate" => item.amount_cents / 100,
          "quantity" => item[:quantity] || 1
        }
      end)

    body = %{
      "customer_id" => params.contact_id,
      "line_items" => line_items,
      "notes" => params[:notes] || "Thank you for your business!",
      "reference_number" => params.payment_id
    }

    case ZohoClient.impl().api_post(conn.access_token, conn.external_org_id, "/invoices", body) do
      {:ok, %{"invoice" => invoice}} -> {:ok, invoice}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def record_payment(%AccountingConnection{} = conn, invoice_id, params) do
    body = %{
      "amount" => params.amount_cents / 100,
      "date" => Date.to_iso8601(params.payment_date),
      "payment_mode" => "creditcard",
      "reference_number" => params[:reference]
    }

    case ZohoClient.impl().api_post(
           conn.access_token,
           conn.external_org_id,
           "/invoices/#{invoice_id}/payments",
           body
         ) do
      {:ok, %{"payment" => payment}} -> {:ok, payment}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_invoice(%AccountingConnection{} = conn, invoice_id) do
    case ZohoClient.impl().api_get(
           conn.access_token,
           conn.external_org_id,
           "/invoices/#{invoice_id}",
           []
         ) do
      {:ok, %{"invoice" => invoice}} -> {:ok, invoice}
      {:error, reason} -> {:error, reason}
    end
  end
end
