defmodule DrivewayOS.Accounts.Deletion do
  @moduledoc """
  GDPR-style "delete my data" orchestrator. The customer-facing
  /me handler is a thin one-liner that calls `request/2`; the
  hard work — scrubbing identifying fields, cancelling active
  subscriptions, destroying personal saved data — lives here.

  Strategy: ANONYMIZE rather than DELETE. Past appointments stay
  on the tenant's books (operators need them for accounting +
  audit) but are decoupled from the customer's identifying
  details. The synthetic email
  `deleted-<uuid>@deleted.invalid` preserves the unique-email
  identity without conflicting with future signups.

  Side effects, in order:
    1. Send the confirmation email (must run BEFORE step 5 — once
       email is scrubbed it can't deliver).
    2. Cancel every active Subscription for this customer (no
       future auto-bookings).
    3. Destroy saved Vehicles + Addresses + BookingDrafts.
    4. Run the :anonymize action on the Customer row.

  Returns `:ok` on success, `{:error, reason}` if step 4 fails;
  earlier steps are best-effort and never block the anonymization.
  """
  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Fleet.{Address, Vehicle}
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{BookingDraft, Subscription}

  require Ash.Query
  require Logger

  @doc """
  Delete + anonymize the given customer's account in the given
  tenant. Caller is responsible for verifying the customer is
  authorized to do this (typically: the customer is the
  signed-in user on /me, so it's their own row).
  """
  @spec request(Tenant.t(), Customer.t()) :: :ok | {:error, term()}
  def request(%Tenant{} = tenant, %Customer{} = customer) do
    send_confirmation(tenant, customer)
    cancel_subscriptions(tenant, customer)
    destroy_personal_records(tenant, customer)

    case anonymize(tenant, customer) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp send_confirmation(tenant, customer) do
    tenant
    |> BookingEmail.account_deleted(customer)
    |> Mailer.deliver()
  rescue
    e ->
      Logger.warning("[deletion] confirmation email failed: #{inspect(e)}")
      :ok
  end

  defp cancel_subscriptions(tenant, customer) do
    case Subscription
         |> Ash.Query.for_read(:for_customer, %{customer_id: customer.id})
         |> Ash.Query.set_tenant(tenant.id)
         |> Ash.read(authorize?: false) do
      {:ok, subs} ->
        Enum.each(subs, fn sub ->
          if sub.status != :cancelled do
            sub
            |> Ash.Changeset.for_update(:cancel, %{})
            |> Ash.update(authorize?: false, tenant: tenant.id)
          end
        end)

      _ ->
        :ok
    end
  end

  defp destroy_personal_records(tenant, customer) do
    for resource <- [Vehicle, Address, BookingDraft] do
      destroy_for_customer(resource, customer.id, tenant.id)
    end
  end

  defp destroy_for_customer(resource, customer_id, tenant_id) do
    case resource
         |> Ash.Query.filter(customer_id == ^customer_id)
         |> Ash.Query.set_tenant(tenant_id)
         |> Ash.read(authorize?: false) do
      {:ok, rows} ->
        Enum.each(rows, &Ash.destroy(&1, authorize?: false, tenant: tenant_id))

      _ ->
        :ok
    end
  end

  defp anonymize(tenant, customer) do
    customer
    |> Ash.Changeset.for_update(:anonymize, %{})
    |> Ash.update(authorize?: false, tenant: tenant.id)
  end
end
