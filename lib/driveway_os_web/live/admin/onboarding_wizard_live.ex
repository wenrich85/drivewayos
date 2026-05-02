defmodule DrivewayOSWeb.Admin.OnboardingWizardLive do
  @moduledoc """
  Mandatory linear wizard at `/admin/onboarding`. Walks a freshly-
  provisioned tenant through Branding → Services → Schedule →
  Payment → Email.

  State machine: `DrivewayOS.Onboarding.Wizard` (pure functions).
  Persistence: `tenant.wizard_progress` jsonb map (only `:skipped`
  flags persisted; done-ness is computed via each step's
  `complete?/1` predicate).

  When `Wizard.complete?/1` returns true, the LV redirects to
  `/admin` with a flash. Skip-for-later writes a :skipped flag and
  re-renders against the next step. The wizard does not lock the
  tenant in — direct navigation to `/admin` works mid-wizard.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Onboarding.Wizard

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      Wizard.complete?(socket.assigns.current_tenant) ->
        {:ok,
         socket
         |> put_flash(:info, "You're all set. Welcome to your dashboard.")
         |> push_navigate(to: ~p"/admin")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Set up your shop")
         |> assign(:errors, %{})
         |> assign_step()}
    end
  end

  defp assign_step(socket) do
    step = Wizard.current_step(socket.assigns.current_tenant)
    assign(socket, :current_step, step)
  end

  @impl true
  def handle_event("step_submit", params, socket) do
    step = socket.assigns.current_step

    case step.submit(params, socket) do
      {:ok, socket} ->
        socket = assign(socket, :errors, %{})

        if Wizard.complete?(socket.assigns.current_tenant) do
          {:noreply,
           socket
           |> put_flash(:info, "You're all set. Welcome to your dashboard.")
           |> push_navigate(to: ~p"/admin")}
        else
          {:noreply, assign_step(socket)}
        end

      {:error, message} ->
        {:noreply, assign(socket, :errors, %{base: message})}
    end
  end

  def handle_event("skip_step", %{"step" => step_id}, socket) do
    step_atom = String.to_existing_atom(step_id)
    {:ok, updated} = Wizard.skip(socket.assigns.current_tenant, step_atom)

    socket = assign(socket, :current_tenant, updated)

    if Wizard.complete?(updated) do
      {:noreply,
       socket
       |> put_flash(:info, "You're all set. Welcome to your dashboard.")
       |> push_navigate(to: ~p"/admin")}
    else
      {:noreply, assign_step(socket)}
    end
  end

  defp step_position(step) do
    Wizard.steps() |> Enum.find_index(&(&1 == step)) |> Kernel.+(1)
  end

  defp total_steps, do: length(Wizard.steps())

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Skip to dashboard
          </a>
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mt-3">
            Step {step_position(@current_step)} of {total_steps()}
          </p>
          <h1 class="text-3xl font-bold tracking-tight">{@current_step.title()}</h1>
        </header>

        <div :if={@errors[:base]} role="alert" class="alert alert-error text-sm">
          {@errors[:base]}
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            {@current_step.render(assigns)}
          </div>
        </section>

        <div class="flex justify-end">
          <button
            type="button"
            phx-click="skip_step"
            phx-value-step={@current_step.id()}
            class="btn btn-ghost btn-sm text-base-content/60"
          >
            Skip for now
          </button>
        </div>
      </div>
    </main>
    """
  end
end
