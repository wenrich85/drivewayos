defmodule DrivewayOSWeb.Admin.ActivityLive do
  @moduledoc """
  Tenant-admin → recent activity at `{slug}.lvh.me/admin/activity`.

  Surfaces the AuditLog entries scoped to this tenant:
  appointment confirmations / cancellations / refunds / payment
  failures, branding edits, custom-domain changes, and (when the
  platform admin uses it) tenant impersonation events.

  Read-only — the audit log is append-only by design. Operators
  use this to answer questions like "who refunded that booking?"
  or "did Stripe really send the payment-failed event?"
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Platform.AuditLog

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
         |> assign(:page_title, "Recent activity")
         |> load_entries()}
    end
  end

  defp load_entries(socket) do
    tenant_id = socket.assigns.current_tenant.id

    {:ok, entries} =
      AuditLog
      |> Ash.Query.for_read(:recent_for_tenant, %{tenant_id: tenant_id, limit: 100})
      |> Ash.read(authorize?: false)

    assign(socket, :entries, entries)
  end

  defp action_label(:appointment_refunded), do: "Refund"
  defp action_label(:appointment_payment_failed), do: "Payment failed"
  defp action_label(:appointment_confirmed), do: "Booking confirmed"
  defp action_label(:appointment_cancelled), do: "Booking cancelled"
  defp action_label(:tenant_branding_updated), do: "Branding updated"
  defp action_label(:tenant_suspended), do: "Tenant suspended"
  defp action_label(:tenant_reactivated), do: "Tenant reactivated"
  defp action_label(:tenant_archived), do: "Tenant archived"
  defp action_label(:tenant_impersonated), do: "Platform impersonation"
  defp action_label(:custom_domain_added), do: "Custom domain added"
  defp action_label(:custom_domain_verified), do: "Custom domain verified"
  defp action_label(:custom_domain_removed), do: "Custom domain removed"
  defp action_label(:platform_plan_updated), do: "Plan updated"
  defp action_label(other), do: to_string(other)

  defp action_badge(:appointment_refunded), do: "badge-warning"
  defp action_badge(:appointment_payment_failed), do: "badge-error"
  defp action_badge(:appointment_confirmed), do: "badge-success"
  defp action_badge(:appointment_cancelled), do: "badge-ghost"
  defp action_badge(:tenant_suspended), do: "badge-error"
  defp action_badge(:tenant_archived), do: "badge-error"
  defp action_badge(:tenant_impersonated), do: "badge-warning"
  defp action_badge(_), do: "badge-info"

  defp fmt_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %Y · %-I:%M %p UTC")

  defp summary_for(entry) do
    case {entry.action, entry.payload} do
      {:appointment_refunded, %{"source" => "stripe_webhook"}} ->
        "Refund processed via Stripe webhook"

      {:appointment_refunded, _} ->
        "Refund issued from admin"

      {:appointment_payment_failed, %{"failure_message" => msg}} when is_binary(msg) ->
        msg

      {:appointment_payment_failed, _} ->
        "Stripe declined the charge"

      {:tenant_branding_updated, %{"changed_fields" => fields}} when is_list(fields) ->
        "Updated #{Enum.join(fields, ", ")}"

      {:tenant_impersonated, %{"target_customer_email" => email}} ->
        "Impersonating #{email}"

      _ ->
        nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-4xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Dashboard
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">Recent activity</h1>
          <p class="text-sm text-base-content/70 mt-1">
            Audit trail for this shop. Append-only — entries can't be edited or deleted.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div :if={@entries == []} class="text-center py-12 px-4">
              <span
                class="hero-clipboard-document-list w-12 h-12 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60">
                No activity yet. Refunds, cancellations, and branding edits land here.
              </p>
            </div>

            <ul :if={@entries != []} class="divide-y divide-base-200">
              <li :for={entry <- @entries} class="py-4">
                <div class="flex items-start justify-between gap-3 flex-wrap">
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2 flex-wrap">
                      <span class={"badge badge-sm " <> action_badge(entry.action)}>
                        {action_label(entry.action)}
                      </span>
                      <span class="text-xs text-base-content/60">
                        {fmt_when(entry.inserted_at)}
                      </span>
                    </div>

                    <div :if={summary_for(entry)} class="text-sm mt-1 text-base-content/80">
                      {summary_for(entry)}
                    </div>

                    <div
                      :if={entry.target_type && entry.target_id}
                      class="text-xs text-base-content/60 mt-1 font-mono truncate"
                    >
                      {entry.target_type} #{String.slice(entry.target_id, 0, 8)}
                    </div>
                  </div>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
