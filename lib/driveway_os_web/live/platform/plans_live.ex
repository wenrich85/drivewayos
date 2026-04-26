defmodule DrivewayOSWeb.Platform.PlansLive do
  @moduledoc """
  Platform admin → SaaS plan editor at admin.lvh.me/plans.

  One card per tier with:
    * Name + monthly price + blurb (editable form)
    * Toggleable feature checkboxes (every feature atom known to
      the system shows up; checked = included in this tier)
    * Limits (services / block_templates / bookings_per_month /
      technicians, with -1 meaning unlimited)

  Toggling any feature or saving the form flushes
  `Plans.flush_cache/0` so subsequent tenant gate checks see the
  new state immediately.

  Audit-logged via `Platform.log_audit!/1` with
  `:platform_plan_updated` action.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadPlatformUserHook

  alias DrivewayOS.Plans
  alias DrivewayOS.Platform.Plan

  # Canonical list of every feature atom the codebase recognizes.
  # Editing this list adds new toggles to the UI; existing rows
  # keep their selections.
  @all_features [
    :basic_booking,
    :my_appointments,
    :admin_dashboard,
    :stripe_connect,
    :branding,
    :appointment_email_confirmations,
    :custom_domains,
    :saved_vehicles,
    :saved_addresses,
    :booking_photos,
    :sms_notifications,
    :push_notifications,
    :loyalty_punch_card,
    :multi_tech_dispatch,
    :route_optimization,
    :customer_subscriptions,
    :marketing_dashboard,
    :ai_photo_analysis,
    :api_access,
    :accounting_integrations,
    :sso,
    :priority_support
  ]

  @impl true
  def mount(_params, _session, socket) do
    cond do
      socket.assigns[:tenant_context] != :platform_admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_platform_user]) ->
        {:ok, push_navigate(socket, to: ~p"/platform-sign-in")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Plans")
         |> assign(:all_features, @all_features)
         |> load_plans()}
    end
  end

  @impl true
  def handle_event("save_plan", %{"tier" => tier_str, "plan" => params}, socket) do
    tier = String.to_existing_atom(tier_str)
    plan = Plans.plan_for(tier)

    attrs =
      %{
        name: params["name"],
        monthly_cents: parse_int(params["monthly_cents"]),
        blurb: params["blurb"],
        limit_services: parse_int(params["limit_services"]),
        limit_block_templates: parse_int(params["limit_block_templates"]),
        limit_bookings_per_month: parse_int(params["limit_bookings_per_month"]),
        limit_technicians: parse_int(params["limit_technicians"])
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    case plan
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(authorize?: false) do
      {:ok, _} ->
        Plans.flush_cache()
        log_audit(socket, plan, :saved, Map.keys(attrs))

        {:noreply,
         socket
         |> assign(:flash_msg, "#{plan.name} plan saved.")
         |> load_plans()}

      {:error, _} ->
        {:noreply, assign(socket, :flash_msg, "Could not save.")}
    end
  end

  def handle_event("toggle_feature", %{"tier" => tier_str, "feature" => feature_str}, socket) do
    tier = String.to_existing_atom(tier_str)
    plan = Plans.plan_for(tier)

    new_features =
      if feature_str in plan.features do
        List.delete(plan.features, feature_str)
      else
        [feature_str | plan.features] |> Enum.uniq()
      end

    case plan
         |> Ash.Changeset.for_update(:update, %{features: new_features})
         |> Ash.update(authorize?: false) do
      {:ok, _} ->
        Plans.flush_cache()
        log_audit(socket, plan, :feature_toggled, [feature_str])
        {:noreply, load_plans(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp load_plans(socket) do
    Plans.flush_cache()

    plans =
      Plan
      |> Ash.Query.for_read(:ordered)
      |> Ash.read!(authorize?: false)

    plans_by_tier = Map.new(plans, fn p -> {p.tier, p} end)

    socket
    |> assign(:plans, plans)
    |> assign(:plans_by_tier, plans_by_tier)
    |> assign_new(:flash_msg, fn -> nil end)
  end

  defp log_audit(socket, plan, kind, fields) do
    DrivewayOS.Platform.log_audit!(%{
      action: :platform_plan_updated,
      platform_user_id: socket.assigns.current_platform_user.id,
      target_type: "Plan",
      target_id: plan.id,
      payload: %{
        "tier" => Atom.to_string(plan.tier),
        "kind" => Atom.to_string(kind),
        "fields" => Enum.map(fields, &to_string/1)
      }
    })
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(_), do: nil

  defp tier_color(:starter), do: "border-base-300"
  defp tier_color(:pro), do: "border-primary"
  defp tier_color(:enterprise), do: "border-accent"
  defp tier_color(_), do: "border-base-300"

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-7xl mx-auto space-y-6">
        <header class="flex justify-between items-start flex-wrap gap-3">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Platform
            </p>
            <h1 class="text-3xl font-bold tracking-tight">Plans</h1>
            <p class="text-sm text-base-content/70 mt-1">
              Edit pricing, limits, and feature gates per tier. Changes apply immediately to every tenant on that tier.
            </p>
          </div>
          <nav class="flex gap-1 flex-wrap">
            <a href="/tenants" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-building-office-2 w-4 h-4" aria-hidden="true"></span> Tenants
            </a>
            <a href="/metrics" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-chart-bar w-4 h-4" aria-hidden="true"></span> Metrics
            </a>
            <a href="/plans" class="btn btn-primary btn-sm gap-1">
              <span class="hero-rectangle-stack w-4 h-4" aria-hidden="true"></span> Plans
            </a>
            <a href="/auth/platform/sign-out" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-arrow-left-on-rectangle w-4 h-4" aria-hidden="true"></span>
              Sign out
            </a>
          </nav>
        </header>

        <div :if={@flash_msg} role="alert" class="alert alert-success">
          <span class="hero-check-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@flash_msg}</span>
        </div>

        <section class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <article
            :for={plan <- @plans}
            class={"card bg-base-100 shadow-sm border-2 #{tier_color(plan.tier)}"}
          >
            <div class="card-body p-6 space-y-4">
              <div>
                <div class="flex items-baseline gap-2">
                  <h2 class="card-title text-2xl">{plan.name}</h2>
                  <span class="text-xs font-mono text-base-content/50">
                    {plan.tier}
                  </span>
                </div>
                <p class="text-3xl font-bold mt-1">
                  {fmt_price(plan.monthly_cents)}
                  <span class="text-sm font-normal text-base-content/60">/ mo</span>
                </p>
              </div>

              <form
                id={"plan-#{plan.tier}-form"}
                phx-submit="save_plan"
                phx-value-tier={plan.tier}
                class="space-y-3"
              >
                <div>
                  <label class="label" for={"plan-name-#{plan.tier}"}>
                    <span class="label-text font-medium text-xs uppercase tracking-wide">Name</span>
                  </label>
                  <input
                    id={"plan-name-#{plan.tier}"}
                    type="text"
                    name="plan[name]"
                    value={plan.name}
                    class="input input-bordered input-sm w-full"
                  />
                </div>
                <div>
                  <label class="label" for={"plan-price-#{plan.tier}"}>
                    <span class="label-text font-medium text-xs uppercase tracking-wide">
                      Monthly (cents)
                    </span>
                  </label>
                  <input
                    id={"plan-price-#{plan.tier}"}
                    type="number"
                    name="plan[monthly_cents]"
                    value={plan.monthly_cents}
                    min="0"
                    class="input input-bordered input-sm w-full"
                  />
                </div>
                <div>
                  <label class="label" for={"plan-blurb-#{plan.tier}"}>
                    <span class="label-text font-medium text-xs uppercase tracking-wide">Blurb</span>
                  </label>
                  <textarea
                    id={"plan-blurb-#{plan.tier}"}
                    name="plan[blurb]"
                    rows="2"
                    class="textarea textarea-bordered textarea-sm w-full"
                  >{plan.blurb}</textarea>
                </div>

                <div class="grid grid-cols-2 gap-2">
                  <div>
                    <label class="label py-1">
                      <span class="label-text font-medium text-xs">Services</span>
                    </label>
                    <input
                      type="number"
                      name="plan[limit_services]"
                      value={plan.limit_services}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <div>
                    <label class="label py-1">
                      <span class="label-text font-medium text-xs">Templates</span>
                    </label>
                    <input
                      type="number"
                      name="plan[limit_block_templates]"
                      value={plan.limit_block_templates}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <div>
                    <label class="label py-1">
                      <span class="label-text font-medium text-xs">Bookings/mo</span>
                    </label>
                    <input
                      type="number"
                      name="plan[limit_bookings_per_month]"
                      value={plan.limit_bookings_per_month}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <div>
                    <label class="label py-1">
                      <span class="label-text font-medium text-xs">Techs</span>
                    </label>
                    <input
                      type="number"
                      name="plan[limit_technicians]"
                      value={plan.limit_technicians}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                </div>
                <p class="text-xs text-base-content/50">
                  -1 = unlimited
                </p>

                <button type="submit" class="btn btn-primary btn-sm w-full gap-1">
                  <span class="hero-check w-4 h-4" aria-hidden="true"></span>
                  Save name / price / limits
                </button>
              </form>

              <div class="divider text-xs my-1">Features</div>

              <ul class="space-y-1.5">
                <li
                  :for={feature <- @all_features}
                  class="flex items-center justify-between gap-2"
                >
                  <span class="text-sm font-mono">{feature}</span>
                  <button
                    type="button"
                    phx-click="toggle_feature"
                    phx-value-tier={plan.tier}
                    phx-value-feature={Atom.to_string(feature)}
                    class={
                      if Atom.to_string(feature) in plan.features,
                        do: "btn btn-success btn-xs",
                        else: "btn btn-ghost btn-xs"
                    }
                    aria-pressed={Atom.to_string(feature) in plan.features}
                  >
                    <span
                      class={
                        if Atom.to_string(feature) in plan.features,
                          do: "hero-check w-3 h-3",
                          else: "hero-plus w-3 h-3"
                      }
                      aria-hidden="true"
                    ></span>
                    {if Atom.to_string(feature) in plan.features, do: "Included", else: "Add"}
                  </button>
                </li>
              </ul>
            </div>
          </article>
        </section>
      </div>
    </main>
    """
  end
end
