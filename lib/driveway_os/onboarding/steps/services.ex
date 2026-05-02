defmodule DrivewayOS.Onboarding.Steps.Services do
  @moduledoc """
  Services wizard step. The tenant ships with two seeded services
  (Basic Wash, Deep Clean); this step prompts them to rename, reprice,
  or replace them with their actual menu.

  The wizard step itself is a thin redirect to /admin/services where
  the full CRUD UI already lives — re-implementing service CRUD
  inline would duplicate complex UX. The wizard owner returns to
  /admin/onboarding when ready (browser back, or via the dashboard
  link).

  `complete?/1` mirrors the `using_default_services?/1` predicate
  the dashboard already uses: false when the tenant still has the
  literal seeded slug set; true once any seeded service is renamed
  or a new service is added.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

  @impl true
  def id, do: :services

  @impl true
  def title, do: "Set your service menu"

  @impl true
  def complete?(%Tenant{} = tenant) do
    {:ok, services} =
      ServiceType
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

    slugs = services |> Enum.map(& &1.slug) |> Enum.sort()
    slugs != ["basic-wash", "deep-clean"]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">
        Your shop ships with two starter services. Rename or replace them with
        what you actually offer — pricing, duration, descriptions all live there.
      </p>
      <a href="/admin/services" class="btn btn-primary btn-sm gap-1">
        Open service editor
        <span class="hero-arrow-top-right-on-square w-3 h-3" aria-hidden="true"></span>
      </a>
      <p class="text-xs text-base-content/60">
        We'll bring you back here when you're done.
      </p>
    </div>
    """
  end

  @impl true
  def submit(_params, socket) do
    # No inline form for this step — operator returns from /admin/services
    # via browser back. The wizard re-checks complete?/1 on every render.
    {:ok, socket}
  end
end
