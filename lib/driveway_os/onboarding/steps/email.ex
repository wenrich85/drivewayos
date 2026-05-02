defmodule DrivewayOS.Onboarding.Steps.Email do
  @moduledoc """
  Email wizard step. Wraps the Postmark provider.

  Unlike Payment (hosted-redirect), Email is API-first: the wizard
  submit calls `Providers.Postmark.provision/2` synchronously, which
  hits Postmark's /servers endpoint, persists credentials on the
  tenant, and sends a welcome email through the new server. The
  send doubles as the deliverability probe — failure is surfaced
  to the operator instead of advancing.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Onboarding.Providers.Postmark
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :email

  @impl true
  def title, do: "Send booking emails"

  @impl true
  def complete?(%Tenant{} = tenant), do: Postmark.setup_complete?(tenant)

  @impl true
  def render(assigns) do
    display = Postmark.display()
    assigns = Map.put(assigns, :display, display)

    ~H"""
    <form id="step-email-form" phx-submit="step_submit" class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <p class="text-xs text-base-content/60">
        We'll create a Postmark server for your shop and send you a quick test email
        to confirm everything's working. Takes a few seconds.
      </p>
      <p :if={@errors[:email]} class="text-error text-sm">
        {@errors[:email]}
      </p>
      <button type="submit" class="btn btn-primary btn-sm gap-1">
        {@display.cta_label}
        <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
      </button>
    </form>
    """
  end

  @impl true
  def submit(_params, socket) do
    tenant = socket.assigns.current_tenant

    case Postmark.provision(tenant, %{}) do
      {:ok, updated} ->
        {:ok, Phoenix.Component.assign(socket, :current_tenant, updated)}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp format_reason(%{status: status, body: body}),
    do: "Postmark error #{status}: #{inspect(body)}"

  defp format_reason(other), do: inspect(other)
end
