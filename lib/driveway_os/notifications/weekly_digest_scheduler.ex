defmodule DrivewayOS.Notifications.WeeklyDigestScheduler do
  @moduledoc """
  Hourly sweep that emails each tenant's admins a Monday-morning
  recap. We fire when:

    * Tenant.last_digest_sent_at is nil OR more than 6 days ago
    * AND it's Monday in the tenant's local timezone
    * AND the tenant-local hour is 7-9am (gives a 3-hour window
      so a brief outage doesn't skip the week)

  After dispatch, `:mark_digest_sent` stamps the tenant so the
  same week can't double-send even if the sweeper restarts.

  Tests drive `dispatch_due/1` directly with a deterministic
  `now`; the GenServer itself is not started in test
  (config/test.exs sets `:start_schedulers?` false).
  """
  use GenServer

  require Ash.Query
  require Logger

  alias DrivewayOS.Accounts
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.Appointment

  @sweep_interval_ms 60 * 60 * 1000
  @boot_delay_ms 120 * 1000

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run one sweep synchronously. Returns the count of digests sent.
  Used in tests to drive the dispatch path with a known clock.
  """
  @spec dispatch_due(DateTime.t()) :: non_neg_integer()
  def dispatch_due(%DateTime{} = now \\ DateTime.utc_now()) do
    list_active_tenants()
    |> Enum.count(fn tenant ->
      due_for?(tenant, now) and dispatch_for_tenant(tenant, now)
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
        Logger.info("[weekly_digest] sent #{count} digests")
      end
    rescue
      e ->
        Logger.error(
          "[weekly_digest] sweep crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
        )
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  # --- Time-window logic ---

  defp due_for?(tenant, now) do
    monday_morning?(tenant.timezone, now) and not recently_sent?(tenant, now)
  end

  defp monday_morning?(tz, now) do
    case DateTime.shift_zone(now, tz) do
      {:ok, local} ->
        Date.day_of_week(DateTime.to_date(local), :monday) == 1 and local.hour in 7..9

      _ ->
        # Fallback to UTC if Tzdata isn't loaded — same logic, just
        # in UTC. Better than silently never firing.
        Date.day_of_week(DateTime.to_date(now), :monday) == 1 and now.hour in 7..9
    end
  end

  defp recently_sent?(%Tenant{last_digest_sent_at: nil}, _now), do: false

  defp recently_sent?(%Tenant{last_digest_sent_at: stamped}, now) do
    DateTime.diff(now, stamped, :second) < 6 * 86_400
  end

  # --- Per-tenant dispatch ---

  defp list_active_tenants do
    case Tenant
         |> Ash.Query.filter(status == :active or status == :pending_onboarding)
         |> Ash.read(authorize?: false) do
      {:ok, tenants} -> tenants
      _ -> []
    end
  end

  defp dispatch_for_tenant(tenant, now) do
    admins = Accounts.tenant_admins(tenant.id)

    if admins == [] do
      false
    else
      stats = collect_stats(tenant, now)

      Enum.each(admins, fn admin ->
        tenant
        |> BookingEmail.weekly_digest(admin, stats)
        |> Mailer.deliver(Mailer.for_tenant(tenant))
      end)

      tenant
      |> Ash.Changeset.for_update(:mark_digest_sent, %{at: now})
      |> Ash.update!(authorize?: false)

      true
    end
  rescue
    e ->
      Logger.warning("[weekly_digest] dispatch failed for tenant=#{tenant.id}: #{inspect(e)}")
      false
  end

  defp collect_stats(tenant, now) do
    week_ago = DateTime.add(now, -7 * 86_400, :second)

    {:ok, appointments} =
      Appointment
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

    bookings_this_week =
      Enum.count(appointments, fn a ->
        DateTime.compare(a.inserted_at, week_ago) == :gt
      end)

    pending_now = Enum.count(appointments, &(&1.status == :pending))

    cancellations_week =
      Enum.count(appointments, fn a ->
        a.status == :cancelled and DateTime.compare(a.updated_at, week_ago) == :gt
      end)

    revenue_week_cents =
      appointments
      |> Enum.filter(fn a ->
        a.payment_status == :paid and
          DateTime.compare(a.scheduled_at, week_ago) == :gt
      end)
      |> Enum.reduce(0, &(&1.price_cents + &2))

    today_count = today_count_for(tenant.timezone, appointments, now)

    top_channel =
      appointments
      |> Enum.filter(fn a ->
        a.acquisition_channel not in [nil, ""] and
          DateTime.compare(a.inserted_at, week_ago) == :gt
      end)
      |> Enum.frequencies_by(& &1.acquisition_channel)
      |> Enum.max_by(fn {_, c} -> c end, fn -> {nil, 0} end)
      |> elem(0)

    %{
      bookings_this_week: bookings_this_week,
      pending_now: pending_now,
      revenue_week_cents: revenue_week_cents,
      cancellations_week: cancellations_week,
      today_count: today_count,
      top_channel: top_channel
    }
  end

  defp today_count_for(tz, appointments, now) do
    case DateTime.shift_zone(now, tz) do
      {:ok, local} ->
        date = DateTime.to_date(local)
        {:ok, midnight} = NaiveDateTime.new(date, ~T[00:00:00])
        {:ok, start_local} = DateTime.from_naive(midnight, tz)
        end_local = DateTime.add(start_local, 86_400, :second)
        start_utc = DateTime.shift_zone!(start_local, "Etc/UTC")
        end_utc = DateTime.shift_zone!(end_local, "Etc/UTC")

        Enum.count(appointments, fn a ->
          a.status != :cancelled and
            DateTime.compare(a.scheduled_at, start_utc) != :lt and
            DateTime.compare(a.scheduled_at, end_utc) == :lt
        end)

      _ ->
        0
    end
  end
end
