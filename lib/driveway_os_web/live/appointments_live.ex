defmodule DrivewayOSWeb.AppointmentsLive do
  @moduledoc """
  Customer's "My Appointments" page at `{slug}.lvh.me/appointments`.

  Auth-gated. Lists the signed-in customer's appointments in the
  current tenant, sorted newest-first. V2 will add cancellation,
  rescheduling, photo gallery, etc.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Scheduling.Appointment
  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        tenant_id = socket.assigns.current_tenant.id
        customer_id = socket.assigns.current_customer.id

        appts =
          Appointment
          |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
          |> Ash.Query.set_tenant(tenant_id)
          |> Ash.read!(authorize?: false)

        # One small lookup keyed by service_type_id so the row render
        # can show the service name without an N+1.
        service_ids = appts |> Enum.map(& &1.service_type_id) |> Enum.uniq()

        services =
          if service_ids == [] do
            %{}
          else
            ServiceType
            |> Ash.Query.filter(id in ^service_ids)
            |> Ash.Query.set_tenant(tenant_id)
            |> Ash.read!(authorize?: false)
            |> Map.new(&{&1.id, &1})
          end

        {:ok,
         socket
         |> assign(:page_title, "My appointments")
         |> assign(:appointments, appts)
         |> assign(:services, services)}
    end
  end

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp fmt_when(%DateTime{} = dt) do
    Calendar.strftime(dt, "%A, %B %-d, %Y · %-I:%M %p")
  end

  # Spec § 6.7 status palette.
  defp status_badge_class(:pending), do: "badge-warning"
  defp status_badge_class(:confirmed), do: "badge-info"
  defp status_badge_class(:in_progress), do: "badge-primary"
  defp status_badge_class(:completed), do: "badge-success"
  defp status_badge_class(:cancelled), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-3xl mx-auto space-y-6">
        <header class="flex items-end justify-between flex-wrap gap-3">
          <div>
            <a
              href="/"
              class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
            >
              <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
            </a>
            <h1 class="text-3xl font-bold tracking-tight mt-2">My appointments</h1>
            <p class="text-sm text-base-content/70 mt-1">
              Every wash you've booked at <span class="font-semibold">{@current_tenant.display_name}</span>, newest first.
            </p>
          </div>
          <.link navigate={~p"/book"} class="btn btn-primary gap-2">
            <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Book another
          </.link>
        </header>

        <%!-- Empty state per spec § 6.9 --%>
        <section :if={@appointments == []} class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body text-center py-12 px-4">
            <span
              class="hero-calendar w-12 h-12 mx-auto text-base-content/30"
              aria-hidden="true"
            ></span>
            <h3 class="mt-4 text-lg font-semibold">No appointments yet.</h3>
            <p class="mt-1 text-sm text-base-content/60 max-w-sm mx-auto">
              Pick a service and a time and {@current_tenant.display_name} will take it from there.
            </p>
            <.link navigate={~p"/book"} class="btn btn-primary btn-sm mt-4">
              Book your first wash
            </.link>
          </div>
        </section>

        <ul :if={@appointments != []} class="space-y-3">
          <li :for={a <- @appointments}>
            <.link
              navigate={~p"/appointments/#{a.id}"}
              class="block card bg-base-100 shadow-sm border border-base-300 hover:shadow-md transition-shadow cursor-pointer"
            >
              <div class="card-body p-5">
                <div class="flex justify-between items-start gap-3 flex-wrap">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 flex-wrap">
                      <span class="font-semibold">
                        {service_name(@services, a.service_type_id)}
                      </span>
                      <span class={"badge badge-sm " <> status_badge_class(a.status)}>
                        {a.status}
                      </span>
                      <span :if={a.payment_status == :paid} class="badge badge-sm badge-success">
                        Paid
                      </span>
                    </div>
                    <div class="text-sm text-base-content/70 mt-1 flex items-center gap-1">
                      <span class="hero-clock w-4 h-4 shrink-0" aria-hidden="true"></span>
                      {fmt_when(a.scheduled_at)}
                    </div>
                    <div class="text-sm text-base-content/70 mt-1 flex items-start gap-1 truncate">
                      <span
                        class="hero-truck w-4 h-4 shrink-0 mt-0.5"
                        aria-hidden="true"
                      ></span>
                      <span class="truncate">{a.vehicle_description}</span>
                    </div>
                    <div class="text-sm text-base-content/70 mt-1 flex items-start gap-1 truncate">
                      <span
                        class="hero-map-pin w-4 h-4 shrink-0 mt-0.5"
                        aria-hidden="true"
                      ></span>
                      <span class="truncate">{a.service_address}</span>
                    </div>
                  </div>
                  <div class="text-right shrink-0">
                    <div class="text-lg font-semibold">{fmt_price(a.price_cents)}</div>
                  </div>
                </div>
              </div>
            </.link>
          </li>
        </ul>
      </div>
    </main>
    """
  end

  defp service_name(services, id) do
    case Map.get(services, id) do
      %{name: name} -> name
      _ -> "Service"
    end
  end
end
