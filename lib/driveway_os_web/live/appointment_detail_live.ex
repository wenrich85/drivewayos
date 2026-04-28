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
  alias DrivewayOS.AppointmentBroadcaster
  alias DrivewayOS.Billing.StripeClient
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
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
       |> assign(:flash_msg, nil)
       |> assign(:cancel_form_open?, false)
       |> assign(:reschedule_form_open?, false)
       |> assign(:reschedule_error, nil)}
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

  # Both customer and admin cancels go through the inline form.
  # The reason set + the "Admin:" / "Customer:" prefix are decided
  # in `format_cancel_reason/2` based on the current_customer's role.
  def handle_event("cancel", %{"cancel" => params}, socket) do
    reason = format_cancel_reason(params, socket.assigns.current_customer)
    transition(socket, :cancel, %{cancellation_reason: reason})
  end

  # Fallback for fast-path cancels (dashboard inline button) that
  # don't render the form. Lands as "Cancelled by admin" /
  # "Cancelled by customer" the same way it has historically.
  def handle_event("cancel", _, socket) do
    transition(socket, :cancel, %{cancellation_reason: cancel_reason(socket)})
  end

  def handle_event("show_cancel_form", _, socket) do
    {:noreply, assign(socket, :cancel_form_open?, true)}
  end

  def handle_event("hide_cancel_form", _, socket) do
    {:noreply, assign(socket, :cancel_form_open?, false)}
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

  def handle_event("show_reschedule_form", _, socket) do
    if socket.assigns.current_customer.role == :admin do
      {:noreply,
       socket
       |> assign(:reschedule_form_open?, true)
       |> assign(:reschedule_error, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("hide_reschedule_form", _, socket) do
    {:noreply,
     socket
     |> assign(:reschedule_form_open?, false)
     |> assign(:reschedule_error, nil)}
  end

  def handle_event(
        "reschedule",
        %{"reschedule" => %{"new_scheduled_at" => raw}},
        socket
      ) do
    if socket.assigns.current_customer.role != :admin do
      {:noreply, socket}
    else
      tenant = socket.assigns.current_tenant
      old_scheduled_at = socket.assigns.appt.scheduled_at

      case parse_local_datetime(raw) do
        {:ok, new_at} ->
          case socket.assigns.appt
               |> Ash.Changeset.for_update(:reschedule, %{new_scheduled_at: new_at})
               |> Ash.update(authorize?: false, tenant: tenant.id) do
            {:ok, updated} ->
              notify_rescheduled(tenant, socket.assigns.booker, updated, old_scheduled_at)

              {:noreply,
               socket
               |> assign(:appt, updated)
               |> assign(:reschedule_form_open?, false)
               |> assign(:reschedule_error, nil)
               |> assign(:flash_msg, "Rescheduled. Customer notified.")}

            {:error, %Ash.Error.Invalid{errors: errors}} ->
              msg = errors |> Enum.map(&Map.get(&1, :message, "is invalid")) |> Enum.join("; ")
              {:noreply, assign(socket, :reschedule_error, msg)}

            _ ->
              {:noreply, assign(socket, :reschedule_error, "Couldn't reschedule.")}
          end

        :error ->
          {:noreply, assign(socket, :reschedule_error, "Pick a valid future date and time.")}
      end
    end
  end

  defp parse_local_datetime(raw) do
    case DateTime.from_iso8601(raw <> ":00Z") do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  defp notify_rescheduled(tenant, booker, appt, old_scheduled_at) do
    case Ash.get(ServiceType, appt.service_type_id, tenant: tenant.id, authorize?: false) do
      {:ok, service} ->
        tenant
        |> BookingEmail.rescheduled(booker, appt, service, old_scheduled_at)
        |> Mailer.deliver()

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_event(
        "save_operator_notes",
        %{"appointment" => %{"operator_notes" => notes}},
        socket
      ) do
    if socket.assigns.current_customer.role == :admin do
      tenant_id = socket.assigns.current_tenant.id

      case socket.assigns.appt
           |> Ash.Changeset.for_update(:set_operator_notes, %{operator_notes: notes})
           |> Ash.update(authorize?: false, tenant: tenant_id) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:appt, updated)
           |> assign(:flash_msg, "Operator notes saved.")}

        _ ->
          {:noreply, assign(socket, :flash_msg, "Couldn't save the notes.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("resend_email", _, socket) do
    if socket.assigns.current_customer.role == :admin do
      do_resend_email(socket)
    else
      {:noreply, socket}
    end
  end

  defp do_resend_email(socket) do
    socket.assigns.current_tenant
    |> BookingEmail.confirmation(
      socket.assigns.booker,
      socket.assigns.appt,
      socket.assigns.service
    )
    |> Mailer.deliver()

    {:noreply, assign(socket, :flash_msg, "Confirmation email re-sent.")}
  rescue
    _ -> {:noreply, assign(socket, :flash_msg, "Couldn't send the email — try again.")}
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
          {:ok, refund} ->
            # Flip locally — Stripe will also send a charge.refunded
            # webhook; the resource action is idempotent.
            updated =
              appt
              |> Ash.Changeset.for_update(:mark_refunded, %{})
              |> Ash.update!(authorize?: false, tenant: tenant.id)

            DrivewayOS.Platform.log_audit!(%{
              action: :appointment_refunded,
              tenant_id: tenant.id,
              target_type: "Appointment",
              target_id: appt.id,
              payload: %{
                "stripe_refund_id" => refund.id,
                "stripe_payment_intent_id" => appt.stripe_payment_intent_id,
                "amount_cents" => appt.price_cents
              }
            })

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

  @customer_cancel_reasons [
    {"schedule_conflict", "Schedule conflict"},
    {"service_not_needed", "Service no longer needed"},
    {"weather", "Bad weather"},
    {"changed_provider", "Going with another provider"},
    {"other", "Other"}
  ]

  # Admin reasons skew toward operational realities (weather is
  # shared with the customer side, but tech-out-sick / equipment
  # issue / customer no-show only make sense from the operator's
  # perspective).
  @admin_cancel_reasons [
    {"weather", "Bad weather"},
    {"equipment", "Equipment issue"},
    {"tech_unavailable", "Tech unavailable"},
    {"no_show", "Customer no-show"},
    {"customer_rescheduled", "Customer rescheduled"},
    {"other", "Other"}
  ]

  @doc false
  def cancel_reason_options(%Customer{role: :admin}), do: @admin_cancel_reasons
  def cancel_reason_options(_), do: @customer_cancel_reasons

  defp format_cancel_reason(%{"reason" => key, "details" => details}, %Customer{role: :admin}) do
    label = lookup_cancel_label(key, @admin_cancel_reasons)

    case String.trim(details || "") do
      "" -> "Admin: #{label}"
      d -> "Admin: #{label} — #{d}"
    end
  end

  defp format_cancel_reason(%{"reason" => key, "details" => details}, _) do
    label = lookup_cancel_label(key, @customer_cancel_reasons)

    case String.trim(details || "") do
      "" -> "Customer: #{label}"
      d -> "Customer: #{label} — #{d}"
    end
  end

  defp format_cancel_reason(_, %Customer{role: :admin}), do: "Cancelled by admin"
  defp format_cancel_reason(_, _), do: "Cancelled by customer"

  defp lookup_cancel_label(key, options) do
    Enum.find_value(options, "Other", fn {k, l} -> if k == key, do: l end)
  end

  defp transition(socket, action, args) do
    tenant_id = socket.assigns.current_tenant.id

    case socket.assigns.appt
         |> Ash.Changeset.for_update(action, args)
         |> Ash.update(authorize?: false, tenant: tenant_id) do
      {:ok, updated} ->
        send_state_change_emails(socket, action, updated)
        AppointmentBroadcaster.broadcast(tenant_id, action_event(action), %{id: updated.id})

        {:noreply,
         socket
         |> assign(:appt, updated)
         |> assign(:flash_msg, "Updated.")}

      {:error, _} ->
        {:noreply, assign(socket, :flash_msg, "Could not update.")}
    end
  end

  defp action_event(:confirm), do: :confirmed
  defp action_event(:cancel), do: :cancelled
  defp action_event(:start_wash), do: :started
  defp action_event(:complete), do: :completed
  defp action_event(_), do: :payment_changed

  # Side-effect: emails on state change. Confirm + cancel notify the
  # customer; cancellations from a customer also alert the admins.
  # Wraps everything in a rescue so a mailer outage can't block the
  # transition itself — the database state update is what matters.
  defp send_state_change_emails(socket, action, updated) do
    tenant = socket.assigns.current_tenant
    booker = socket.assigns.booker
    service = socket.assigns.service
    actor = socket.assigns.current_customer

    case action do
      :confirm ->
        tenant
        |> BookingEmail.confirmed(booker, updated, service)
        |> Mailer.deliver()

      :cancel ->
        tenant
        |> BookingEmail.cancelled(booker, updated, service)
        |> Mailer.deliver()

        # Customer-initiated cancellations also alert tenant admins
        # so they can re-shuffle their day.
        if actor.id == booker.id and actor.role != :admin do
          for admin <- DrivewayOS.Accounts.tenant_admins(tenant.id) do
            tenant
            |> BookingEmail.customer_cancellation_alert(admin, booker, updated, service)
            |> Mailer.deliver()
          end
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
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
            <p
              :if={@service.description && @service.description != ""}
              class="text-sm text-base-content/70 mt-1"
            >
              {@service.description}
            </p>
            <div class="mt-2 flex items-center gap-2 flex-wrap">
              <span class={"badge badge-sm " <> status_badge(@appt.status)}>{@appt.status}</span>
              <span :if={@appt.payment_status == :paid} class="badge badge-sm badge-success">Paid</span>
              <span :if={@appt.payment_status == :pending} class="badge badge-sm badge-warning">Payment pending</span>
              <span :if={@appt.payment_status == :failed} class="badge badge-sm badge-error">Payment failed</span>
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

              <%= if admin?(@current_customer) && @appt.reminder_sent_at do %>
                <dt class="text-base-content/60">Reminder</dt>
                <dd class="col-span-2 text-base-content/80">
                  Sent {fmt_when(@appt.reminder_sent_at)}
                </dd>
              <% end %>
            </dl>
          </div>
        </section>

        <%!-- Admin-only pinned notes from Customer.admin_notes —
             gate codes, vehicle quirks, prefs. Hidden when empty so
             clean records don't render an empty card. --%>
        <section
          :if={admin?(@current_customer) and @booker.admin_notes && @booker.admin_notes != ""}
          class="card bg-warning/10 border border-warning/30 shadow-sm"
        >
          <div class="card-body p-4">
            <div class="flex items-start gap-3">
              <span
                class="hero-bookmark w-5 h-5 text-warning shrink-0 mt-0.5"
                aria-hidden="true"
              ></span>
              <div class="min-w-0">
                <div class="text-xs font-semibold uppercase tracking-wide text-warning">
                  Pinned about {@booker.name}
                </div>
                <div class="text-sm mt-1">{@booker.admin_notes}</div>
              </div>
            </div>
          </div>
        </section>

        <%!-- Operator-only notes scoped to THIS appointment.
             Distinct from `Customer.admin_notes` (carries across
             every booking) and from `appt.notes` (the customer's
             own comment from booking). One-off tech instructions:
             "steep driveway, bring ramps." --%>
        <section
          :if={admin?(@current_customer)}
          class="card bg-base-100 shadow-sm border border-base-300"
        >
          <div class="card-body p-6 space-y-3">
            <div>
              <h2 class="card-title text-base">Operator notes</h2>
              <p class="text-xs text-base-content/60">
                Tech-only context for this specific appointment. Not visible to the customer.
              </p>
            </div>

            <form
              id="operator-notes-form"
              phx-submit="save_operator_notes"
              class="space-y-2"
            >
              <textarea
                name="appointment[operator_notes]"
                rows="3"
                placeholder="One-off instructions: steep driveway, bring ramps; skip the wheels; etc."
                class="textarea textarea-bordered w-full text-sm"
              >{@appt.operator_notes || ""}</textarea>
              <button type="submit" class="btn btn-primary btn-sm gap-1">
                <span class="hero-check w-4 h-4" aria-hidden="true"></span> Save notes
              </button>
            </form>
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

              <%!-- Resend confirmation: admin only, while the appointment isn't cancelled/done --%>
              <button
                :if={admin?(@current_customer) and @appt.status not in [:completed, :cancelled]}
                phx-click="resend_email"
                class="btn btn-ghost btn-sm gap-1"
              >
                <span class="hero-envelope w-4 h-4" aria-hidden="true"></span> Resend email
              </button>

              <%!-- Add to calendar: visible to anyone who can see the appointment --%>
              <a
                :if={@appt.status not in [:cancelled]}
                href={~p"/appointments/#{@appt.id}/calendar.ics"}
                class="btn btn-ghost btn-sm gap-1"
                title="Download .ics for Google / Apple / Outlook"
              >
                <span class="hero-calendar w-4 h-4" aria-hidden="true"></span> Add to calendar
              </a>

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

              <%!-- Admin reschedule: opens an inline date-picker form
                   below. Status (pending/confirmed) is preserved
                   across the move; the customer is emailed about it. --%>
              <button
                :if={
                  admin?(@current_customer) and @appt.status in [:pending, :confirmed] and
                    not @reschedule_form_open?
                }
                phx-click="show_reschedule_form"
                class="btn btn-ghost btn-sm gap-1"
              >
                <span class="hero-arrow-path w-4 h-4" aria-hidden="true"></span> Reschedule
              </button>

              <%!-- Admin and customer both get an inline form with a
                   reason picker. The reason set differs by role
                   (handled in the form below) so the analytics card
                   on /admin can bucket admin-side cancellations
                   distinctly from customer-side ones. --%>
              <button
                :if={
                  @appt.status in [:pending, :confirmed] and
                    not @cancel_form_open?
                }
                phx-click="show_cancel_form"
                class="btn btn-ghost btn-sm text-error gap-1"
              >
                <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span> Cancel
              </button>

              <%!-- Book again: customer-facing utility on terminal-state
                   appointments. Skips the rebook hop for guests since
                   their account is ephemeral. --%>
              <.link
                :if={
                  @appt.status in [:completed, :cancelled] and
                    @current_customer && @current_customer.id == @booker.id and
                    not @booker.guest?
                }
                navigate={~p"/book?from=#{@appt.id}"}
                class="btn btn-primary btn-sm gap-1"
              >
                <span class="hero-arrow-path w-4 h-4" aria-hidden="true"></span> Book again
              </.link>

              <p
                :if={@appt.status in [:completed, :cancelled]}
                class="text-sm text-base-content/60"
              >
                No further actions — this appointment is {@appt.status}.
              </p>
            </div>

            <form
              :if={@cancel_form_open? and @appt.status in [:pending, :confirmed]}
              id="cancel-appointment-form"
              phx-submit="cancel"
              class="mt-4 border-t border-base-200 pt-4 space-y-3"
            >
              <p class="text-sm font-medium">Why are you cancelling?</p>

              <div class="space-y-2">
                <label
                  :for={{value, label} <- cancel_reason_options(@current_customer)}
                  class="flex items-center gap-2 text-sm cursor-pointer"
                >
                  <input
                    type="radio"
                    name="cancel[reason]"
                    value={value}
                    class="radio radio-sm"
                    required
                  />
                  {label}
                </label>
              </div>

              <textarea
                name="cancel[details]"
                rows="2"
                placeholder="Anything else we should know? (optional)"
                class="textarea textarea-bordered w-full text-sm"
              ></textarea>

              <div class="flex justify-end gap-2">
                <button type="button" phx-click="hide_cancel_form" class="btn btn-ghost btn-sm">
                  Back
                </button>
                <button type="submit" class="btn btn-error btn-sm">
                  Cancel booking
                </button>
              </div>
            </form>

            <form
              :if={@reschedule_form_open? and @appt.status in [:pending, :confirmed]}
              id="reschedule-appointment-form"
              phx-submit="reschedule"
              class="mt-4 border-t border-base-200 pt-4 space-y-3"
            >
              <p class="text-sm font-medium">Move this appointment to a new time</p>

              <div :if={@reschedule_error} role="alert" class="alert alert-error text-sm">
                {@reschedule_error}
              </div>

              <div>
                <label class="label" for="reschedule-when">
                  <span class="label-text font-medium">New date and time</span>
                </label>
                <input
                  id="reschedule-when"
                  type="datetime-local"
                  name="reschedule[new_scheduled_at]"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <p class="text-xs text-base-content/60">
                The customer will be emailed about the change. Status stays the same — pending bookings stay pending, confirmed stay confirmed.
              </p>

              <div class="flex justify-end gap-2">
                <button type="button" phx-click="hide_reschedule_form" class="btn btn-ghost btn-sm">
                  Back
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  Save new time
                </button>
              </div>
            </form>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
