defmodule DrivewayOS.Onboarding.Steps.Payment do
  @moduledoc """
  Payment wizard step. As of Phase 4, generic over N providers in
  the `:payment` category — iterates `Onboarding.Registry.by_category(:payment)`.

  Phase 1 shipped Stripe Connect (single-card render). Phase 4 added
  Square + the picker UI: tenant sees side-by-side cards for every
  configured payment provider not yet set up. Each card routes to its
  own OAuth start (no select-then-submit two-click flow).

  `complete?/1` returns true if ANY payment provider is connected for
  the tenant. Wizard skips the step once any one is done. There's no
  alternate entry point in V1 for tenants who already chose one
  provider — switching is support-driven (per spec decision #4).
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Onboarding.{Affiliate, Registry}
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :payment

  @impl true
  def title, do: "Take card payments"

  @impl true
  def complete?(%Tenant{} = tenant) do
    Registry.by_category(:payment)
    |> Enum.any?(& &1.setup_complete?(tenant))
  end

  @impl true
  def render(assigns) do
    cards = providers_for_picker(assigns.current_tenant)
    assigns = Map.put(assigns, :cards, cards)

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-slate-600">
        Pick the payment processor you want to use.
        You can change later by emailing support.
      </p>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <%= for card <- @cards do %>
          <div class="card bg-base-100 shadow-md border border-slate-200 transition-shadow motion-reduce:transition-none hover:shadow-lg">
            <div class="card-body p-6 space-y-3">
              <h3 class="text-lg font-semibold text-slate-900">{card.title}</h3>
              <p class="text-sm text-slate-600 leading-relaxed">{card.blurb}</p>
              <%= if perk = Affiliate.perk_copy(card.id) do %>
                <p class="text-xs text-success font-medium">{perk}</p>
              <% end %>
              <a
                href={card.href}
                class="btn btn-primary min-h-[44px] gap-2 motion-reduce:transition-none"
                aria-label={"Connect " <> card.title}
              >
                {card.cta_label}
                <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
              </a>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def submit(_params, socket), do: {:ok, socket}

  defp providers_for_picker(tenant) do
    Registry.by_category(:payment)
    |> Enum.filter(& &1.configured?())
    |> Enum.reject(& &1.setup_complete?(tenant))
    |> Enum.map(fn mod -> Map.put(mod.display(), :id, mod.id()) end)
  end
end
