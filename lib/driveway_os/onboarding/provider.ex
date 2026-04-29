defmodule DrivewayOS.Onboarding.Provider do
  @moduledoc """
  Behaviour every onboarding-integration provider implements.

  A "provider" here is an external service (Stripe, Postmark, Square,
  etc.) that a tenant can connect during onboarding. The behaviour
  is intentionally minimal — five callbacks that together let the
  wizard render a card for each provider, decide whether it's
  configured at the platform level, and decide whether THIS tenant
  has finished connecting it.

  See also: `DrivewayOS.Onboarding.Registry` for the canonical list
  of providers, and `docs/superpowers/specs/2026-04-28-tenant-onboarding-roadmap.md`
  for why the abstraction exists.
  """

  alias DrivewayOS.Platform.Tenant

  @typedoc "Logical category — :payment, :email, :accounting, etc."
  @type category :: atom()

  @typedoc "Static display config rendered as a checklist / wizard card."
  @type display :: %{
          required(:title) => String.t(),
          required(:blurb) => String.t(),
          required(:cta_label) => String.t(),
          required(:href) => String.t()
        }

  @doc """
  Stable identifier (e.g. `:stripe_connect`). Used in Phase 1 as
  the map key for per-tenant wizard progress persistence — has no
  runtime call site in Phase 0 but is load-bearing for the next
  phase. Don't remove during dead-code cleanup passes.
  """
  @callback id() :: atom()

  @doc "Logical category this provider belongs to."
  @callback category() :: category()

  @doc "Title / blurb / CTA copy + the URL the CTA points at."
  @callback display() :: display()

  @doc """
  True when the platform has the credentials needed to drive this
  provider (e.g. `STRIPE_CLIENT_ID` is set). False when the
  integration is dormant on this server — the wizard hides such
  providers entirely rather than offering a dead-end CTA.
  """
  @callback configured?() :: boolean()

  @doc """
  True when the given tenant has finished connecting this provider
  (e.g. has a `stripe_account_id`). The wizard / dashboard
  checklist hides the row when this returns true.
  """
  @callback setup_complete?(Tenant.t()) :: boolean()
end
