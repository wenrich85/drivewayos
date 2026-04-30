defmodule DrivewayOS.Onboarding.Step do
  @moduledoc """
  Behaviour every onboarding-wizard step implements.

  A step is one slice of the linear-required wizard at
  /admin/onboarding (Branding, Services, Schedule, Payment, Email).
  Each step owns its own form rendering and submit handling, and
  exposes a `complete?(tenant)` predicate that the wizard FSM uses
  to decide whether to skip past it.

  Done-ness is always computed from real state via `complete?/1` —
  never stored. Skip flags live in `tenant.wizard_progress` and are
  managed by `DrivewayOS.Onboarding.Wizard.skip/2`.

  See also: `DrivewayOS.Onboarding.Wizard` for the FSM helpers,
  and the spec at
  `docs/superpowers/specs/2026-04-29-tenant-onboarding-phase-1-design.md`.
  """

  alias DrivewayOS.Platform.Tenant

  @doc "Stable identifier (e.g. `:branding`). Used as the key in `wizard_progress`."
  @callback id() :: atom()

  @doc "Human-readable title rendered as the step heading (e.g. \"Make it yours\")."
  @callback title() :: String.t()

  @doc """
  True when this tenant has fulfilled this step's requirements based
  on real state (e.g. `not is_nil(tenant.support_email)` for Branding).
  Never reads `wizard_progress` — that's the wizard's concern, not the
  step's.
  """
  @callback complete?(Tenant.t()) :: boolean()

  @doc """
  Renders the step's form/UI inside the wizard layout. Receives
  socket assigns (current_tenant, current_customer, errors, etc.)
  and returns rendered HEEx.
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Handles the step's primary form submit. Returns:

    * `{:ok, socket}` — step succeeded; wizard advances.
    * `{:error, term}` — step failed; wizard stays on this step,
      surfaces the error.

  May write to the tenant or to provider-specific external services.
  """
  @callback submit(params :: map(), socket :: Phoenix.LiveView.Socket.t())
              :: {:ok, Phoenix.LiveView.Socket.t()} | {:error, term()}
end
