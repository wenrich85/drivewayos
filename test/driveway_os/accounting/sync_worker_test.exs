defmodule DrivewayOS.Accounting.SyncWorkerTest do
  @moduledoc """
  Pre-flight checks dominate the worker's surface. The actual
  Accounting.sync_payment call is exercised by zoho_books_test +
  the facade test (Task 3 doesn't add one — facade is thin
  delegation), so this suite focuses on the worker's gating logic.
  """
  use DrivewayOS.DataCase, async: false
  use Oban.Testing, repo: DrivewayOS.Repo

  import Mox
  import Swoosh.TestAssertions

  alias DrivewayOS.Accounting.{SyncWorker, ZohoClient}
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection
  alias DrivewayOS.Scheduling.Appointment

  require Ash.Query

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sw-#{System.unique_integer([:positive])}",
        display_name: "Sync Worker Test",
        admin_email: "sw-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "skips sync when tenant has no AccountingConnection (returns :ok)", ctx do
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    # No Mox expectations — the worker shouldn't call ZohoClient.
    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })
  end

  test "skips sync when AccountingConnection is paused", ctx do
    connect_zoho!(ctx.tenant.id)
    pause_zoho!(ctx.tenant.id)
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })
  end

  test "skips sync when AccountingConnection is disconnected", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    conn
    |> Ash.Changeset.for_update(:disconnect, %{})
    |> Ash.update!(authorize?: false)

    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })
  end

  test "happy path: pushes contact + invoice + payment, records last_sync_at", ctx do
    conn = connect_zoho!(ctx.tenant.id)
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    expect(ZohoClient.Mock, :api_get, fn _, _, "/contacts", _ ->
      {:ok, %{"contacts" => []}}
    end)

    expect(ZohoClient.Mock, :api_post, fn _, _, "/contacts", _ ->
      {:ok, %{"contact" => %{"contact_id" => "c-1"}}}
    end)

    expect(ZohoClient.Mock, :api_post, fn _, _, "/invoices", _ ->
      {:ok, %{"invoice" => %{"invoice_id" => "inv-1"}}}
    end)

    expect(ZohoClient.Mock, :api_post, fn _, _, "/invoices/inv-1/payments", _ ->
      {:ok, %{"payment" => %{"payment_id" => "pay-1"}}}
    end)

    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })

    {:ok, refreshed} =
      Ash.get(AccountingConnection, conn.id, authorize?: false)

    assert %DateTime{} = refreshed.last_sync_at
    assert refreshed.last_sync_error == nil
  end

  test "auth failure (401) auto-pauses + emails", ctx do
    _conn = connect_zoho!(ctx.tenant.id)
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    # First HTTP call returns auth_failed.
    expect(ZohoClient.Mock, :api_get, fn _, _, _, _ -> {:error, :auth_failed} end)

    # Worker returns :ok (no Oban retries; we auto-paused).
    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })

    {:ok, refreshed} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    refute refreshed.auto_sync_enabled
    assert refreshed.last_sync_error =~ "auth_failed"

    # Email captured by the Test adapter.
    assert_email_sent(fn email -> assert email.subject =~ "reconnect" end)
  end

  defp connect_zoho!(tenant_id) do
    AccountingConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :zoho_books,
      external_org_id: "org-99",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    })
    |> Ash.create!(authorize?: false)
  end

  defp pause_zoho!(tenant_id) do
    {:ok, conn} = Platform.get_accounting_connection(tenant_id, :zoho_books)
    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)
  end

  # Mirrors the Appointment-creation pattern from
  # test/driveway_os_web/controllers/stripe_webhook_controller_test.exs:
  # look up a seeded ServiceType + the admin Customer, book an appt
  # with a future scheduled_at, then mark_paid so payment_status: :paid
  # and paid_at populate.
  defp create_paid_appointment!(tenant_id, _admin_id) do
    {:ok, [service | _]} =
      DrivewayOS.Scheduling.ServiceType
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, [customer | _]} =
      DrivewayOS.Accounts.Customer
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, appt} =
      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: customer.id,
          service_type_id: service.id,
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: service.duration_minutes,
          price_cents: service.base_price_cents,
          vehicle_description: "Sync Test Vehicle",
          service_address: "1 Sync Lane"
        },
        tenant: tenant_id
      )
      |> Ash.create(authorize?: false)

    pi_id = "pi_sync_#{System.unique_integer([:positive])}"

    appt
    |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: pi_id})
    |> Ash.update!(authorize?: false, tenant: tenant_id)
  end
end
