defmodule DrivewayOS.Accounting do
  @moduledoc """
  Facade over per-provider accounting modules. Resolves the provider
  module from `connection.provider` and delegates each call. Phase 3
  has only `:zoho_books`; Phase 4 will add `:quickbooks`.

  `sync_payment/5` is the high-level operation called from the Oban
  SyncWorker — it does the find-or-create-contact + create-invoice +
  record-payment chain in one call.
  """

  require Logger

  alias DrivewayOS.Platform.AccountingConnection

  @providers %{
    zoho_books: DrivewayOS.Accounting.ZohoBooks
  }

  @doc """
  Resolve a provider module from a connection. Raises if the provider
  isn't registered (programmer error — we'd never store an unknown
  provider in the DB given the `:one_of` constraint).
  """
  @spec provider_module!(AccountingConnection.t()) :: module()
  def provider_module!(%AccountingConnection{provider: provider}) do
    Map.fetch!(@providers, provider)
  end

  @doc """
  Find or create a contact in the accounting system by email.
  """
  @spec find_or_create_contact(AccountingConnection.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def find_or_create_contact(%AccountingConnection{} = conn, params) do
    mod = provider_module!(conn)

    case mod.find_contact_by_email(conn, params.email) do
      {:ok, contact} -> {:ok, contact}
      {:error, :not_found} -> mod.create_contact(conn, params)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_invoice(AccountingConnection.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_invoice(%AccountingConnection{} = conn, params) do
    provider_module!(conn).create_invoice(conn, params)
  end

  @spec record_payment(AccountingConnection.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def record_payment(%AccountingConnection{} = conn, invoice_id, params) do
    provider_module!(conn).record_payment(conn, invoice_id, params)
  end

  @doc """
  Full sync: find/create contact, create invoice, record payment.
  Called by `Accounting.SyncWorker`. Uses `tenant.display_name` in
  the invoice notes so each tenant's invoices look like their brand,
  not DrivewayOS's.
  """
  @spec sync_payment(
          AccountingConnection.t(),
          DrivewayOS.Platform.Tenant.t(),
          DrivewayOS.Scheduling.Appointment.t(),
          DrivewayOS.Accounts.Customer.t(),
          String.t()
        ) ::
          :ok | {:error, term()}
  def sync_payment(%AccountingConnection{} = conn, tenant, appointment, customer, service_name) do
    with {:ok, contact} <-
           find_or_create_contact(conn, %{
             name: customer.name,
             email: to_string(customer.email),
             phone: customer.phone
           }),
         contact_id = extract_contact_id(contact),
         {:ok, invoice} <-
           create_invoice(conn, %{
             contact_id: contact_id,
             line_items: [
               %{name: service_name, amount_cents: appointment.price_cents, quantity: 1}
             ],
             payment_id: appointment.stripe_payment_intent_id || appointment.id,
             notes: "#{tenant.display_name} — #{service_name}"
           }),
         invoice_id = extract_invoice_id(invoice),
         {:ok, _payment} <-
           record_payment(conn, invoice_id, %{
             amount_cents: appointment.price_cents,
             payment_date:
               (appointment.paid_at && DateTime.to_date(appointment.paid_at)) ||
                 Date.utc_today(),
             reference: appointment.stripe_payment_intent_id
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Accounting.sync_payment failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Provider response shapes vary; each impl returns a contact map,
  # but the id field's name differs. Phase 4 (QBO) extends these.
  defp extract_contact_id(%{"contact_id" => id}), do: id
  defp extract_contact_id(%{"Id" => id}), do: id
  defp extract_contact_id(c), do: c["id"]

  defp extract_invoice_id(%{"invoice_id" => id}), do: id
  defp extract_invoice_id(%{"Id" => id}), do: id
  defp extract_invoice_id(i), do: i["id"]
end
