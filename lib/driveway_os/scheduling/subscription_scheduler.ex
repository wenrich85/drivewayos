defmodule DrivewayOS.Scheduling.SubscriptionScheduler do
  @moduledoc """
  Hourly sweep that materializes due Subscriptions into concrete
  Appointments. For every active subscription whose next_run_at
  falls in the [now, now + lookahead] window, we:

    1. Create an Appointment with the subscription's snapshot
       fields.
    2. Call `:advance_next_run` to push next_run_at forward by
       the frequency interval and stamp last_run_at.

  Step 2 is what prevents double-runs: once a subscription is
  advanced, the same row will not re-enter the :due window until
  next cycle.

  Lookahead window is 3 days so the customer's confirmation +
  reminder emails go out with comfortable buffer (the 24h reminder
  worker handles the day-before email).
  """
  use GenServer

  require Ash.Query
  require Logger

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType, Subscription}

  @sweep_interval_ms 60 * 60 * 1000
  @boot_delay_ms 90 * 1000
  @lookahead_days 3

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run one sweep synchronously. Returns the count of Appointments
  created. Drives both the GenServer and the test path with a
  deterministic `now`.
  """
  @spec dispatch_due(DateTime.t()) :: non_neg_integer()
  def dispatch_due(%DateTime{} = now \\ DateTime.utc_now()) do
    window_end = DateTime.add(now, @lookahead_days * 86_400, :second)

    list_active_tenants()
    |> Enum.reduce(0, fn tenant, acc ->
      acc + dispatch_for_tenant(tenant, now, window_end)
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
      count = dispatch_due(DateTime.utc_now())

      if count > 0 do
        Logger.info("[subscription_scheduler] materialized #{count} appointments")
      end
    rescue
      e ->
        Logger.error(
          "[subscription_scheduler] sweep crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
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
    case Subscription
         |> Ash.Query.for_read(:due, %{
           window_start: window_start,
           window_end: window_end
         })
         |> Ash.Query.set_tenant(tenant.id)
         |> Ash.read(authorize?: false) do
      {:ok, []} ->
        0

      {:ok, subs} ->
        Enum.count(subs, &materialize_one(tenant, &1))

      _ ->
        0
    end
  end

  defp materialize_one(tenant, sub) do
    with {:ok, service} <-
           Ash.get(ServiceType, sub.service_type_id, tenant: tenant.id, authorize?: false),
         {:ok, appt} <-
           Appointment
           |> Ash.Changeset.for_create(
             :book,
             %{
               customer_id: sub.customer_id,
               service_type_id: sub.service_type_id,
               scheduled_at: sub.next_run_at,
               duration_minutes: service.duration_minutes,
               price_cents: service.base_price_cents,
               vehicle_id: sub.vehicle_id,
               vehicle_description: sub.vehicle_description,
               address_id: sub.address_id,
               service_address: sub.service_address,
               notes: subscription_note(sub.notes)
             },
             tenant: tenant.id
           )
           |> Ash.create(authorize?: false),
         {:ok, _advanced} <-
           sub
           |> Ash.Changeset.for_update(:advance_next_run, %{ran_at: DateTime.utc_now()})
           |> Ash.update(authorize?: false, tenant: tenant.id) do
      notify_customer_of_auto_booking(tenant, sub, appt, service)
      true
    else
      err ->
        Logger.warning(
          "[subscription_scheduler] couldn't materialize sub=#{sub.id} tenant=#{tenant.id}: #{inspect(err)}"
        )

        false
    end
  end

  # Best-effort customer email — a mailer hiccup must not roll back
  # the appointment we just created or undo the scheduler's
  # next_run_at advance.
  defp notify_customer_of_auto_booking(tenant, sub, appt, service) do
    with {:ok, customer} <-
           Ash.get(Customer, sub.customer_id, tenant: tenant.id, authorize?: false) do
      tenant
      |> BookingEmail.subscription_appointment_created(customer, appt, service)
      |> Mailer.deliver()
    end

    :ok
  rescue
    _ -> :ok
  end

  defp subscription_note(nil), do: "Created from subscription."
  defp subscription_note(""), do: "Created from subscription."
  defp subscription_note(notes), do: "Created from subscription. #{notes}"
end
