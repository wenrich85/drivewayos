defmodule DrivewayOS.Notifications.ReminderScheduler do
  @moduledoc """
  Hourly sweep that finds appointments scheduled in the next 23-25h
  window with no reminder yet, and dispatches a 24h-before-the-wash
  reminder email per appointment. Each row is marked
  `reminder_sent_at` after a successful send so we never double up.

  Started by the application supervisor in non-test envs. Tests
  drive the dispatch path directly via `dispatch_due_reminders/1`
  with a deterministic `now` argument so the time-window math is
  testable without time-warping.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.{BookingEmail, BookingSms}
  alias DrivewayOS.Plans
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  # Sweep cadence — once per hour. Production tolerance: emails go
  # out 23-25h before the appointment, so a 1-hour cadence guarantees
  # every appointment is hit by exactly one sweep.
  @sweep_interval_ms 60 * 60 * 1000

  # Boot delay so we don't sweep during application start.
  @boot_delay_ms 60 * 1000

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Synchronously runs one sweep — finds and sends every reminder
  whose appointment is in the [now+23h, now+25h] window. Returns
  the count of reminders sent. Used by tests + manual invocation
  from `iex -S mix`.
  """
  @spec dispatch_due_reminders(DateTime.t()) :: non_neg_integer()
  def dispatch_due_reminders(%DateTime{} = now \\ DateTime.utc_now()) do
    window_start = DateTime.add(now, 23 * 3600, :second)
    window_end = DateTime.add(now, 25 * 3600, :second)

    list_active_tenants()
    |> Enum.reduce(0, fn tenant, acc ->
      acc + dispatch_for_tenant(tenant, window_start, window_end)
    end)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @boot_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      count = dispatch_due_reminders(DateTime.utc_now())

      if count > 0 do
        Logger.info("[reminder_scheduler] sent #{count} reminders")
      end
    rescue
      e ->
        Logger.error(
          "[reminder_scheduler] sweep crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
        )
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  # --- Private helpers ---

  defp list_active_tenants do
    case Tenant
         |> Ash.Query.filter(status == :active or status == :pending_onboarding)
         |> Ash.read(authorize?: false) do
      {:ok, tenants} -> tenants
      _ -> []
    end
  end

  defp dispatch_for_tenant(tenant, window_start, window_end) do
    case Appointment
         |> Ash.Query.for_read(:due_for_reminder, %{
           window_start: window_start,
           window_end: window_end
         })
         |> Ash.Query.set_tenant(tenant.id)
         |> Ash.read(authorize?: false) do
      {:ok, []} ->
        0

      {:ok, appointments} ->
        Enum.count(appointments, &send_one_reminder(tenant, &1))

      _ ->
        0
    end
  end

  defp send_one_reminder(tenant, appt) do
    with {:ok, customer} <-
           Ash.get(DrivewayOS.Accounts.Customer, appt.customer_id,
             tenant: tenant.id,
             authorize?: false
           ),
         {:ok, service} <-
           Ash.get(ServiceType, appt.service_type_id, tenant: tenant.id, authorize?: false),
         _email <- send_email(tenant, customer, appt, service),
         {:ok, _} <-
           appt
           |> Ash.Changeset.for_update(:mark_reminder_sent, %{})
           |> Ash.update(authorize?: false, tenant: tenant.id) do
      true
    else
      _ ->
        Logger.warning(
          "[reminder_scheduler] couldn't process appt=#{appt.id} tenant=#{tenant.id}"
        )

        false
    end
  end

  defp send_email(tenant, customer, appt, service) do
    tenant
    |> BookingEmail.reminder(customer, appt, service)
    |> Mailer.deliver(Mailer.for_tenant(tenant))

    if Plans.tenant_can?(tenant, :sms_notifications) do
      BookingSms.reminder(tenant, customer, appt, service)
    end
  rescue
    _ -> :ok
  end
end
