defmodule DrivewayOSWeb.Admin.CustomerDetailLive do
  @moduledoc """
  Tenant admin → individual customer page at
  `/admin/customers/:id`. Shows contact info + every appointment
  the customer's ever had + a free-text admin_notes editor.

  All reads are tenant-scoped via `Ash.get(.., tenant: ..)` —
  asking for an id from another tenant returns :error and the LV
  bounces back to the customers list.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      true ->
        load_customer(socket, id)
    end
  end

  defp load_customer(socket, id) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(Customer, id, tenant: tenant_id, authorize?: false) do
      {:ok, customer} ->
        {:ok, appointments} =
          Appointment
          |> Ash.Query.for_read(:for_customer, %{customer_id: customer.id})
          |> Ash.Query.set_tenant(tenant_id)
          |> Ash.read(authorize?: false)

        {:ok, services} =
          ServiceType |> Ash.Query.set_tenant(tenant_id) |> Ash.read(authorize?: false)

        {:ok,
         socket
         |> assign(:page_title, customer.name)
         |> assign(:customer, customer)
         |> assign(:appointments, appointments)
         |> assign(:service_map, Map.new(services, &{&1.id, &1}))
         |> assign(:flash_msg, nil)
         |> assign(:notes_error, nil)}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/admin/customers")}
    end
  end

  @impl true
  def handle_event("save_notes", %{"customer" => %{"admin_notes" => notes}}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    case socket.assigns.customer
         |> Ash.Changeset.for_update(:update, %{admin_notes: notes})
         |> Ash.update(authorize?: false, tenant: tenant_id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:customer, updated)
         |> assign(:flash_msg, "Notes saved.")
         |> assign(:notes_error, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :notes_error, "Could not save notes.")}
    end
  end

  defp fmt_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d, %Y · %-I:%M %p")

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp service_name(map, id), do: get_in(map, [id, Access.key(:name)]) || "Service"

  defp status_badge(:pending), do: "badge-warning"
  defp status_badge(:confirmed), do: "badge-info"
  defp status_badge(:in_progress), do: "badge-primary"
  defp status_badge(:completed), do: "badge-success"
  defp status_badge(:cancelled), do: "badge-ghost"
  defp status_badge(_), do: "badge"

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-3xl mx-auto space-y-6">
        <div class="flex justify-between items-start flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">{@customer.name}</h1>
            <p class="text-base-content/70 text-sm">
              {to_string(@customer.email)}
              <span :if={@customer.phone} class="ml-2">· {@customer.phone}</span>
            </p>
          </div>
          <a href="/admin/customers" class="btn btn-ghost btn-sm">← All customers</a>
        </div>

        <div :if={@flash_msg} class="alert alert-success text-sm">{@flash_msg}</div>
        <div :if={@notes_error} class="alert alert-error text-sm">{@notes_error}</div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Admin notes</h2>
            <p class="text-xs text-base-content/60">
              Visible to your team only. Gate codes, vehicle quirks, preferences, etc.
            </p>

            <form id="notes-form" phx-submit="save_notes" class="space-y-2">
              <textarea
                name="customer[admin_notes]"
                rows="4"
                class="textarea textarea-bordered w-full"
              >{@customer.admin_notes || ""}</textarea>
              <button type="submit" class="btn btn-primary btn-sm">Save notes</button>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Appointment history</h2>

            <div :if={@appointments == []} class="text-center py-6 text-base-content/60">
              No bookings yet.
            </div>

            <ul :if={@appointments != []} class="divide-y divide-base-200">
              <li
                :for={a <- @appointments}
                class="py-3 flex items-center justify-between gap-3 flex-wrap"
              >
                <div class="flex-1 min-w-0">
                  <div class="font-semibold flex items-center gap-2">
                    <span>{service_name(@service_map, a.service_type_id)}</span>
                    <span class={"badge badge-sm #{status_badge(a.status)}"}>{a.status}</span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    {fmt_when(a.scheduled_at)}
                  </div>
                  <div class="text-xs text-base-content/60 truncate">
                    {a.vehicle_description} · {a.service_address}
                  </div>
                </div>
                <div class="text-sm font-semibold">{fmt_price(a.price_cents)}</div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
