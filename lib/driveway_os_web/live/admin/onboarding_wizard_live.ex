defmodule DrivewayOSWeb.Admin.OnboardingWizardLive do
  @moduledoc """
  Stub wizard at `/admin/onboarding`. Phase 0 ships this as a
  directory of provider cards grouped by category — Phase 1 will
  replace the body with the actual linear wizard
  (Branding → Services → Schedule → Payment → Email).

  Lives next to the existing admin LVs so it picks up the same
  tenant + customer mounts. Auth: tenant-scoped + admin-only.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Onboarding.Registry

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
         |> assign(:page_title, "Set up your shop")
         |> assign(:groups, group_pending(socket.assigns.current_tenant))}
    end
  end

  # Returns a list of {category, [provider_module, ...]} for the
  # categories where this tenant still has providers needing setup.
  # Empty categories drop out so an all-done shop sees an empty list.
  defp group_pending(tenant) do
    tenant
    |> Registry.needing_setup()
    |> Enum.group_by(& &1.category())
    |> Enum.sort_by(fn {category, _} -> category end)
  end

  defp category_label(:payment), do: "Payment"
  defp category_label(:email), do: "Email"
  defp category_label(:accounting), do: "Accounting"
  defp category_label(other), do: other |> Atom.to_string() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-3xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Dashboard
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">Set up your shop</h1>
          <p class="text-sm text-base-content/70 mt-1">
            Connect the integrations your shop needs. We'll walk you through each one.
          </p>
        </header>

        <div :if={@groups == []} class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body text-center py-10 px-4">
            <span class="hero-check-circle w-12 h-12 mx-auto text-success" aria-hidden="true"></span>
            <h2 class="mt-3 text-lg font-semibold">All set</h2>
            <p class="text-sm text-base-content/70 mt-1">
              Every available integration is connected. You're ready for customers.
            </p>
          </div>
        </div>

        <section
          :for={{category, providers} <- @groups}
          class="card bg-base-100 shadow-sm border border-base-300"
        >
          <div class="card-body p-6">
            <h2 class="card-title text-lg">{category_label(category)}</h2>
            <ul class="space-y-3 mt-2">
              <li
                :for={provider <- providers}
                class="flex gap-3 items-start bg-base-200/50 border border-base-300 rounded-lg p-4"
              >
                <% display = provider.display() %>
                <div class="flex-1 min-w-0">
                  <div class="font-semibold">{display.title}</div>
                  <div class="text-sm text-base-content/70 mt-0.5">{display.blurb}</div>
                </div>
                <a
                  href={display.href}
                  class="btn btn-primary btn-sm gap-1 shrink-0 self-center"
                >
                  {display.cta_label}
                  <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
                </a>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
