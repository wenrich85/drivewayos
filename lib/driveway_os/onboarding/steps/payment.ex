defmodule DrivewayOS.Onboarding.Steps.Payment do
  @moduledoc """
  Payment wizard step. Delegates everything to the
  `Providers.StripeConnect` provider — the OAuth + state +
  account-creation logic already lives there from Phase 0.

  This step is a thin presentational layer: the wizard renders the
  StripeConnect provider's `display.title` + `display.blurb` + a
  "Connect Stripe" link to `/onboarding/stripe/start`. The OAuth
  redirect comes back to `/onboarding/stripe/callback`, which
  redirects to `/admin/onboarding` when the wizard is incomplete
  (Task 13).
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Onboarding.{Affiliate, Providers.StripeConnect}
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :payment

  @impl true
  def title, do: "Take card payments"

  @impl true
  def complete?(%Tenant{} = tenant), do: StripeConnect.setup_complete?(tenant)

  @impl true
  def render(assigns) do
    display = StripeConnect.display()
    assigns = Map.put(assigns, :display, display)

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <%= if perk = Affiliate.perk_copy(:stripe_connect) do %>
        <p class="text-xs text-success font-medium">{perk}</p>
      <% end %>
      <a href={@display.href} class="btn btn-primary btn-sm gap-1">
        {@display.cta_label}
        <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
      </a>
      <p class="text-xs text-base-content/60">
        Stripe handles identity verification on their site; we'll bring you back here when you're done.
      </p>
    </div>
    """
  end

  @impl true
  def submit(_params, socket), do: {:ok, socket}
end
