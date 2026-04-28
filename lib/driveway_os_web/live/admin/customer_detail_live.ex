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
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Plans
  alias DrivewayOS.Scheduling.{Appointment, ServiceType, Subscription}
  alias DrivewayOS.SubscriptionBroadcaster

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

        {:ok, subscriptions} =
          Subscription
          |> Ash.Query.for_read(:for_customer, %{customer_id: customer.id})
          |> Ash.Query.set_tenant(tenant_id)
          |> Ash.read(authorize?: false)

        {:ok,
         socket
         |> assign(:page_title, customer.name)
         |> assign(:customer, customer)
         |> assign(:appointments, appointments)
         |> assign(:status_filter, :all)
         |> assign(:subscriptions, subscriptions)
         |> assign(:service_map, Map.new(services, &{&1.id, &1}))
         |> assign(:services, services)
         |> assign(:subscribe_form?, false)
         |> assign(:subscribe_error, nil)
         |> assign(:flash_msg, nil)
         |> assign(:notes_error, nil)}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/admin/customers")}
    end
  end

  @impl true
  def handle_event("filter_history_status", %{"status" => status}, socket) do
    {:noreply, assign(socket, :status_filter, parse_status(status))}
  end

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

  # --- Subscriptions ---

  # --- Promote / demote (multi-admin per tenant) ---

  def handle_event("promote_to_admin", _, socket) do
    update_customer_role(socket, :admin, "Promoted to admin.")
  end

  def handle_event("demote_to_customer", _, socket) do
    cond do
      socket.assigns.customer.id == socket.assigns.current_customer.id ->
        # Don't let the operator lock themselves out by demoting
        # their own admin role mid-session.
        {:noreply, assign(socket, :flash_msg, "You can't demote yourself.")}

      last_admin?(socket) ->
        {:noreply,
         assign(
           socket,
           :flash_msg,
           "Can't demote the last admin — promote someone else first."
         )}

      true ->
        update_customer_role(socket, :customer, "Demoted to customer.")
    end
  end

  defp update_customer_role(socket, role, success_msg) do
    case socket.assigns.customer
         |> Ash.Changeset.for_update(:update, %{role: role})
         |> Ash.update(authorize?: false, tenant: socket.assigns.current_tenant.id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:customer, updated)
         |> assign(:flash_msg, success_msg)}

      _ ->
        {:noreply, assign(socket, :flash_msg, "Couldn't update the role.")}
    end
  end

  defp last_admin?(socket) do
    case DrivewayOS.Accounts.tenant_admins(socket.assigns.current_tenant.id) do
      [%{id: only_id}] -> only_id == socket.assigns.customer.id
      _ -> false
    end
  end

  def handle_event("show_subscribe_form", _, socket) do
    {:noreply, socket |> assign(:subscribe_form?, true) |> assign(:subscribe_error, nil)}
  end

  def handle_event("hide_subscribe_form", _, socket) do
    {:noreply, socket |> assign(:subscribe_form?, false) |> assign(:subscribe_error, nil)}
  end

  def handle_event("create_subscription", %{"sub" => params}, socket) do
    tenant_id = socket.assigns.current_tenant.id
    customer = socket.assigns.customer

    starts_at =
      case DateTime.from_iso8601(params["starts_at"] <> ":00Z") do
        {:ok, dt, _} -> dt
        _ -> nil
      end

    attrs = %{
      customer_id: customer.id,
      service_type_id: params["service_type_id"],
      frequency: String.to_existing_atom(params["frequency"] || "biweekly"),
      starts_at: starts_at,
      service_address: params["service_address"] |> to_string() |> String.trim(),
      vehicle_description: params["vehicle_description"] |> to_string() |> String.trim()
    }

    case Subscription
         |> Ash.Changeset.for_create(:subscribe, attrs, tenant: tenant_id)
         |> Ash.create(authorize?: false) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:subscribe_form?, false)
         |> assign(:subscribe_error, nil)
         |> reload_subscriptions()}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        msg = errors |> Enum.map(&Map.get(&1, :message, "is invalid")) |> Enum.join("; ")
        {:noreply, assign(socket, :subscribe_error, msg)}

      _ ->
        {:noreply, assign(socket, :subscribe_error, "Could not create subscription.")}
    end
  end

  def handle_event("pause_subscription", %{"id" => id}, socket),
    do: transition_subscription(socket, id, :pause)

  def handle_event("resume_subscription", %{"id" => id}, socket),
    do: transition_subscription(socket, id, :resume)

  def handle_event("cancel_subscription", %{"id" => id}, socket),
    do: transition_subscription(socket, id, :cancel)

  defp transition_subscription(socket, id, action) do
    tenant_id = socket.assigns.current_tenant.id
    tenant = socket.assigns.current_tenant
    customer = socket.assigns.customer

    with {:ok, sub} <- Ash.get(Subscription, id, tenant: tenant_id, authorize?: false),
         true <- sub.customer_id == customer.id,
         {:ok, updated} <-
           sub
           |> Ash.Changeset.for_update(action, %{})
           |> Ash.update(authorize?: false, tenant: tenant_id) do
      SubscriptionBroadcaster.broadcast(tenant_id, customer.id, action, %{id: id})

      if action == :cancel do
        notify_subscription_cancelled(tenant, customer, updated)
      end

      {:noreply, reload_subscriptions(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp notify_subscription_cancelled(tenant, customer, sub) do
    case Ash.get(ServiceType, sub.service_type_id, tenant: tenant.id, authorize?: false) do
      {:ok, service} ->
        tenant
        |> BookingEmail.subscription_cancelled(customer, sub, service)
        |> Mailer.deliver()

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reload_subscriptions(socket) do
    {:ok, subscriptions} =
      Subscription
      |> Ash.Query.for_read(:for_customer, %{customer_id: socket.assigns.customer.id})
      |> Ash.Query.set_tenant(socket.assigns.current_tenant.id)
      |> Ash.read(authorize?: false)

    assign(socket, :subscriptions, subscriptions)
  end

  defp fmt_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d, %Y · %-I:%M %p")

  defp fmt_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d")

  defp sub_badge(:active), do: "badge-success"
  defp sub_badge(:paused), do: "badge-warning"
  defp sub_badge(:cancelled), do: "badge-ghost"
  defp sub_badge(_), do: "badge-ghost"

  defp frequency_label(:weekly), do: "weekly"
  defp frequency_label(:biweekly), do: "biweekly"
  defp frequency_label(:monthly), do: "monthly"
  defp frequency_label(other), do: to_string(other)

  # Mirror of CustomerProfileLive's loyalty helpers — operators
  # see exactly what the customer sees on their /me, plus a hint
  # about how the wizard's redemption checkbox actually applies
  # the credit (since some operators won't intuit that without
  # context).
  defp loyalty_visible?(%{loyalty_threshold: t}, %{loyalty_count: _}) when is_integer(t), do: true
  defp loyalty_visible?(_, _), do: false

  defp loyalty_earned?(%{loyalty_threshold: t}, %{loyalty_count: c})
       when is_integer(t) and is_integer(c),
       do: c >= t

  defp loyalty_earned?(_, _), do: false

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp service_name(map, id), do: get_in(map, [id, Access.key(:name)]) || "Service"

  defp parse_status("all"), do: :all
  defp parse_status("pending"), do: :pending
  defp parse_status("confirmed"), do: :confirmed
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("completed"), do: :completed
  defp parse_status("cancelled"), do: :cancelled
  defp parse_status(_), do: :all

  defp filter_appts(appts, :all), do: appts
  defp filter_appts(appts, status), do: Enum.filter(appts, &(&1.status == status))

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
          <div class="mt-2 flex justify-between items-start gap-3 flex-wrap">
            <h1 class="text-3xl font-bold tracking-tight">{@customer.name}</h1>
            <div class="flex gap-2 flex-wrap">
              <.link
                navigate={~p"/book?on_behalf_of=#{@customer.id}"}
                class="btn btn-primary btn-sm gap-1"
                title={"Book a wash for #{@customer.name}"}
              >
                <span class="hero-plus w-4 h-4" aria-hidden="true"></span>
                Book a wash
              </.link>
              <button
                :if={@customer.role != :admin}
                phx-click="promote_to_admin"
                data-confirm={"Give #{@customer.name} full admin access?"}
                class="btn btn-ghost btn-sm gap-1"
                title="Grant operator privileges"
              >
                <span class="hero-shield-check w-4 h-4" aria-hidden="true"></span>
                Promote to admin
              </button>
              <button
                :if={@customer.role == :admin and @customer.id != @current_customer.id}
                phx-click="demote_to_customer"
                data-confirm={"Remove admin access from #{@customer.name}?"}
                class="btn btn-ghost btn-sm gap-1 text-warning"
                title="Revoke operator privileges"
              >
                <span class="hero-shield-exclamation w-4 h-4" aria-hidden="true"></span>
                Demote
              </button>
            </div>
          </div>
          <p class="text-sm text-base-content/70 mt-1 flex items-center gap-3 flex-wrap">
            <span class="inline-flex items-center gap-1">
              <span class="hero-envelope w-4 h-4" aria-hidden="true"></span>
              {to_string(@customer.email)}
            </span>
            <a
              :if={@customer.phone}
              href={"tel:" <> @customer.phone}
              class="inline-flex items-center gap-1 link link-hover"
              title={"Call " <> @customer.phone}
            >
              <span class="hero-phone w-4 h-4" aria-hidden="true"></span> {@customer.phone}
            </a>
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

        <section
          :if={loyalty_visible?(@current_tenant, @customer)}
          class={
            "card shadow-sm border " <>
              if loyalty_earned?(@current_tenant, @customer),
                do: "bg-success/10 border-success/30",
                else: "bg-primary/5 border-primary/20"
          }
        >
          <div class="card-body p-4 flex-row items-center gap-3">
            <span
              class={
                "w-6 h-6 shrink-0 hero-gift " <>
                  if loyalty_earned?(@current_tenant, @customer),
                    do: "text-success",
                    else: "text-primary"
              }
              aria-hidden="true"
            ></span>
            <div class="flex-1 min-w-0">
              <div class="font-semibold">
                <%= if loyalty_earned?(@current_tenant, @customer) do %>
                  Loyalty: free wash earned
                <% else %>
                  Loyalty: {@customer.loyalty_count}/{@current_tenant.loyalty_threshold}
                <% end %>
              </div>
              <div :if={loyalty_earned?(@current_tenant, @customer)} class="text-xs text-base-content/70 mt-0.5">
                Apply on their next booking — wizard's redemption checkbox handles the discount.
              </div>
            </div>
            <div class="text-xl font-bold tabular-nums shrink-0">
              {@customer.loyalty_count}/{@current_tenant.loyalty_threshold}
            </div>
          </div>
        </section>

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

        <section
          :if={Plans.tenant_can?(@current_tenant, :customer_subscriptions)}
          class="card bg-base-100 shadow-sm border border-base-300"
        >
          <div class="card-body p-6">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h2 class="card-title text-lg">Recurring bookings</h2>
              <button
                :if={not @subscribe_form? and @services != []}
                phx-click="show_subscribe_form"
                class="btn btn-ghost btn-sm gap-1"
              >
                <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Add subscription
              </button>
            </div>

            <div :if={@subscriptions == [] and not @subscribe_form?} class="text-sm text-base-content/60 mt-2">
              No recurring bookings.
            </div>

            <ul :if={@subscriptions != []} class="divide-y divide-base-200 mt-2">
              <li :for={sub <- @subscriptions} class="py-3">
                <div class="flex items-start justify-between gap-3 flex-wrap">
                  <div class="min-w-0">
                    <div class="font-medium flex items-center gap-2 flex-wrap">
                      <.link
                        navigate={~p"/subscriptions/#{sub.id}"}
                        class="link link-hover"
                      >
                        {service_name(@service_map, sub.service_type_id)}
                      </.link>
                      <span class={"badge badge-sm " <> sub_badge(sub.status)}>{sub.status}</span>
                      <span class="text-xs text-base-content/60">
                        {frequency_label(sub.frequency)}
                      </span>
                    </div>
                    <div class="text-sm text-base-content/70 mt-1">
                      Next: {fmt_date(sub.next_run_at)}
                      <span class="text-base-content/40 mx-1">·</span>
                      {sub.vehicle_description}
                    </div>
                    <div class="text-xs text-base-content/60 truncate mt-0.5">
                      {sub.service_address}
                    </div>
                  </div>
                  <div class="flex gap-2">
                    <button
                      :if={sub.status == :active}
                      phx-click="pause_subscription"
                      phx-value-id={sub.id}
                      class="btn btn-ghost btn-xs gap-1"
                    >
                      <span class="hero-pause w-3 h-3" aria-hidden="true"></span> Pause
                    </button>
                    <button
                      :if={sub.status == :paused}
                      phx-click="resume_subscription"
                      phx-value-id={sub.id}
                      class="btn btn-success btn-xs gap-1"
                    >
                      <span class="hero-play w-3 h-3" aria-hidden="true"></span> Resume
                    </button>
                    <button
                      :if={sub.status != :cancelled}
                      phx-click="cancel_subscription"
                      phx-value-id={sub.id}
                      data-confirm="Cancel this recurring booking?"
                      class="btn btn-ghost btn-xs text-error gap-1"
                    >
                      <span class="hero-x-mark w-3 h-3" aria-hidden="true"></span> Cancel
                    </button>
                  </div>
                </div>
              </li>
            </ul>

            <form
              :if={@subscribe_form?}
              id="admin-subscribe-form"
              phx-submit="create_subscription"
              class="mt-4 border-t border-base-200 pt-4 space-y-3"
            >
              <div :if={@subscribe_error} role="alert" class="alert alert-error text-sm">
                {@subscribe_error}
              </div>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="label" for="sub-service">
                    <span class="label-text font-medium">Service</span>
                  </label>
                  <select
                    id="sub-service"
                    name="sub[service_type_id]"
                    class="select select-bordered w-full"
                    required
                  >
                    <option value="">— Pick a service —</option>
                    <option :for={s <- @services} value={s.id}>{s.name}</option>
                  </select>
                </div>
                <div>
                  <label class="label" for="sub-freq">
                    <span class="label-text font-medium">Frequency</span>
                  </label>
                  <select
                    id="sub-freq"
                    name="sub[frequency]"
                    class="select select-bordered w-full"
                    required
                  >
                    <option value="weekly">Weekly</option>
                    <option value="biweekly" selected>Every 2 weeks</option>
                    <option value="monthly">Monthly</option>
                  </select>
                </div>
              </div>

              <div>
                <label class="label" for="sub-starts">
                  <span class="label-text font-medium">First run</span>
                </label>
                <input
                  id="sub-starts"
                  type="datetime-local"
                  name="sub[starts_at]"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="label" for="sub-vehicle">
                    <span class="label-text font-medium">Vehicle</span>
                  </label>
                  <input
                    id="sub-vehicle"
                    type="text"
                    name="sub[vehicle_description]"
                    placeholder="2022 Subaru Outback (Blue)"
                    class="input input-bordered w-full"
                    required
                  />
                </div>
                <div>
                  <label class="label" for="sub-address">
                    <span class="label-text font-medium">Address</span>
                  </label>
                  <input
                    id="sub-address"
                    type="text"
                    name="sub[service_address]"
                    placeholder="123 Cedar St, San Antonio TX"
                    class="input input-bordered w-full"
                    required
                  />
                </div>
              </div>

              <div class="flex justify-end gap-2">
                <button type="button" phx-click="hide_subscribe_form" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Create subscription</button>
              </div>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h2 class="card-title text-lg">Appointment history</h2>
              <form
                :if={@appointments != []}
                id="customer-history-filter-form"
                phx-change="filter_history_status"
                class="flex flex-wrap gap-1"
              >
                <label
                  :for={
                    {label, value} <-
                      [
                        {"All", "all"},
                        {"Pending", "pending"},
                        {"Confirmed", "confirmed"},
                        {"Completed", "completed"},
                        {"Cancelled", "cancelled"}
                      ]
                  }
                  class={
                    "btn btn-xs " <>
                      if Atom.to_string(@status_filter) == value,
                        do: "btn-primary",
                        else: "btn-ghost"
                  }
                >
                  <input
                    type="radio"
                    name="status"
                    value={value}
                    checked={Atom.to_string(@status_filter) == value}
                    class="hidden"
                  />
                  {label}
                </label>
              </form>
            </div>

            <div :if={@appointments == []} class="text-center py-8 px-4">
              <span
                class="hero-calendar w-12 h-12 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60">No bookings yet.</p>
            </div>

            <% filtered_appts = filter_appts(@appointments, @status_filter) %>

            <div
              :if={@appointments != [] and filtered_appts == []}
              class="text-center py-8 px-4"
            >
              <p class="text-sm text-base-content/60">
                No {Atom.to_string(@status_filter)} appointments.
              </p>
            </div>

            <ul :if={filtered_appts != []} class="divide-y divide-base-200">
              <li
                :for={a <- filtered_appts}
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
