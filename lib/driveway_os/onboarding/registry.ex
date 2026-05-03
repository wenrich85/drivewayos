defmodule DrivewayOS.Onboarding.Registry do
  @moduledoc """
  Canonical list of onboarding providers + helpers for querying them.

  The list is a module attribute rather than runtime config because
  every supported provider lives in this codebase — there's no
  tenant-supplied or runtime-discovered set. New providers land via
  PR (add the module here + add the implementation file).

  Consumers:
    * `DrivewayOSWeb.Admin.DashboardLive` — composes the dashboard
      checklist from `needing_setup/1`.
    * `DrivewayOSWeb.Admin.OnboardingWizardLive` — calls
      `needing_setup/1` then groups locally for the per-category
      render.

  `by_category/1` has no Phase 0 consumer; it's reserved for
  Phase 1 wizard routing (per-category step LVs).
  """

  alias DrivewayOS.Platform.Tenant

  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect,
    DrivewayOS.Onboarding.Providers.Postmark,
    DrivewayOS.Onboarding.Providers.ZohoBooks,
    DrivewayOS.Onboarding.Providers.Square,
    DrivewayOS.Onboarding.Providers.Resend
  ]

  @doc "All registered providers, in declaration order."
  @spec all() :: [module()]
  def all, do: @providers

  @doc "Providers whose `category/0` matches `cat`."
  @spec by_category(atom()) :: [module()]
  def by_category(cat) when is_atom(cat) do
    Enum.filter(@providers, &(&1.category() == cat))
  end

  @doc """
  Providers the given tenant should still be prompted to set up.
  Filters by both `configured?/0` (don't surface dead-end CTAs for
  providers the platform itself isn't configured for) and
  `setup_complete?/1` (don't keep nagging once they've connected).
  """
  @spec needing_setup(Tenant.t()) :: [module()]
  def needing_setup(%Tenant{} = tenant) do
    @providers
    |> Enum.filter(& &1.configured?())
    |> Enum.reject(& &1.setup_complete?(tenant))
  end

  @doc """
  Look up a provider module by its `id/0` value. Returns
  `{:ok, module}` or `:error`. Used by `Onboarding.Affiliate` to
  resolve provider id atoms to their implementations without
  exposing the `@providers` list directly.
  """
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch(provider_id) when is_atom(provider_id) do
    case Enum.find(@providers, &(&1.id() == provider_id)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end
end
