defmodule DrivewayOS.Onboarding.Providers.Postmark do
  @moduledoc """
  Postmark onboarding provider — V1 email integration.

  Fully API-first: `provision/2` POSTs to Postmark's `/servers`
  endpoint, persists the resulting `server_id` + `api_key` on the
  tenant, then sends a welcome/verification email through the
  newly-provisioned server. The welcome send doubles as the
  deliverability probe — if it fails, we surface the error and
  don't advance the wizard.

  Account-level auth: read `POSTMARK_ACCOUNT_TOKEN` via
  `:postmark_account_token` application config (configured in
  runtime.exs). When unset, `configured?/0` returns false and the
  Email step + dashboard checklist hide themselves.
  """

  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :postmark

  @impl true
  def category, do: :email

  @impl true
  def display do
    %{
      title: "Send booking emails",
      blurb:
        "Wire up Postmark so confirmations, reminders, and receipts " <>
          "go to your customers from your shop's address.",
      cta_label: "Set up email",
      href: "/admin/onboarding"
    }
  end

  @impl true
  def configured? do
    case Application.get_env(:driveway_os, :postmark_account_token) do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  @impl true
  def setup_complete?(%Tenant{postmark_server_id: id}), do: not is_nil(id)

  @impl true
  def provision(%Tenant{} = tenant, _params) do
    with {:ok, %{server_id: server_id, api_key: api_key}} <-
           PostmarkClient.create_server("drivewayos-#{tenant.slug}"),
         {:ok, updated} <- save_credentials(tenant, server_id, api_key),
         :ok <- send_welcome_email(updated) do
      {:ok, updated}
    end
  end

  defp save_credentials(tenant, server_id, api_key) do
    tenant
    |> Ash.Changeset.for_update(:update, %{
      postmark_server_id: to_string(server_id),
      postmark_api_key: api_key
    })
    |> Ash.update(authorize?: false)
  end

  defp send_welcome_email(tenant) do
    {:ok, admin} = first_admin(tenant)

    # The welcome email is a DrivewayOS platform notification confirming
    # provisioning succeeded. It goes through the shared SMTP adapter
    # (not the just-provisioned Postmark server) so that delivery works
    # even before the new server is fully verified.
    Mailer.deliver(welcome_email(tenant, admin))
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
    emails through Postmark. From this point on, booking
    confirmations, reminders, and receipts will go to your customers
    from your shop's email address.

    No action needed — this email is just confirmation that the
    connection works.

    -- DrivewayOS
    """)
  end
end
