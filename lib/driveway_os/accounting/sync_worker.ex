defmodule DrivewayOS.Accounting.SyncWorker do
  @moduledoc """
  Oban worker that syncs a paid Appointment to the tenant's accounting
  system. Enqueued from the Ash `:mark_paid` change on Appointment
  (Task 10).

  Pre-flight checks (in order):
    1. Active connection exists for (tenant, :zoho_books)?
       If not — `:ok`, nothing to do (most tenants).
    2. Connection's access_token still valid? If expired, refresh.
       If refresh fails with auth, auto-pause + email + `:ok`.
    3. Hand off to `Accounting.sync_payment/5`. On `{:error, :auth_failed}`,
       same auto-pause path. On other errors, return `{:error, reason}`
       so Oban retries up to `max_attempts`.

  Never blocks tenant flows (the `:mark_paid` change wraps the
  Oban.insert in try/rescue per Task 10 — failure to enqueue logs but
  doesn't fail the payment).
  """
  use Oban.Worker, queue: :billing, max_attempts: 5

  alias DrivewayOS.Accounting
  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Mailer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tid, "appointment_id" => aid}}) do
    with {:ok, connection} <- Platform.get_active_accounting_connection(tid, :zoho_books),
         {:ok, tenant} <- Ash.get(DrivewayOS.Platform.Tenant, tid, authorize?: false),
         {:ok, appt} <- Ash.get(Appointment, aid, tenant: tid, authorize?: false),
         {:ok, customer} <- Ash.get(Customer, appt.customer_id, tenant: tid, authorize?: false),
         {:ok, connection} <- ensure_token_fresh(connection),
         service_name = resolve_service_name(appt, tid),
         :ok <- Accounting.sync_payment(connection, tenant, appt, customer, service_name) do
      record_sync_success(connection)
      :ok
    else
      {:error, :no_active_connection} ->
        Logger.info("Accounting sync skipped: no active connection for tenant=#{tid}")
        :ok

      {:error, :auth_failed} ->
        handle_auth_failure(tid)
        :ok

      {:error, reason} ->
        record_sync_error(tid, reason)
        {:error, reason}
    end
  end

  defp ensure_token_fresh(%AccountingConnection{access_token_expires_at: exp} = conn) do
    if not is_nil(exp) and DateTime.compare(exp, DateTime.utc_now()) == :gt do
      {:ok, conn}
    else
      case ZohoClient.impl().refresh_access_token(conn.refresh_token) do
        {:ok, %{access_token: at, expires_in: secs}} ->
          conn
          |> Ash.Changeset.for_update(:refresh_tokens, %{
            access_token: at,
            refresh_token: conn.refresh_token,
            access_token_expires_at: DateTime.add(DateTime.utc_now(), secs, :second)
          })
          |> Ash.update(authorize?: false)

        {:error, :auth_failed} = err ->
          err

        err ->
          err
      end
    end
  end

  defp handle_auth_failure(tenant_id) do
    case Platform.get_accounting_connection(tenant_id, :zoho_books) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:pause, %{})
        |> Ash.update!(authorize?: false)

        conn
        |> Ash.Changeset.for_update(:record_sync_error, %{
          last_sync_error: "auth_failed; reconnect at /admin/integrations"
        })
        |> Ash.update!(authorize?: false)

        send_reconnect_email(tenant_id)

      _ ->
        :ok
    end
  end

  defp record_sync_success(conn) do
    conn
    |> Ash.Changeset.for_update(:record_sync_success, %{})
    |> Ash.update!(authorize?: false)
  end

  defp record_sync_error(tenant_id, reason) do
    case Platform.get_accounting_connection(tenant_id, :zoho_books) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:record_sync_error, %{
          last_sync_error: truncate(inspect(reason), 500)
        })
        |> Ash.update!(authorize?: false)

      _ ->
        :ok
    end
  end

  defp truncate(s, max) when is_binary(s) do
    if byte_size(s) > max, do: binary_part(s, 0, max) <> "…", else: s
  end

  defp send_reconnect_email(tenant_id) do
    with {:ok, tenant} <- Ash.get(DrivewayOS.Platform.Tenant, tenant_id, authorize?: false),
         [admin | _] <- DrivewayOS.Accounts.tenant_admins(tenant_id) do
      email = reconnect_email(tenant, admin)
      Mailer.deliver(email, Mailer.for_tenant(tenant))
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reconnect_email(tenant, admin) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({admin.name, to_string(admin.email)})
    |> Swoosh.Email.from(DrivewayOS.Branding.from_address(tenant))
    |> Swoosh.Email.subject("Action needed: reconnect Zoho Books")
    |> Swoosh.Email.text_body("""
    Hi #{admin.name},

    Your Zoho Books connection for #{tenant.display_name} stopped
    working — likely an expired token or revoked authorization. To
    resume syncing payments to your books, please reconnect:

    /admin/integrations

    No payments are missed in DrivewayOS — only the auto-sync to
    Zoho is paused.

    -- DrivewayOS
    """)
  end

  defp resolve_service_name(appt, tenant_id) do
    case Ash.get(ServiceType, appt.service_type_id, tenant: tenant_id, authorize?: false) do
      {:ok, svc} -> svc.name
      _ -> "Detailing Service"
    end
  end
end
