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
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-3xl mx-auto space-y-6">
        <header>
          <a
            href="/admin/customers"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> All customers
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">{@customer.name}</h1>
          <p class="text-sm text-base-content/70 mt-1 flex items-center gap-3 flex-wrap">
            <span class="inline-flex items-center gap-1">
              <span class="hero-envelope w-4 h-4" aria-hidden="true"></span>
              {to_string(@customer.email)}
            </span>
            <span :if={@customer.phone} class="inline-flex items-center gap-1">
              <span class="hero-phone w-4 h-4" aria-hidden="true"></span> {@customer.phone}
            </span>
            <span :if={@customer.role == :admin} class="badge badge-primary badge-sm">Admin</span>
          </p>
        </header>

        <div :if={@flash_msg} role="alert" class="alert alert-success">
          <span class="hero-check-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@flash_msg}</span>
        </div>
        <div :if={@notes_error} role="alert" class="alert alert-error">
          <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@notes_error}</span>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-3">
            <div>
              <h2 class="card-title text-lg">Admin notes</h2>
              <p class="text-xs text-base-content/60">
                Visible to your team only. Gate codes, vehicle quirks, preferences, etc.
              </p>
            </div>

            <form id="notes-form" phx-submit="save_notes" class="space-y-2">
              <textarea
                name="customer[admin_notes]"
                rows="4"
                placeholder="Notes about this customer…"
                class="textarea textarea-bordered w-full"
              >{@customer.admin_notes || ""}</textarea>
              <button type="submit" class="btn btn-primary btn-sm gap-1">
                <span class="hero-check w-4 h-4" aria-hidden="true"></span> Save notes
              </button>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-lg">Appointment history</h2>

            <div :if={@appointments == []} class="text-center py-8 px-4">
              <span
                class="hero-calendar w-12 h-12 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60">No bookings yet.</p>
            </div>

            <ul :if={@appointments != []} class="divide-y divide-base-200">
              <li
                :for={a <- @appointments}
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
                    <span class={"badge badge-sm " <> status_badge(a.status)}>{a.status}</span>
                  </div>
                  <div class="text-sm text-base-content/70 mt-1">
                    {fmt_when(a.scheduled_at)}
                  </div>
                  <div class="text-xs text-base-content/60 truncate mt-1">
                    {a.vehicle_description} · {a.service_address}
                  </div>
                </div>
                <div class="text-sm font-semibold shrink-0">{fmt_price(a.price_cents)}</div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
