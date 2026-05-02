defmodule DrivewayOS.Scheduling.LoyaltyHooks do
  @moduledoc """
  Loyalty-related side effects fired from Appointment lifecycle
  hooks. Lives in its own module so the after_action callback in
  Appointment.:complete stays a single function call instead of
  inlining tenant lookup + customer reload + email send + audit.

  Public surface: `bump_after_complete/1`. Best-effort throughout
  — a loyalty-email failure must never roll back the underlying
  status transition.
  """
  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Platform.Tenant

  require Logger

  @doc """
  Increments the customer's loyalty_count and, if the new count
  matches the tenant's loyalty_threshold exactly, sends them a
  congratulatory "you earned a free wash" email. Sending exactly
  on the equals-threshold transition guarantees the email fires
  once per cycle (next-Nth completion will re-trigger after a
  redemption resets the count).
  """
  @spec bump_after_complete(map()) :: :ok
  def bump_after_complete(appt) do
    with {:ok, tenant} <- Ash.get(Tenant, appt.tenant_id, authorize?: false),
         {:ok, customer} <-
           Ash.get(Customer, appt.customer_id, tenant: appt.tenant_id, authorize?: false),
         {:ok, updated} <-
           customer
           |> Ash.Changeset.for_update(:increment_loyalty, %{})
           |> Ash.update(authorize?: false, tenant: appt.tenant_id) do
      maybe_send_earned_email(tenant, updated)
    end

    :ok
  rescue
    e ->
      Logger.warning("[loyalty_hooks] bump_after_complete crashed: #{inspect(e)}")
      :ok
  end

  defp maybe_send_earned_email(
         %Tenant{loyalty_threshold: t},
         %Customer{loyalty_count: c, marketing_emails_ok?: true} = customer
       )
       when is_integer(t) and is_integer(c) and c == t do
    tenant = Ash.get!(Tenant, customer.tenant_id, authorize?: false)

    tenant
    |> BookingEmail.loyalty_earned(customer, t)
    |> Mailer.deliver(Mailer.for_tenant(tenant))

    :ok
  rescue
    _ -> :ok
  end

  # Customer opted out of marketing-style emails — silent.
  defp maybe_send_earned_email(_, _), do: :ok
end
