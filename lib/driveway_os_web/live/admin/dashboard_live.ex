defmodule DrivewayOSWeb.Admin.DashboardLive do
  @moduledoc """
  Tenant-admin dashboard at `{slug}.lvh.me/admin`. Shows the
  operator a summary of their shop: pending bookings to confirm,
  customer count, today's schedule.

  V1 keeps it lean — three cards + a "pending appointments" list
  with confirm/cancel actions inline. V2 adds dispatch kanban,
  customer detail pages, marketing rollups, etc.

  Auth + authorization at mount: must be a Customer (loaded by
  LoadCustomerHook) AND `role == :admin`. Non-admins bounce to /
  (the customer-facing landing).
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.AppointmentBroadcaster
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Platform.CustomDomain
  alias DrivewayOS.Scheduling.{Appointment, BlockTemplate, ServiceType, Subscription}

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      true ->
        if connected?(socket) do
          AppointmentBroadcaster.subscribe(socket.assigns.current_tenant.id)
        end

        {:ok, load_dashboard(socket)}
    end
  end

  @impl true
  def handle_info({:appointment, _event, _payload}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  @impl true
  def handle_event("confirm_appointment", %{"id" => id}, socket),
    do: transition_appointment(socket, id, :confirm, %{})

  def handle_event("cancel_appointment", %{"id" => id}, socket),
    do: transition_appointment(socket, id, :cancel, %{cancellation_reason: "Cancelled by admin"})

  def handle_event("start_appointment", %{"id" => id}, socket),
    do: transition_appointment(socket, id, :start_wash, %{})

  def handle_event("complete_appointment", %{"id" => id}, socket),
    do: transition_appointment(socket, id, :complete, %{})

  defp transition_appointment(socket, id, action, args) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(Appointment, id, tenant: tenant_id, authorize?: false) do
      {:ok, appt} ->
        updated =
          appt
          |> Ash.Changeset.for_update(action, args)
          |> Ash.update!(authorize?: false, tenant: tenant_id)

        send_state_change_email(socket, action, updated)
        AppointmentBroadcaster.broadcast(tenant_id, broadcast_event(action), %{id: updated.id})

        {:noreply, load_dashboard(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp broadcast_event(:confirm), do: :confirmed
  defp broadcast_event(:cancel), do: :cancelled
  defp broadcast_event(:start_wash), do: :started
  defp broadcast_event(:complete), do: :completed
  defp broadcast_event(_), do: :payment_changed

  # Customer-side email on admin-initiated confirm / cancel.
  defp send_state_change_email(socket, action, %Appointment{} = appt)
       when action in [:confirm, :cancel] do
    tenant = socket.assigns.current_tenant

    with {:ok, booker} <-
           Ash.get(Customer, appt.customer_id, tenant: tenant.id, authorize?: false),
         {:ok, service} <-
           Ash.get(ServiceType, appt.service_type_id, tenant: tenant.id, authorize?: false) do
      email =
        case action do
          :confirm -> BookingEmail.confirmed(tenant, booker, appt, service)
          :cancel -> BookingEmail.cancelled(tenant, booker, appt, service)
        end

      Mailer.deliver(email)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp send_state_change_email(_, _, _), do: :ok

  # --- Private ---

  defp load_dashboard(socket) do
    tenant_id = socket.assigns.current_tenant.id

    appointments =
      Appointment
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read!(authorize?: false)

    customers =
      Customer
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read!(authorize?: false)

    service_ids = appointments |> Enum.map(& &1.service_type_id) |> Enum.uniq()

    service_map =
      if service_ids == [] do
        %{}
      else
        ServiceType
        |> Ash.Query.filter(id in ^service_ids)
        |> Ash.Query.set_tenant(tenant_id)
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.id, &1})
      end

    customer_map = Map.new(customers, &{&1.id, &1})

    pending = Enum.filter(appointments, &(&1.status == :pending))
    upcoming = Enum.filter(appointments, &(&1.status in [:pending, :confirmed]))
    today = today_appointments(appointments, socket.assigns.current_tenant.timezone)
    {revenue_week, revenue_month} = revenue_summary(appointments)
    channels = channel_summary(appointments)
    cancel_reasons = cancellation_reason_summary(appointments)

    {active_sub_count, mrr_cents} = subscription_summary(tenant_id)

    {:ok, blocks} =
      BlockTemplate |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false)

    {:ok, custom_domains} =
      CustomDomain
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, all_services} =
      ServiceType |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false)

    checklist =
      build_checklist(socket.assigns.current_tenant, blocks, custom_domains, all_services)

    socket
    |> assign(:page_title, "Admin · #{socket.assigns.current_tenant.display_name}")
    |> assign(:pending, Enum.sort_by(pending, & &1.scheduled_at, DateTime))
    |> assign(:pending_count, length(pending))
    |> assign(:upcoming_count, length(upcoming))
    |> assign(:customer_count, length(customers))
    |> assign(:service_map, service_map)
    |> assign(:customer_map, customer_map)
    |> assign(:checklist, checklist)
    |> assign(:today, today)
    |> assign(:revenue_week, revenue_week)
    |> assign(:revenue_month, revenue_month)
    |> assign(:channels, channels)
    |> assign(:cancel_reasons, cancel_reasons)
    |> assign(:active_sub_count, active_sub_count)
    |> assign(:mrr_cents, mrr_cents)
  end

  # Active subscriptions and rough monthly recurring revenue. The
  # frequency multipliers are calendar averages — weekly = 52/12,
  # biweekly = 26/12, monthly = 1 — applied to each sub's service
  # base price at lookup time so a price change is reflected without
  # a backfill. Refunded / cancelled appointments aren't subtracted
  # here; this is a forward-looking signal, not an accounting figure.
  defp subscription_summary(tenant_id) do
    {:ok, subs} =
      Subscription
      |> Ash.Query.filter(status == :active)
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read(authorize?: false)

    case subs do
      [] ->
        {0, 0}

      _ ->
        service_ids = subs |> Enum.map(& &1.service_type_id) |> Enum.uniq()

        prices =
          ServiceType
          |> Ash.Query.filter(id in ^service_ids)
          |> Ash.Query.set_tenant(tenant_id)
          |> Ash.read!(authorize?: false)
          |> Map.new(&{&1.id, &1.base_price_cents})

        cents =
          subs
          |> Enum.reduce(0, fn sub, acc ->
            base = Map.get(prices, sub.service_type_id, 0)
            acc + round(base * frequency_factor(sub.frequency))
          end)

        {length(subs), cents}
    end
  end

  defp frequency_factor(:weekly), do: 52 / 12
  defp frequency_factor(:biweekly), do: 26 / 12
  defp frequency_factor(:monthly), do: 1
  defp frequency_factor(_), do: 0

  # Last-30-days breakdown of cancelled appointments grouped by
  # parsed reason. Customer-side cancellations land as
  # "Customer: <label> — <details>" (J3 dropdown); admin-side
  # cancellations land as "Cancelled by admin". We strip the
  # `— details` suffix so the histogram groups by reason class
  # rather than fragmenting on freetext.
  defp cancellation_reason_summary(appointments) do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    appointments
    |> Enum.filter(fn a ->
      a.status == :cancelled and
        DateTime.compare(a.scheduled_at, cutoff) != :lt
    end)
    |> Enum.frequencies_by(&parse_cancel_reason/1)
    |> Enum.sort_by(fn {_, count} -> -count end)
  end

  defp parse_cancel_reason(%{cancellation_reason: nil}), do: "Unspecified"
  defp parse_cancel_reason(%{cancellation_reason: ""}), do: "Unspecified"

  defp parse_cancel_reason(%{cancellation_reason: text}) when is_binary(text) do
    cond do
      String.starts_with?(text, "Customer: ") ->
        text
        |> String.replace_prefix("Customer: ", "")
        |> String.split(" — ", parts: 2)
        |> List.first()

      String.starts_with?(text, "Cancelled by admin") ->
        "Admin-cancelled"

      String.starts_with?(text, "Cancelled by customer") ->
        "Customer (no reason)"

      true ->
        text
    end
  end

  defp parse_cancel_reason(_), do: "Unspecified"

  # Last-30-days breakdown of acquisition_channel counts. Rolls
  # nils into "Not asked" so the operator sees what fraction of
  # bookings are missing the question — useful signal that
  # something's off (e.g. wizard never reaching the schedule
  # step).
  defp channel_summary(appointments) do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    appointments
    |> Enum.filter(&(DateTime.compare(&1.scheduled_at, cutoff) != :lt))
    |> Enum.frequencies_by(fn a -> a.acquisition_channel || "Not asked" end)
    |> Enum.sort_by(fn {_, count} -> -count end)
  end

  # Sums price_cents across paid appointments scheduled in [start, now)
  # for two windows: trailing 7 days and trailing 30 days. Refunded
  # rows drop out (payment_status is the source of truth, not just
  # `paid_at`).
  defp revenue_summary(appointments) do
    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7 * 86_400, :second)
    month_ago = DateTime.add(now, -30 * 86_400, :second)

    paid = Enum.filter(appointments, &(&1.payment_status == :paid))

    week =
      paid
      |> Enum.filter(&(DateTime.compare(&1.scheduled_at, week_ago) != :lt))
      |> Enum.reduce(0, &(&1.price_cents + &2))

    month =
      paid
      |> Enum.filter(&(DateTime.compare(&1.scheduled_at, month_ago) != :lt))
      |> Enum.reduce(0, &(&1.price_cents + &2))

    {week, month}
  end

  # Returns the subset of appointments scheduled within today's
  # local-time window for the tenant's timezone, excluding cancelled
  # ones. Sorted by scheduled_at ascending — chronological as the
  # operator works through the day.
  defp today_appointments(appointments, tz) do
    {start_utc, end_utc} = local_day_bounds_utc(tz)

    appointments
    |> Enum.filter(fn a ->
      a.status != :cancelled and
        DateTime.compare(a.scheduled_at, start_utc) != :lt and
        DateTime.compare(a.scheduled_at, end_utc) == :lt
    end)
    |> Enum.sort_by(& &1.scheduled_at, DateTime)
  end

  defp local_day_bounds_utc(tz) do
    case DateTime.shift_zone(DateTime.utc_now(), tz) do
      {:ok, now_local} ->
        date = DateTime.to_date(now_local)
        {:ok, midnight_local} = NaiveDateTime.new(date, ~T[00:00:00]) |> from_naive_in(tz)
        next_local = DateTime.add(midnight_local, 86_400, :second)

        {DateTime.shift_zone!(midnight_local, "Etc/UTC"),
         DateTime.shift_zone!(next_local, "Etc/UTC")}

      _ ->
        # Tzdata not loaded or unknown zone — fall back to UTC. The
        # widget still works, just at UTC-day boundaries.
        now = DateTime.utc_now()
        date = DateTime.to_date(now)
        {:ok, start_utc} = NaiveDateTime.new(date, ~T[00:00:00]) |> from_naive_in("Etc/UTC")
        {start_utc, DateTime.add(start_utc, 86_400, :second)}
    end
  end

  defp from_naive_in({:ok, ndt}, tz), do: DateTime.from_naive(ndt, tz)
  defp from_naive_in(other, _), do: other

  # Returns a list of `{title, blurb, href}` for the open onboarding
  # items only — completed ones drop out, so when everything's done
  # the checklist is just `[]` and the card hides itself.
  defp build_checklist(tenant, blocks, custom_domains, services) do
    [
      is_nil(tenant.stripe_account_id) &&
        {"Connect Stripe", "Take payment for bookings.", "/onboarding/stripe/start"},
      using_default_services?(services) &&
        {"Customize your services",
         "Tweak the seeded Basic Wash + Deep Clean to match your real menu, or add new ones.",
         "/admin/services"},
      Enum.empty?(blocks) &&
        {"Define your availability",
         "Customers see concrete time slots once you've added at least one weekly block.",
         "/admin/schedule"},
      missing_branding?(tenant) &&
        {"Customize your branding",
         "Upload a logo, set your support email, pick a brand color.",
         "/admin/branding"},
      Enum.empty?(custom_domains) &&
        {"(Optional) Run on your own domain",
         "Point a hostname like book.yourshop.com at DrivewayOS.",
         "/admin/domains"}
    ]
    |> Enum.filter(& &1)
  end

  # Tenants ship with two seeded services (slugs "basic-wash" and
  # "deep-clean"). If those are still the literal set on the
  # account, the operator hasn't customized — surface the prompt.
  # Renaming, repricing, or adding a new ServiceType drops the
  # checklist item.
  defp using_default_services?(services) do
    slugs = services |> Enum.map(& &1.slug) |> Enum.sort()
    slugs == ["basic-wash", "deep-clean"]
  end

  # Onboarding-time defaults like "no logo" + "no support email"
  # mean the operator hasn't customized branding yet.
  defp missing_branding?(tenant) do
    is_nil(tenant.support_email) and is_nil(tenant.logo_url)
  end

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp fmt_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a %b %-d · %-I:%M %p")
  end

  defp fmt_local_time(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%-I:%M %p")
      _ -> Calendar.strftime(dt, "%-I:%M %p UTC")
    end
  end

  defp status_badge(:pending), do: "badge-warning"
  defp status_badge(:confirmed), do: "badge-info"
  defp status_badge(:in_progress), do: "badge-primary"
  defp status_badge(:completed), do: "badge-success"
  defp status_badge(_), do: "badge-ghost"

  defp service_name(map, id), do: get_in(map, [id, Access.key(:name)]) || "Service"

  defp customer_name(map, id), do: get_in(map, [id, Access.key(:name)]) || "Customer"

  defp customer_phone(map, id) do
    case get_in(map, [id, Access.key(:phone)]) do
      nil -> nil
      "" -> nil
      phone -> phone
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-6xl mx-auto space-y-6">
        <header class="flex justify-between items-start flex-wrap gap-3">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Admin</p>
            <h1 class="text-3xl font-bold tracking-tight">{@current_tenant.display_name}</h1>
            <p class="text-sm text-base-content/70 mt-1">
              Welcome back, {@current_customer.name}.
            </p>
          </div>
          <nav class="flex gap-1 flex-wrap" aria-label="Admin sections">
            <.nav_link href="/admin/appointments" icon="hero-calendar">Appointments</.nav_link>
            <.nav_link href="/admin/customers" icon="hero-user-group">Customers</.nav_link>
            <.nav_link href="/admin/services" icon="hero-rectangle-stack">Services</.nav_link>
            <.nav_link href="/admin/schedule" icon="hero-clock">Schedule</.nav_link>
            <.nav_link href="/admin/branding" icon="hero-paint-brush">Branding</.nav_link>
            <.nav_link href="/admin/domains" icon="hero-globe-alt">Domains</.nav_link>
            <.nav_link href="/admin/activity" icon="hero-clipboard-document-list">Activity</.nav_link>
            <a
              href="/"
              target="_blank"
              rel="noopener"
              class="btn btn-ghost btn-sm gap-1"
              title="Preview your customer-facing site in a new tab"
            >
              <span class="hero-arrow-top-right-on-square w-4 h-4" aria-hidden="true"></span>
              View shop
            </a>
            <a href="/auth/customer/sign-out" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-arrow-left-on-rectangle w-4 h-4" aria-hidden="true"></span>
              Sign out
            </a>
          </nav>
        </header>

        <section
          :if={@checklist != []}
          class="card bg-warning/10 border border-warning/30 shadow-sm"
        >
          <div class="card-body p-6">
            <div class="flex items-start gap-3">
              <span class="hero-rocket-launch w-6 h-6 text-warning shrink-0 mt-0.5" aria-hidden="true"></span>
              <div>
                <h2 class="card-title text-lg">Get set up</h2>
                <p class="text-sm text-base-content/70">
                  A few things to take care of before you're ready for real customers.
                </p>
              </div>
            </div>

            <ul class="space-y-3 mt-3">
              <li
                :for={{title, blurb, href} <- @checklist}
                class="flex gap-3 items-start bg-base-100 border border-base-300 rounded-lg p-4"
              >
                <span class="hero-arrow-right-circle w-5 h-5 text-warning shrink-0 mt-0.5" aria-hidden="true"></span>
                <div class="flex-1">
                  <div class="font-semibold">{title}</div>
                  <div class="text-sm text-base-content/70">{blurb}</div>
                </div>
                <a href={href} class="btn btn-primary btn-sm">Do it</a>
              </li>
            </ul>
          </div>
        </section>

        <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Pending
            </div>
            <div class="stat-value text-2xl font-bold text-warning">{@pending_count}</div>
            <div class="stat-desc text-xs text-base-content/60">Awaiting confirm</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Upcoming
            </div>
            <div class="stat-value text-2xl font-bold text-info">{@upcoming_count}</div>
            <div class="stat-desc text-xs text-base-content/60">Pending + confirmed</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Customers
            </div>
            <div class="stat-value text-2xl font-bold">{@customer_count}</div>
            <div class="stat-desc text-xs text-base-content/60">All time</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              This week
            </div>
            <div class="stat-value text-2xl font-bold text-success">
              {fmt_price(@revenue_week)}
            </div>
            <div class="stat-desc text-xs text-base-content/60">Paid bookings</div>
          </article>
          <article class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              This month
            </div>
            <div class="stat-value text-2xl font-bold text-success">
              {fmt_price(@revenue_month)}
            </div>
            <div class="stat-desc text-xs text-base-content/60">Trailing 30 days</div>
          </article>
          <article
            :if={@active_sub_count > 0}
            class="stat bg-base-100 rounded-xl shadow-sm border border-base-300"
          >
            <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
              Subscriptions
            </div>
            <div class="stat-value text-2xl font-bold text-primary">{@active_sub_count}</div>
            <div class="stat-desc text-xs text-base-content/60">
              ~{fmt_price(@mrr_cents)}/mo Recurring
            </div>
          </article>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h2 class="card-title text-lg">Today</h2>
              <div class="flex items-center gap-3">
                <span class="text-xs text-base-content/60">
                  {length(@today)} {if length(@today) == 1, do: "appointment", else: "appointments"}
                </span>
                <a
                  :if={@today != []}
                  href="/admin/today/print"
                  class="btn btn-ghost btn-xs gap-1"
                >
                  <span class="hero-printer w-3 h-3" aria-hidden="true"></span> Print
                </a>
              </div>
            </div>

            <div :if={@today == []} class="text-center py-8 px-4">
              <span class="hero-sun w-10 h-10 mx-auto text-base-content/30" aria-hidden="true"></span>
              <h3 class="mt-3 font-semibold">Nothing on today</h3>
              <p class="mt-1 text-sm text-base-content/60">
                No bookings scheduled for {Calendar.strftime(Date.utc_today(), "%a %b %-d")}.
              </p>
            </div>

            <ul :if={@today != []} class="divide-y divide-base-200 mt-2">
              <li
                :for={a <- @today}
                class="py-4 flex items-start justify-between gap-3 flex-wrap"
              >
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="font-mono text-sm tabular-nums">
                      {fmt_local_time(a.scheduled_at, @current_tenant.timezone)}
                    </span>
                    <.link navigate={~p"/appointments/#{a.id}"} class="font-semibold link link-hover">
                      {service_name(@service_map, a.service_type_id)}
                    </.link>
                    <span class={"badge badge-sm " <> status_badge(a.status)}>{a.status}</span>
                  </div>
                  <div class="text-sm text-base-content/70 mt-1 flex items-center gap-1 flex-wrap">
                    <span class="hero-user w-4 h-4" aria-hidden="true"></span>
                    {customer_name(@customer_map, a.customer_id)}
                    <% phone = customer_phone(@customer_map, a.customer_id) %>
                    <a
                      :if={phone}
                      href={"tel:" <> phone}
                      class="link link-hover font-mono text-xs text-base-content/60 ml-1 inline-flex items-center gap-0.5"
                      title={"Call " <> phone}
                    >
                      <span class="hero-phone w-3 h-3" aria-hidden="true"></span>
                      {phone}
                    </a>
                    <span class="text-base-content/40 mx-1">·</span>
                    {a.vehicle_description}
                  </div>
                  <div class="text-xs text-base-content/60 truncate mt-1 flex items-center gap-1">
                    <span class="hero-map-pin w-3 h-3 shrink-0" aria-hidden="true"></span>
                    {a.service_address}
                  </div>
                </div>

                <div class="flex items-center gap-2">
                  <button
                    :if={a.status == :pending}
                    phx-click="confirm_appointment"
                    phx-value-id={a.id}
                    class="btn btn-success btn-sm gap-1"
                  >
                    <span class="hero-check w-4 h-4" aria-hidden="true"></span> Confirm
                  </button>
                  <button
                    :if={a.status == :confirmed}
                    phx-click="start_appointment"
                    phx-value-id={a.id}
                    class="btn btn-primary btn-sm gap-1"
                  >
                    <span class="hero-play w-4 h-4" aria-hidden="true"></span> Start
                  </button>
                  <button
                    :if={a.status == :in_progress}
                    phx-click="complete_appointment"
                    phx-value-id={a.id}
                    class="btn btn-success btn-sm gap-1"
                  >
                    <span class="hero-check-circle w-4 h-4" aria-hidden="true"></span> Complete
                  </button>
                  <span
                    :if={a.status == :completed}
                    class="text-sm text-success font-medium"
                  >
                    Done
                  </span>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <section
            :if={@channels != []}
            class="card bg-base-100 shadow-sm border border-base-300"
          >
            <div class="card-body p-6">
              <h2 class="card-title text-lg">How customers found you</h2>
              <p class="text-sm text-base-content/60 mb-3">Last 30 days</p>

              <ul class="space-y-2">
                <li
                  :for={{channel, count} <- @channels}
                  class="flex items-center justify-between text-sm"
                >
                  <span class="text-base-content/80">{channel}</span>
                  <span class="font-semibold tabular-nums">{count}</span>
                </li>
              </ul>
            </div>
          </section>

          <section
            :if={@cancel_reasons != []}
            class="card bg-base-100 shadow-sm border border-base-300"
          >
            <div class="card-body p-6">
              <h2 class="card-title text-lg">Why customers cancel</h2>
              <p class="text-sm text-base-content/60 mb-3">Last 30 days</p>

              <ul class="space-y-2">
                <li
                  :for={{reason, count} <- @cancel_reasons}
                  class="flex items-center justify-between text-sm"
                >
                  <span class="text-base-content/80">{reason}</span>
                  <span class="font-semibold tabular-nums">{count}</span>
                </li>
              </ul>
            </div>
          </section>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h2 class="card-title text-lg">Pending appointments</h2>
              <a
                :if={@pending != []}
                href="/admin/appointments"
                class="btn btn-ghost btn-sm gap-1"
              >
                View all
                <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
              </a>
            </div>

            <div :if={@pending == []} class="text-center py-12 px-4">
              <span class="hero-inbox w-12 h-12 mx-auto text-base-content/30" aria-hidden="true"></span>
              <h3 class="mt-4 text-lg font-semibold">All caught up</h3>
              <p class="mt-1 text-sm text-base-content/60 max-w-sm mx-auto">
                Nothing pending right now. New bookings show up here automatically.
              </p>
            </div>

            <ul :if={@pending != []} class="divide-y divide-base-200 mt-2">
              <li
                :for={a <- @pending}
                class="py-4 flex items-start justify-between gap-3 flex-wrap"
              >
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <.link
                      navigate={~p"/appointments/#{a.id}"}
                      class="font-semibold link link-hover"
                    >
                      {service_name(@service_map, a.service_type_id)}
                    </.link>
                    <span class="text-base-content/40">·</span>
                    <span class="text-sm text-base-content/70">
                      {customer_name(@customer_map, a.customer_id)}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70 mt-1 flex items-center gap-1">
                    <span class="hero-clock w-4 h-4" aria-hidden="true"></span>
                    {fmt_when(a.scheduled_at)}
                    <span class="text-base-content/40 mx-1">·</span>
                    {a.vehicle_description}
                  </div>
                  <div class="text-xs text-base-content/60 truncate mt-1 flex items-center gap-1">
                    <span class="hero-map-pin w-3 h-3 shrink-0" aria-hidden="true"></span>
                    {a.service_address}
                  </div>
                </div>

                <div class="flex items-center gap-2">
                  <span class="font-semibold">{fmt_price(a.price_cents)}</span>
                  <button
                    phx-click="confirm_appointment"
                    phx-value-id={a.id}
                    class="btn btn-success btn-sm gap-1"
                  >
                    <span class="hero-check w-4 h-4" aria-hidden="true"></span> Confirm
                  </button>
                  <button
                    phx-click="cancel_appointment"
                    phx-value-id={a.id}
                    data-confirm="Cancel this appointment?"
                    class="btn btn-ghost btn-sm text-error"
                    aria-label="Cancel"
                  >
                    <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span>
                  </button>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <a href={@href} class="btn btn-ghost btn-sm gap-1">
      <span class={"#{@icon} w-4 h-4"} aria-hidden="true"></span>
      {render_slot(@inner_block)}
    </a>
    """
  end
end
