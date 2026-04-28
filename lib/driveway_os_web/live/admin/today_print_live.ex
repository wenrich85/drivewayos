defmodule DrivewayOSWeb.Admin.TodayPrintLive do
  @moduledoc """
  Printable single-page route sheet for today at
  `{slug}.lvh.me/admin/today/print`. Lists every confirmed /
  in-progress appointment in tenant-local time order with
  customer name, phone, vehicle, address, notes.

  Stripped chrome (no nav, no action buttons), `print:` Tailwind
  classes for paper-friendly typography. Operators print this
  before they head out for the day.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

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
        {:ok,
         socket
         |> assign(:page_title, "Today — print")
         |> load_today()}
    end
  end

  defp load_today(socket) do
    tenant = socket.assigns.current_tenant
    tenant_id = tenant.id

    appointments =
      Appointment
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read!(authorize?: false)

    {start_utc, end_utc} = local_day_bounds_utc(tenant.timezone)

    today =
      appointments
      |> Enum.filter(fn a ->
        a.status in [:confirmed, :in_progress, :pending] and
          DateTime.compare(a.scheduled_at, start_utc) != :lt and
          DateTime.compare(a.scheduled_at, end_utc) == :lt
      end)
      |> Enum.sort_by(& &1.scheduled_at, DateTime)

    customer_ids = today |> Enum.map(& &1.customer_id) |> Enum.uniq()
    service_ids = today |> Enum.map(& &1.service_type_id) |> Enum.uniq()

    customer_map =
      if customer_ids == [] do
        %{}
      else
        Customer
        |> Ash.Query.filter(id in ^customer_ids)
        |> Ash.Query.set_tenant(tenant_id)
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.id, &1})
      end

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

    socket
    |> assign(:today, today)
    |> assign(:customer_map, customer_map)
    |> assign(:service_map, service_map)
    |> assign(:print_date, Date.utc_today())
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
        now = DateTime.utc_now()
        date = DateTime.to_date(now)
        {:ok, start_utc} = NaiveDateTime.new(date, ~T[00:00:00]) |> from_naive_in("Etc/UTC")
        {start_utc, DateTime.add(start_utc, 86_400, :second)}
    end
  end

  defp from_naive_in({:ok, ndt}, tz), do: DateTime.from_naive(ndt, tz)
  defp from_naive_in(other, _), do: other

  defp fmt_local_time(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%-I:%M %p")
      _ -> Calendar.strftime(dt, "%-I:%M %p UTC")
    end
  end

  defp service_name(map, id), do: get_in(map, [id, Access.key(:name)]) || "Service"

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-100 px-6 py-8 max-w-3xl mx-auto print:p-0 print:max-w-none">
      <header class="flex items-baseline justify-between gap-4 mb-6 print:mb-3">
        <div>
          <h1 class="text-2xl font-bold tracking-tight">
            {@current_tenant.display_name} — today's route
          </h1>
          <p class="text-sm text-base-content/60 mt-1">
            {Calendar.strftime(@print_date, "%A, %B %-d, %Y")}
            · {length(@today)} {if length(@today) == 1, do: "appointment", else: "appointments"}
          </p>
        </div>
        <div class="flex gap-2 print:hidden">
          <a href="/admin" class="btn btn-ghost btn-sm">Back</a>
          <button onclick="window.print()" class="btn btn-primary btn-sm gap-1">
            <span class="hero-printer w-4 h-4" aria-hidden="true"></span> Print
          </button>
        </div>
      </header>

      <div :if={@today == []} class="text-center py-10 text-base-content/60">
        Nothing scheduled today.
      </div>

      <ol :if={@today != []} class="space-y-4">
        <li
          :for={a <- @today}
          class="border border-base-300 rounded-lg p-4 print:border-0 print:border-b print:rounded-none print:py-3 break-inside-avoid"
        >
          <div class="flex items-baseline justify-between gap-3 mb-2">
            <div class="font-mono text-lg tabular-nums font-bold">
              {fmt_local_time(a.scheduled_at, @current_tenant.timezone)}
            </div>
            <div class="text-sm text-base-content/60 uppercase tracking-wide">
              {a.status} · {a.duration_minutes} min
            </div>
          </div>

          <dl class="grid grid-cols-4 gap-x-3 gap-y-1 text-sm">
            <dt class="text-base-content/60">Service</dt>
            <dd class="col-span-3 font-semibold">
              {service_name(@service_map, a.service_type_id)}
            </dd>

            <dt class="text-base-content/60">Customer</dt>
            <dd class="col-span-3">
              {(@customer_map[a.customer_id] || %{name: "—"}).name}
              <% phone = (@customer_map[a.customer_id] || %{phone: nil}).phone %>
              <a
                :if={phone}
                href={"tel:" <> phone}
                class="ml-2 font-mono link link-hover"
              >
                {phone}
              </a>
            </dd>

            <dt class="text-base-content/60">
              {if a.additional_vehicles != [], do: "Vehicles", else: "Vehicle"}
            </dt>
            <dd class="col-span-3">
              <div>{a.vehicle_description}</div>
              <div :for={v <- a.additional_vehicles} class="text-base-content/80">
                + {v["description"]}
              </div>
            </dd>

            <dt class="text-base-content/60">Address</dt>
            <dd class="col-span-3 font-medium">{a.service_address}</dd>

            <%= if a.acquisition_channel && a.acquisition_channel != "" do %>
              <dt class="text-base-content/60">Source</dt>
              <dd class="col-span-3">{a.acquisition_channel}</dd>
            <% end %>

            <% pinned = (@customer_map[a.customer_id] || %{admin_notes: nil}).admin_notes %>
            <%= if pinned && pinned != "" do %>
              <dt class="text-base-content/60">Pinned</dt>
              <dd class="col-span-3 font-semibold">{pinned}</dd>
            <% end %>

            <%= if a.operator_notes && a.operator_notes != "" do %>
              <dt class="text-base-content/60">Tech</dt>
              <dd class="col-span-3 font-semibold">{a.operator_notes}</dd>
            <% end %>

            <%= if a.notes && a.notes != "" do %>
              <dt class="text-base-content/60">Notes</dt>
              <dd class="col-span-3 italic">{a.notes}</dd>
            <% end %>
          </dl>
        </li>
      </ol>
    </main>
    """
  end
end
