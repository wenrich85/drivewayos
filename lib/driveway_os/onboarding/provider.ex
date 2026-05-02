defmodule DrivewayOS.Onboarding.Provider do
  @moduledoc """
  Behaviour every onboarding-integration provider implements.

  A "provider" here is an external service (Stripe, Postmark, Square,
  etc.) that a tenant can connect during onboarding. The behaviour
  is intentionally minimal — eight callbacks (six required, two
  optional) that together let the wizard render a card for each
  provider, decide whether it's configured at the platform level,
  decide whether THIS tenant has finished connecting it, and
  optionally surface affiliate / referral metadata + tenant-facing
  perk copy.

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

  @doc """
  Provision the integration for `tenant`. API-first providers do
  the actual external setup here (POST to the provider's API,
  store credentials on the tenant, send any verification email).
  Hosted-redirect providers return `{:error, :hosted_required}` —
  the wizard then routes the operator to `display.href` instead.

  Args is a per-provider map (e.g. for an API-first provider that
  needs a tenant-supplied display name). For hosted-redirect
  providers, the args map is ignored.

  Returns:
    * `{:ok, updated_tenant}` — provisioning succeeded; persist + advance
    * `{:error, :hosted_required}` — caller should fall back to display.href
    * `{:error, term}` — provisioning failed; surface to the operator
  """
  @callback provision(Tenant.t(), map()) ::
              {:ok, Tenant.t()} | {:error, :hosted_required | term()}

  @typedoc "Affiliate config — query-param name + ref id, or nil when no program."
  @type affiliate_config :: %{ref_param: String.t(), ref_id: String.t() | nil} | nil

  @doc """
  Affiliate / referral configuration for this provider, or nil if
  none. Shape: `%{ref_param: <query-param-name>, ref_id: <ref-value>}`.

  When the returned map's `ref_id` is `nil` (env var unset) or this
  callback returns `nil`, `Onboarding.Affiliate.tag_url/2` is a
  passthrough.

  Implementations typically read the ref_id from app config so it
  can be set per-environment via env vars without redeploying:

      def affiliate_config do
        %{
          ref_param: "ref",
          ref_id: Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
        }
      end
  """
  @callback affiliate_config() :: affiliate_config()

  @doc """
  Visible-to-tenant perk copy, or `nil` if no perk is offered. The
  wizard card renders the string below the provider's blurb when
  non-nil.

  Static text only — perk copy is marketing copy, not a credential,
  so it lives hardcoded in the provider module rather than env-var
  indirection.
  """
  @callback tenant_perk() :: String.t() | nil

  @optional_callbacks affiliate_config: 0, tenant_perk: 0
end
