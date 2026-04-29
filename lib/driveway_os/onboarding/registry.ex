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
    * `DrivewayOSWeb.Admin.OnboardingWizardLive` — renders one
      section per category from `by_category/1`.
  """

  alias DrivewayOS.Platform.Tenant

  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect
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
end
