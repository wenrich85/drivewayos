defmodule DrivewayOS.Accounting.Provider do
  @moduledoc """
  Behaviour for accounting integrations. Each provider implements
  the same five callbacks; the facade in `DrivewayOS.Accounting`
  delegates based on the connection's `provider` atom.

  Every callback takes `connection :: AccountingConnection.t()` as
  its first arg. The connection carries the OAuth credentials, the
  tenant's external_org_id (Zoho's organization_id, QBO's realm_id),
  and the region — everything a provider call needs.

  Phase 4 adds QuickBooks Online by implementing this behaviour
  against the QBO REST API.
  """

  alias DrivewayOS.Platform.AccountingConnection

  @type connection :: AccountingConnection.t()

  @type contact_params :: %{
          required(:name) => String.t(),
          required(:email) => String.t(),
          optional(:phone) => String.t() | nil
        }

  @type line_item :: %{
          required(:name) => String.t(),
          required(:amount_cents) => integer(),
          optional(:quantity) => integer()
        }

  @type invoice_params :: %{
          required(:contact_id) => String.t(),
          required(:line_items) => [line_item()],
          required(:payment_id) => String.t(),
          optional(:notes) => String.t()
        }

  @type payment_params :: %{
          required(:amount_cents) => integer(),
          required(:payment_date) => Date.t(),
          optional(:reference) => String.t() | nil
        }

  @callback create_contact(connection(), contact_params()) :: {:ok, map()} | {:error, term()}
  @callback find_contact_by_email(connection(), String.t()) ::
              {:ok, map()} | {:error, :not_found} | {:error, term()}
  @callback create_invoice(connection(), invoice_params()) :: {:ok, map()} | {:error, term()}
  @callback record_payment(connection(), invoice_id :: String.t(), payment_params()) ::
              {:ok, map()} | {:error, term()}
  @callback get_invoice(connection(), invoice_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
