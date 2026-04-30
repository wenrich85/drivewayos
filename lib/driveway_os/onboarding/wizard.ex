defmodule DrivewayOS.Onboarding.Wizard do
  @moduledoc """
  Pure-function FSM helpers for the onboarding wizard at
  /admin/onboarding.

  The wizard walks five mandatory-linear steps. Each step is an
  `Onboarding.Step` implementation. State lives in
  `tenant.wizard_progress` (a jsonb map keyed by step id), but only
  `:skipped` flags are persisted — `:done` is computed via the
  step's own `complete?/1` predicate.

  This module is data-in / data-out — no GenServer, no compile-time
  registry beyond a module attribute, no side effects except the
  Ash update calls in `skip/2` and `unskip/2`. The default step
  list can be overridden via the second arg on `current_step/2` and
  `complete?/2` to make testing trivial.
  """

  alias DrivewayOS.Platform.Tenant

  @steps [
    DrivewayOS.Onboarding.Steps.Branding,
    DrivewayOS.Onboarding.Steps.Services,
    DrivewayOS.Onboarding.Steps.Schedule,
    DrivewayOS.Onboarding.Steps.Payment,
    DrivewayOS.Onboarding.Steps.Email
  ]

  @doc "Canonical wizard step list, in declaration order."
  @spec steps() :: [module()]
  def steps, do: @steps

  @doc """
  First step that's not complete? AND not skipped, walking
  the step list in order. Returns nil when every step is in a
  terminal state (complete or skipped) — the wizard caller treats
  nil as "wizard is done, redirect to /admin".
  """
  @spec current_step(map(), [module()]) :: module() | nil
  def current_step(tenant, steps \\ steps()) do
    Enum.find(steps, fn step ->
      not step.complete?(tenant) and not skipped?(tenant, step.id())
    end)
  end

  @doc """
  True when every step is either complete or skipped. False if any
  step is still pending. Empty step list returns true (vacuously).
  """
  @spec complete?(map(), [module()]) :: boolean()
  def complete?(tenant, steps \\ steps()) do
    Enum.all?(steps, fn step ->
      step.complete?(tenant) or skipped?(tenant, step.id())
    end)
  end

  @doc "Whether the given step id is marked :skipped in wizard_progress."
  @spec skipped?(map(), atom()) :: boolean()
  def skipped?(%{wizard_progress: progress}, step_id) when is_atom(step_id) do
    Map.get(progress || %{}, to_string(step_id)) == "skipped"
  end

  def skipped?(_, _), do: false

  @doc """
  Persist `step_id` as :skipped in the tenant's wizard_progress.
  Returns `{:ok, updated_tenant}` or `{:error, _}`.
  """
  @spec skip(Tenant.t(), atom()) :: {:ok, Tenant.t()} | {:error, term()}
  def skip(%Tenant{} = tenant, step_id) when is_atom(step_id) do
    tenant
    |> Ash.Changeset.for_update(:set_wizard_progress, %{step: step_id, status: :skipped})
    |> Ash.update(authorize?: false)
  end

  @doc """
  Remove the skip flag for `step_id` from wizard_progress (i.e.
  un-skip it; the step becomes pending again).
  """
  @spec unskip(Tenant.t(), atom()) :: {:ok, Tenant.t()} | {:error, term()}
  def unskip(%Tenant{} = tenant, step_id) when is_atom(step_id) do
    tenant
    |> Ash.Changeset.for_update(:set_wizard_progress, %{step: step_id, status: :pending})
    |> Ash.update(authorize?: false)
  end
end
