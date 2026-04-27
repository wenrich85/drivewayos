defmodule DrivewayOS.AppointmentBroadcaster do
  @moduledoc """
  Per-tenant PubSub fan-out for Appointment lifecycle events. Each
  state-change handler (confirm / cancel / start_wash / complete /
  refund / new booking) calls `broadcast/2` so any subscribed
  LiveView refreshes without a manual reload.

  Topic shape: `"tenant:<tenant_id>:appointments"`. Tenant-scoped
  by construction — there's no cross-tenant fan-out — so a tenant
  admin's dashboard never wakes up to another tenant's events.
  """
  alias Phoenix.PubSub

  @pubsub DrivewayOS.PubSub

  @type event :: :booked | :confirmed | :cancelled | :started | :completed | :payment_changed

  @doc "Subscribe the calling process to a tenant's appointment events."
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(tenant_id) when is_binary(tenant_id) do
    PubSub.subscribe(@pubsub, topic_for(tenant_id))
  end

  @doc """
  Broadcast a state-change event. Wraps `Phoenix.PubSub.broadcast/3`
  in a rescue so a PubSub hiccup never blocks the underlying
  transition.
  """
  @spec broadcast(binary(), event(), map()) :: :ok
  def broadcast(tenant_id, event, payload \\ %{}) when is_binary(tenant_id) and is_atom(event) do
    PubSub.broadcast(@pubsub, topic_for(tenant_id), {:appointment, event, payload})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp topic_for(tenant_id), do: "tenant:#{tenant_id}:appointments"
end
