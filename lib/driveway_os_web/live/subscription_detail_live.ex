defmodule DrivewayOSWeb.SubscriptionDetailLive do
  @moduledoc """
  /subscriptions/:id — single recurring booking. Both the
  subscription's owner and a tenant admin can open it. Surfaces:

    * Service / frequency / status / addresses + notes
    * Past appointments materialized from this subscription
      (heuristic match by customer + service since `starts_at`,
      since Appointment doesn't carry a `subscription_id`).
    * Pause / resume / cancel actions, gated on current status.

  Cross-tenant access raises via tenant-scoped Ash.get; missing
  permissions bounce to `/`.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Scheduling.{Appointment, ServiceType, Subscription}
  alias DrivewayOS.SubscriptionBroadcaster

  require Ash.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok,
         socket
         |> push_navigate(to: ~p"/sign-in?return_to=/subscriptions/#{id}")}

      true ->
        load(socket, id)
    end
  end

  defp load(socket, id) do
    tenant_id = socket.assigns.current_tenant.id
    me = socket.assigns.current_customer

    case Ash.get(Subscription, id, tenant: tenant_id, authorize?: false) do
      {:ok, sub} ->
        cond do
          sub.customer_id != me.id and me.role != :admin ->
            {:ok, push_navigate(socket, to: ~p"/")}

          true ->
            assemble(socket, sub, tenant_id)
        end

      _ ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp assemble(socket, sub, tenant_id) do
    {:ok, service} = Ash.get(ServiceType, sub.service_type_id, tenant: tenant_id, authorize?: false)
    {:ok, customer} = Ash.get(Customer, sub.customer_id, tenant: tenant_id, authorize?: false)

    appts = past_appointments(sub, tenant_id)

    {:ok,
     socket
     |> assign(:page_title, "Subscription · #{service.name}")
     |> assign(:sub, sub)
     |> assign(:service, service)
     |> assign(:customer, customer)
     |> assign(:appointments, appts)
     |> assign(:flash_msg, nil)}
  end

  # No `subscription_id` on Appointment in V1 — we approximate the
  # back-link by matching customer + service since the sub started.
  # Good enough for visualizing recurring history; if a customer
  # also one-off books the same service it'll show up here, which
  # is acceptable noise (still their own washes).
  defp past_appointments(sub, tenant_id) do
    {:ok, appts} =
      Appointment
      |> Ash.Query.filter(
        customer_id == ^sub.customer_id and
          service_type_id == ^sub.service_type_id and
          scheduled_at >= ^sub.starts_at
      )
      |> Ash.Query.sort(scheduled_at: :desc)
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.read(authorize?: false)

    appts
  end

  @impl true
  def handle_event("pause", _, socket), do: transition(socket, :pause)
  def handle_event("resume", _, socket), do: transition(socket, :resume)
  def handle_event("cancel", _, socket), do: transition(socket, :cancel)

  defp transition(socket, action) do
    tenant = socket.assigns.current_tenant
    sub = socket.assigns.sub

    case sub
         |> Ash.Changeset.for_update(action, %{})
         |> Ash.update(authorize?: false, tenant: tenant.id) do
      {:ok, updated} ->
        SubscriptionBroadcaster.broadcast(tenant.id, sub.customer_id, action, %{id: sub.id})

        if action == :cancel do
          notify_cancelled(tenant, socket.assigns.customer, updated, socket.assigns.service)
        end

        {:noreply,
         socket
         |> assign(:sub, updated)
         |> assign(:flash_msg, flash_for(action))}

      _ ->
        {:noreply, assign(socket, :flash_msg, "Couldn't update the subscription.")}
    end
  end

  defp flash_for(:pause), do: "Paused. We won't book the next one until you resume."
  defp flash_for(:resume), do: "Resumed."
  defp flash_for(:cancel), do: "Cancelled. No more recurring washes will be booked."

  defp notify_cancelled(tenant, customer, sub, service) do
    tenant
    |> BookingEmail.subscription_cancelled(customer, sub, service)
    |> Mailer.deliver()

    :ok
  rescue
    _ -> :ok
  end

  defp fmt_when(nil), do: "—"
  defp fmt_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d, %Y · %-I:%M %p")

  defp fmt_date(nil), do: "—"
  defp fmt_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d, %Y")

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp status_badge(:active), do: "badge-success"
  defp status_badge(:paused), do: "badge-warning"
  defp status_badge(:cancelled), do: "badge-ghost"
  defp status_badge(_), do: "badge-ghost"

  defp appt_badge(:pending), do: "badge-warning"
  defp appt_badge(:confirmed), do: "badge-info"
  defp appt_badge(:in_progress), do: "badge-primary"
  defp appt_badge(:completed), do: "badge-success"
  defp appt_badge(:cancelled), do: "badge-ghost"
  defp appt_badge(_), do: "badge"

  defp back_link(socket) do
    if socket.assigns.current_customer.role == :admin do
      ~p"/admin/customers/#{socket.assigns.sub.customer_id}"
    else
      ~p"/me"
    end
  end

  defp back_label(socket) do
    if socket.assigns.current_customer.role == :admin do
      "Back to #{socket.assigns.customer.name}"
    else
      "Back to my account"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header>
          <a
            href={back_link(@socket |> Map.put(:assigns, assigns))}
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span>
            {back_label(@socket |> Map.put(:assigns, assigns))}
          </a>
          <div class="mt-2 flex items-start justify-between gap-3 flex-wrap">
            <div class="min-w-0">
              <h1 class="text-3xl font-bold tracking-tight">{@service.name}</h1>
              <p class="text-sm text-base-content/70 mt-1">
                {@customer.name} · {Atom.to_string(@sub.frequency)}
              </p>
            </div>
            <span class={"badge badge-lg " <> status_badge(@sub.status)}>{@sub.status}</span>
          </div>
        </header>

        <div :if={@flash_msg} role="alert" class="alert alert-success">
          <span class="hero-check-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@flash_msg}</span>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 grid grid-cols-2 gap-4 text-sm">
            <div>
              <div class="text-xs text-base-content/60 uppercase tracking-wide">Started</div>
              <div class="font-medium">{fmt_date(@sub.starts_at)}</div>
            </div>
            <div>
              <div class="text-xs text-base-content/60 uppercase tracking-wide">Next run</div>
              <div class="font-medium">{fmt_when(@sub.next_run_at)}</div>
            </div>
            <div :if={@sub.last_run_at} class="col-span-2">
              <div class="text-xs text-base-content/60 uppercase tracking-wide">Last run</div>
              <div class="font-medium">{fmt_when(@sub.last_run_at)}</div>
            </div>
            <div class="col-span-2">
              <div class="text-xs text-base-content/60 uppercase tracking-wide">Vehicle</div>
              <div class="font-medium">{@sub.vehicle_description}</div>
            </div>
            <div class="col-span-2">
              <div class="text-xs text-base-content/60 uppercase tracking-wide">Address</div>
              <div class="font-medium">{@sub.service_address}</div>
            </div>
            <div :if={@sub.notes && @sub.notes != ""} class="col-span-2">
              <div class="text-xs text-base-content/60 uppercase tracking-wide">Notes</div>
              <div class="text-base-content/80">{@sub.notes}</div>
            </div>
          </div>
        </section>

        <section
          :if={@sub.status != :cancelled}
          class="card bg-base-100 shadow-sm border border-base-300"
        >
          <div class="card-body p-6 flex flex-row items-center justify-between gap-3 flex-wrap">
            <div>
              <h2 class="card-title text-base">Manage</h2>
              <p class="text-xs text-base-content/60 mt-1">
                Pause to skip upcoming runs without losing your settings; cancel ends future runs.
              </p>
            </div>
            <div class="flex gap-2 flex-wrap">
              <button
                :if={@sub.status == :active}
                phx-click="pause"
                class="btn btn-ghost btn-sm gap-1"
              >
                <span class="hero-pause w-4 h-4" aria-hidden="true"></span> Pause
              </button>
              <button
                :if={@sub.status == :paused}
                phx-click="resume"
                class="btn btn-success btn-sm gap-1"
              >
                <span class="hero-play w-4 h-4" aria-hidden="true"></span> Resume
              </button>
              <button
                phx-click="cancel"
                data-confirm="Cancel this recurring booking? Future runs will stop."
                class="btn btn-ghost btn-sm text-error gap-1"
              >
                <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span> Cancel
              </button>
            </div>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-lg">Past appointments</h2>
            <p class="text-xs text-base-content/60">
              Every wash on this customer + service since the subscription started.
            </p>

            <div :if={@appointments == []} class="text-center py-6 px-4">
              <span
                class="hero-calendar w-10 h-10 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60">
                No washes yet. The first run is scheduled for {fmt_when(@sub.next_run_at)}.
              </p>
            </div>

            <ul :if={@appointments != []} class="divide-y divide-base-200">
              <li
                :for={a <- @appointments}
                class="py-3 flex items-start justify-between gap-3 flex-wrap"
              >
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <.link
                      navigate={~p"/appointments/#{a.id}"}
                      class="font-semibold link link-hover"
                    >
                      {fmt_when(a.scheduled_at)}
                    </.link>
                    <span class={"badge badge-sm " <> appt_badge(a.status)}>{a.status}</span>
                  </div>
                  <div class="text-xs text-base-content/60 truncate mt-0.5">
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
