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

  defp status_badge_class(:pending), do: "badge-ghost"
  defp status_badge_class(:confirmed), do: "badge-info"
  defp status_badge_class(:in_progress), do: "badge-warning"
  defp status_badge_class(:completed), do: "badge-success"
  defp status_badge_class(:cancelled), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-12">
      <div class="max-w-3xl mx-auto space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-3xl font-bold">My appointments</h1>
          <.link navigate={~p"/book"} class="btn btn-primary">Book another</.link>
        </div>

        <div :if={@appointments == []} class="card bg-base-100 shadow">
          <div class="card-body text-center py-12">
            <p class="text-base-content/60">
              No appointments yet.
            </p>
            <div class="card-actions justify-center mt-2">
              <.link navigate={~p"/book"} class="btn btn-primary">Book your first wash</.link>
            </div>
          </div>
        </div>

        <ul :if={@appointments != []} class="space-y-3">
          <li :for={a <- @appointments} class="card bg-base-100 shadow">
            <div class="card-body p-5">
              <div class="flex justify-between items-start gap-3 flex-wrap">
                <div class="flex-1">
                  <div class="font-semibold">
                    {service_name(@services, a.service_type_id)}
                  </div>
                  <div class="text-sm text-base-content/70">
                    {fmt_when(a.scheduled_at)}
                  </div>
                  <div class="text-sm text-base-content/70 mt-1">
                    {a.vehicle_description} · {a.service_address}
                  </div>
                </div>
                <div class="text-right">
                  <span class={"badge " <> status_badge_class(a.status)}>
                    {a.status}
                  </span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {fmt_price(a.price_cents)}
                  </div>
                </div>
              </div>
            </div>
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
