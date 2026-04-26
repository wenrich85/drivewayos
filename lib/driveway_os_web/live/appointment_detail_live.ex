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
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-2xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">{@service.name}</h1>
            <p class="text-base-content/70 text-sm">
              <span class={"badge badge-sm #{status_badge(@appt.status)}"}>
                {@appt.status}
              </span>
              <span class="ml-2">{fmt_when(@appt.scheduled_at)}</span>
            </p>
          </div>
          <a
            href={if admin?(@current_customer), do: "/admin/appointments", else: "/appointments"}
            class="btn btn-ghost btn-sm"
          >
            ← Back
          </a>
        </div>

        <div :if={@flash_msg} class="alert alert-success text-sm">{@flash_msg}</div>

        <section class="card bg-base-100 shadow">
          <div class="card-body space-y-2">
            <div class="grid grid-cols-3 gap-2 text-sm">
              <div class="text-base-content/60">Customer</div>
              <div class="col-span-2 font-semibold">{@booker.name}</div>

              <div class="text-base-content/60">Email</div>
              <div class="col-span-2">{to_string(@booker.email)}</div>

              <div :if={@booker.phone} class="text-base-content/60">Phone</div>
              <div :if={@booker.phone} class="col-span-2">{@booker.phone}</div>

              <div class="text-base-content/60">Vehicle</div>
              <div class="col-span-2">{@appt.vehicle_description}</div>

              <div class="text-base-content/60">Address</div>
              <div class="col-span-2">{@appt.service_address}</div>

              <div class="text-base-content/60">Duration</div>
              <div class="col-span-2">{@appt.duration_minutes} min</div>

              <div class="text-base-content/60">Total</div>
              <div class="col-span-2 font-semibold">{fmt_price(@appt.price_cents)}</div>

              <div :if={@appt.payment_status != :unpaid} class="text-base-content/60">
                Payment
              </div>
              <div :if={@appt.payment_status != :unpaid} class="col-span-2">
                <span :if={@appt.payment_status == :paid} class="badge badge-success badge-sm">
                  Paid
                </span>
                <span :if={@appt.payment_status == :pending} class="badge badge-warning badge-sm">
                  Pending
                </span>
              </div>

              <div :if={@appt.notes} class="text-base-content/60">Notes</div>
              <div :if={@appt.notes} class="col-span-2 text-sm">{@appt.notes}</div>

              <div :if={@appt.cancellation_reason} class="text-base-content/60">
                Cancelled
              </div>
              <div :if={@appt.cancellation_reason} class="col-span-2 text-sm">
                {@appt.cancellation_reason}
              </div>
            </div>
          </div>
        </section>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Actions</h2>

            <div class="flex gap-2 flex-wrap">
              <%!-- Admin actions --%>
              <button
                :if={admin?(@current_customer) and @appt.status == :pending}
                phx-click="confirm"
                class="btn btn-success btn-sm"
              >
                Confirm
              </button>
              <button
                :if={admin?(@current_customer) and @appt.status == :confirmed}
                phx-click="start_wash"
                class="btn btn-primary btn-sm"
              >
                Start
              </button>
              <button
                :if={admin?(@current_customer) and @appt.status == :in_progress}
                phx-click="complete"
                class="btn btn-success btn-sm"
              >
                Mark complete
              </button>

              <%!-- Refund: admin only, only on a paid appointment with a known PI --%>
              <button
                :if={
                  admin?(@current_customer) and @appt.payment_status == :paid and
                    not is_nil(@appt.stripe_payment_intent_id)
                }
                phx-click="refund"
                data-confirm="Refund this charge through Stripe?"
                class="btn btn-warning btn-sm"
              >
                Refund
              </button>

              <%!-- Cancel: anyone in scope, while it's still cancellable --%>
              <button
                :if={@appt.status in [:pending, :confirmed]}
                phx-click="cancel"
                data-confirm="Cancel this appointment?"
                class="btn btn-ghost btn-sm text-error"
              >
                Cancel appointment
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
