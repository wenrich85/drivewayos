defmodule DrivewayOS.Onboarding.Providers.Resend do
  @moduledoc """
  Resend onboarding provider — Phase 4b's second email integration.

  Fully API-first (mirrors Phase 1 Postmark): `provision/2` POSTs
  to Resend's `/api-keys` endpoint, persists the resulting
  `key_id` + `api_key` on a new EmailConnection row, then sends a
  welcome/verification email through the just-provisioned api_key.
  The welcome send doubles as the deliverability probe.

  Master account auth: read `RESEND_API_KEY` via
  `:resend_api_key` application config (configured in
  runtime.exs). When unset, `configured?/0` returns false and
  Resend hides itself from the picker.

  V1 affiliate config returns nil — Resend's affiliate program
  enrollment is deferred. The picker still renders the card.
  """

  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.ResendClient
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{EmailConnection, Tenant}

  @impl true
  def id, do: :resend

  @impl true
  def category, do: :email

  @impl true
  def display do
    %{
      title: "Send booking emails via Resend",
      blurb:
        "Wire up Resend so confirmations, reminders, and receipts " <>
          "go to your customers from your shop's address.",
      cta_label: "Set up Resend",
      href: "/onboarding/resend/start"
    }
  end

  @impl true
  def configured? do
    case Application.get_env(:driveway_os, :resend_api_key) do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  @impl true
  def setup_complete?(%Tenant{id: tid}) do
    case Platform.get_email_connection(tid, :resend) do
      {:ok, %EmailConnection{api_key: key}} when is_binary(key) -> true
      _ -> false
    end
  end

  @impl true
  def provision(%Tenant{} = tenant, _params) do
    with {:ok, %{key_id: key_id, api_key: api_key}} <-
           ResendClient.create_api_key("drivewayos-#{tenant.slug}"),
         {:ok, _conn} <- save_connection(tenant, key_id, api_key),
         :ok <- send_welcome_email(tenant) do
      {:ok, tenant}
    end
  end

  @impl true
  def affiliate_config, do: nil

  @impl true
  def tenant_perk, do: nil

  defp save_connection(tenant, key_id, api_key) do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant.id,
      provider: :resend,
      external_key_id: key_id,
      api_key: api_key
    })
    |> Ash.create(authorize?: false)
  end

  defp send_welcome_email(tenant) do
    {:ok, admin} = first_admin(tenant)

    # The welcome email IS the deliverability probe for the
    # just-provisioned Resend api_key (per spec decision #7).
    # Routing through `Mailer.for_tenant/1` means a bad api_key
    # surfaces here at the most actionable moment, not silently at
    # the next booking confirmation.
    Mailer.deliver(welcome_email(tenant, admin), Mailer.for_tenant(tenant))
    :ok
  rescue
    e -> {:error, %{reason: :welcome_email_failed, exception: Exception.message(e)}}
  end

  defp first_admin(tenant) do
    case DrivewayOS.Accounts.tenant_admins(tenant.id) do
      [admin | _] -> {:ok, admin}
      _ -> {:error, :no_admin}
    end
  end

  defp welcome_email(tenant, admin) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({admin.name, to_string(admin.email)})
    |> Swoosh.Email.from(DrivewayOS.Branding.from_address(tenant))
    |> Swoosh.Email.subject("Your shop is set up to send email")
    |> Swoosh.Email.text_body("""
    Hi #{admin.name},

    #{tenant.display_name} is now wired up to send transactional
    emails through Resend. From this point on, booking
    confirmations, reminders, and receipts will go to your customers
    from your shop's email address.

    No action needed — this email is just confirmation that the
    connection works.

    -- DrivewayOS
    """)
  end
end
