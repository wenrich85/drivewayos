defmodule DrivewayOSWeb.AppointmentDetailLive do
  @moduledoc """
  /appointments/:id — single-appointment view, used by both
  customers (see + cancel their own) and admins (see + confirm /
  cancel / start / complete any in their tenant).

  Authorization is two-pronged:

    1. Resource lookup is tenant-scoped via Ash multitenancy, so
       cross-tenant ids return :error.
    2. Within a tenant, only the booker OR an admin can view —
       a stranger gets bounced to /appointments.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Billing.StripeClient
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        load(socket, id)
    end
  end

  defp load(socket, id) do
    tenant_id = socket.assigns.current_tenant.id
    me = socket.assigns.current_customer

    with {:ok, appt} <- Ash.get(Appointment, id, tenant: tenant_id, authorize?: false),
         true <- can_view?(appt, me),
         {:ok, service} <-
           Ash.get(ServiceType, appt.service_type_id,
             tenant: tenant_id,
             authorize?: false
           ),
         {:ok, booker} <-
           Ash.get(Customer, appt.customer_id, tenant: tenant_id, authorize?: false) do
      {:ok,
       socket
       |> assign(:page_title, "Appointment")
       |> assign(:appt, appt)
       |> assign(:service, service)
       |> assign(:booker, booker)
       |> assign(:flash_msg, nil)}
    else
      _ -> {:ok, push_navigate(socket, to: ~p"/appointments")}
    end
  end

  defp can_view?(_appt, %Customer{role: :admin}), do: true
  defp can_view?(%{customer_id: cid}, %Customer{id: cid}), do: true
  defp can_view?(_, _), do: false

  @impl true
  def handle_event("confirm", _, socket) do
    transition(socket, :confirm, %{})
  end

  def handle_event("cancel", _, socket) do
    transition(socket, :cancel, %{cancellation_reason: cancel_reason(socket)})
  end

  def handle_event("start_wash", _, socket) do
    transition(socket, :start_wash, %{})
  end

  def handle_event("complete", _, socket) do
    transition(socket, :complete, %{})
  end

  def handle_event("refund", _, socket) do
    if socket.assigns.current_customer.role == :admin do
      do_refund(socket)
    else
      {:noreply, socket}
    end
  end

  defp do_refund(socket) do
    tenant = socket.assigns.current_tenant
    appt = socket.assigns.appt

    cond do
      is_nil(tenant.stripe_account_id) ->
        {:noreply, assign(socket, :flash_msg, "Connect Stripe before refunding.")}

      is_nil(appt.stripe_payment_intent_id) ->
        {:noreply, assign(socket, :flash_msg, "No payment to refund.")}

      appt.payment_status != :paid ->
        {:noreply, assign(socket, :flash_msg, "Appointment isn't in a refundable state.")}

      true ->
        case StripeClient.refund_payment_intent(
               tenant.stripe_account_id,
               appt.stripe_payment_intent_id
             ) do
          {:ok, _} ->
            # Flip locally — Stripe will also send a charge.refunded
            # webhook; the resource action is idempotent.
            updated =
              appt
              |> Ash.Changeset.for_update(:mark_refunded, %{})
              |> Ash.update!(authorize?: false, tenant: tenant.id)

            {:noreply,
             socket
             |> assign(:appt, updated)
             |> assign(:flash_msg, "Refund issued. Stripe will confirm shortly.")}

          {:error, _} ->
            {:noreply, assign(socket, :flash_msg, "Refund failed. Try again.")}
        end
    end
  end

  defp cancel_reason(socket) do
    if socket.assigns.current_customer.role == :admin do
      "Cancelled by admin"
    else
      "Cancelled by customer"
    end
  end

  defp transition(socket, action, args) do
    tenant_id = socket.assigns.current_tenant.id

    case socket.assigns.appt
         |> Ash.Changeset.for_update(action, args)
         |> Ash.update(authorize?: false, tenant: tenant_id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:appt, updated)
         |> assign(:flash_msg, "Updated.")}

      {:error, _} ->
        {:noreply, assign(socket, :flash_msg, "Could not update.")}
    end
  end

  defp fmt_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d, %Y · %-I:%M %p UTC")

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  defp status_badge(:pending), do: "badge-warning"
  defp status_badge(:confirmed), do: "badge-info"
  defp status_badge(:in_progress), do: "badge-primary"
  defp status_badge(:completed), do: "badge-success"
  defp status_badge(:cancelled), do: "badge-ghost"
  defp status_badge(_), do: "badge"

  defp admin?(%Customer{role: :admin}), do: true
  defp admin?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header class="space-y-3">
          <a
            href={if admin?(@current_customer), do: "/admin/appointments", else: "/appointments"}
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Back
          </a>
          <div>
            <h1 class="text-3xl font-bold tracking-tight">{@service.name}</h1>
            <div class="mt-2 flex items-center gap-2 flex-wrap">
              <span class={"badge badge-sm " <> status_badge(@appt.status)}>{@appt.status}</span>
              <span :if={@appt.payment_status == :paid} class="badge badge-sm badge-success">Paid</span>
              <span :if={@appt.payment_status == :pending} class="badge badge-sm badge-warning">Payment pending</span>
              <span :if={@appt.payment_status == :refunded} class="badge badge-sm badge-ghost">Refunded</span>
              <span class="text-sm text-base-content/70 ml-1">{fmt_when(@appt.scheduled_at)}</span>
            </div>
          </div>
        </header>

        <div :if={@flash_msg} role="alert" class="alert alert-success">
          <span class="hero-check-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@flash_msg}</span>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-4">
            <h2 class="card-title text-base">Details</h2>

            <dl class="grid grid-cols-3 gap-x-3 gap-y-3 text-sm">
              <dt class="text-base-content/60">Customer</dt>
              <dd class="col-span-2 font-semibold">{@booker.name}</dd>

              <dt class="text-base-content/60">Email</dt>
              <dd class="col-span-2 truncate">{to_string(@booker.email)}</dd>

              <%= if @booker.phone do %>
                <dt class="text-base-content/60">Phone</dt>
                <dd class="col-span-2">{@booker.phone}</dd>
              <% end %>

              <dt class="text-base-content/60">Vehicle</dt>
              <dd class="col-span-2">{@appt.vehicle_description}</dd>

              <dt class="text-base-content/60">Address</dt>
              <dd class="col-span-2">{@appt.service_address}</dd>

              <dt class="text-base-content/60">Duration</dt>
              <dd class="col-span-2">{@appt.duration_minutes} min</dd>

              <dt class="text-base-content/60">Total</dt>
              <dd class="col-span-2 font-semibold">{fmt_price(@appt.price_cents)}</dd>

              <%= if @appt.notes && @appt.notes != "" do %>
                <dt class="text-base-content/60">Notes</dt>
                <dd class="col-span-2 text-base-content/80">{@appt.notes}</dd>
              <% end %>

              <%= if @appt.cancellation_reason do %>
                <dt class="text-base-content/60">Cancelled</dt>
                <dd class="col-span-2 text-base-content/80">{@appt.cancellation_reason}</dd>
              <% end %>
            </dl>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-base">Actions</h2>

            <div class="mt-3 flex gap-2 flex-wrap">
              <%!-- Admin actions --%>
              <button
                :if={admin?(@current_customer) and @appt.status == :pending}
                phx-click="confirm"
                class="btn btn-success btn-sm gap-1"
              >
                <span class="hero-check w-4 h-4" aria-hidden="true"></span> Confirm
              </button>
              <button
                :if={admin?(@current_customer) and @appt.status == :confirmed}
                phx-click="start_wash"
                class="btn btn-primary btn-sm gap-1"
              >
                <span class="hero-play w-4 h-4" aria-hidden="true"></span> Start
              </button>
              <button
                :if={admin?(@current_customer) and @appt.status == :in_progress}
                phx-click="complete"
                class="btn btn-success btn-sm gap-1"
              >
                <span class="hero-check-circle w-4 h-4" aria-hidden="true"></span> Mark complete
              </button>

              <%!-- Refund: admin only, only on a paid appointment with a known PI --%>
              <button
                :if={
                  admin?(@current_customer) and @appt.payment_status == :paid and
                    not is_nil(@appt.stripe_payment_intent_id)
                }
                phx-click="refund"
                data-confirm="Refund this charge through Stripe?"
                class="btn btn-error btn-sm btn-outline gap-1"
              >
                <span class="hero-arrow-uturn-left w-4 h-4" aria-hidden="true"></span> Refund
              </button>

              <%!-- Cancel: anyone in scope, while it's still cancellable --%>
              <button
                :if={@appt.status in [:pending, :confirmed]}
                phx-click="cancel"
                data-confirm="Cancel this appointment?"
                class="btn btn-ghost btn-sm text-error gap-1"
              >
                <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span> Cancel
              </button>

              <p
                :if={@appt.status in [:completed, :cancelled]}
                class="text-sm text-base-content/60"
              >
                No further actions — this appointment is {@appt.status}.
              </p>
            </div>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
