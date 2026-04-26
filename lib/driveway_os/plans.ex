defmodule DrivewayOS.Plans do
  @moduledoc """
  SaaS-tier feature gating. Each tenant has `plan_tier`
  (:starter | :pro | :enterprise); every gateable feature in the
  app guards itself with `Plans.tenant_can?/2`.

  Plan definitions live in the database as `Platform.Plan` rows so
  a platform admin can edit them from `admin.<host>/plans` without
  a code deploy. This module is a thin wrapper over those rows
  with a process-dictionary cache (cleared on plan edits via the
  `Plans.flush_cache/0` call inside the platform-admin LV).

  ## Adding a new feature gate

  1. Decide which tier(s) get it.
  2. Edit the Plan rows from `admin.<host>/plans` to add the
     feature atom (as a string) to the right tiers' features list.
  3. Reference it in your code:
     `if Plans.tenant_can?(socket.assigns.current_tenant, :feature),
       do: ..., else: render_upgrade_prompt(...)`

  ## Defaults

  Tenants with `plan_tier: nil` default to `:pro` for
  backwards-compatibility — existing tenants pre-Phase-D billing
  shouldn't have features yanked when the gating goes live.

  Calls with a `nil` tenant return `false` (fail-closed).
  """

  alias DrivewayOS.Platform.Plan

  require Ash.Query

  @default_tier :pro
  @cache_key {__MODULE__, :plan_cache}

  @doc """
  The canonical "can this tenant use feature X right now?" check.
  Returns `false` for nil tenant, unknown tier, unknown feature.
  """
  @spec tenant_can?(map() | nil, atom()) :: boolean()
  def tenant_can?(nil, _feature), do: false

  def tenant_can?(%{plan_tier: tier}, feature) when is_atom(feature) do
    case plan_for(tier || @default_tier) do
      %{features: features} -> Atom.to_string(feature) in features
      _ -> false
    end
  end

  def tenant_can?(_, _), do: false

  @doc """
  The Plan row for a given tier atom, or nil. Cached at process
  level — a single LV mount or controller request hits the DB
  at most once per tier checked.
  """
  @spec plan_for(atom()) :: Plan.t() | nil
  def plan_for(tier) when is_atom(tier) do
    cache = Process.get(@cache_key, %{})

    case Map.fetch(cache, tier) do
      {:ok, plan} ->
        plan

      :error ->
        plan = load_plan(tier)
        Process.put(@cache_key, Map.put(cache, tier, plan))
        plan
    end
  end

  def plan_for(_), do: nil

  defp load_plan(tier) do
    case Plan
         |> Ash.Query.for_read(:for_tier, %{tier: tier})
         |> Ash.read(authorize?: false) do
      {:ok, [plan | _]} -> plan
      _ -> nil
    end
  end

  @doc """
  Returns the tier atom for a tenant, defaulting to `:pro` when
  `plan_tier` is nil. Returns nil only for nil tenant.
  """
  @spec tier_for(map() | nil) :: atom() | nil
  def tier_for(nil), do: nil
  def tier_for(%{plan_tier: nil}), do: @default_tier
  def tier_for(%{plan_tier: tier}), do: tier

  @doc """
  All plans in display order (sort_order asc, then by monthly_cents).
  """
  @spec all_plans() :: [Plan.t()]
  def all_plans do
    case Plan
         |> Ash.Query.for_read(:ordered)
         |> Ash.read(authorize?: false) do
      {:ok, plans} -> plans
      _ -> []
    end
  end

  @doc """
  Get a numeric limit for a tenant. `-1` = unlimited.
  Limit keys: :services / :block_templates / :bookings_per_month / :technicians.
  """
  @spec limit(map() | nil, atom()) :: integer() | nil
  def limit(tenant, key) when is_atom(key) do
    field = String.to_existing_atom("limit_#{key}")

    case plan_for(tier_for(tenant)) do
      %Plan{} = p -> Map.get(p, field)
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  The next tier above the given one, or nil at the top. Used to
  render "Upgrade to {next}" CTAs from gated UI.
  """
  @spec next_tier(atom()) :: atom() | nil
  def next_tier(:starter), do: :pro
  def next_tier(:pro), do: :enterprise
  def next_tier(:enterprise), do: nil
  def next_tier(_), do: nil

  @doc """
  Drop the per-process plan cache. Call this inside any handler
  that updates a Plan row so subsequent checks see the new state.
  """
  @spec flush_cache() :: :ok
  def flush_cache do
    Process.delete(@cache_key)
    :ok
  end
end
