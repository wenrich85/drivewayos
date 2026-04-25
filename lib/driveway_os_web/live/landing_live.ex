defmodule DrivewayOSWeb.LandingLive do
  @moduledoc """
  Single landing route that branches on `tenant_context`:

    * `:marketing` (no subdomain or `www.`) — DrivewayOS product
      marketing.
    * `:tenant` ({slug}.{platform_host}) — the tenant's customer-
      facing welcome page.

  Both modes share the same LV process; render/1 picks the right
  template based on `assigns.current_tenant`. Keeps routing simple
  (one path, one process) at the cost of one branch in render.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(%{current_tenant: nil} = assigns), do: marketing(assigns)
  def render(%{current_tenant: %{}} = assigns), do: tenant(assigns)

  defp marketing(assigns) do
    ~H"""
    <main class="min-h-screen flex flex-col items-center justify-center bg-base-200 px-4">
      <div class="max-w-3xl text-center space-y-6">
        <h1 class="text-5xl font-bold text-primary">DrivewayOS</h1>
        <p class="text-xl text-base-content/70">
          The operating system for mobile detail shops. One platform,
          many shops, each with their own brand.
        </p>
        <div class="flex justify-center gap-3">
          <a href="/signup" class="btn btn-primary">Start your shop</a>
          <a href="#features" class="btn btn-ghost">Learn more</a>
        </div>
        <p class="text-sm text-base-content/50">
          Coming soon — currently in private development.
        </p>
      </div>
    </main>
    """
  end

  defp tenant(assigns) do
    ~H"""
    <main
      class="min-h-screen flex flex-col items-center justify-center px-4"
      style={"--tenant-color: ##{primary_color(@current_tenant)};"}
      data-primary-color={"#" <> primary_color(@current_tenant)}
    >
      <div class="max-w-3xl text-center space-y-6">
        <img
          :if={@current_tenant.logo_url}
          src={@current_tenant.logo_url}
          alt={@current_tenant.display_name}
          class="mx-auto h-20 w-auto"
        />
        <h1
          class="text-5xl font-bold"
          style="color: var(--tenant-color);"
        >
          {@current_tenant.display_name}
        </h1>
        <p class="text-xl text-base-content/70">
          Mobile detailing at your door. Book a wash in minutes.
        </p>
        <div class="flex justify-center gap-3">
          <a
            href="/book"
            class="btn"
            style="background-color: var(--tenant-color); color: white;"
          >
            Book a wash
          </a>
          <a href="/sign-in" class="btn btn-ghost">Sign in</a>
        </div>
      </div>
    </main>
    """
  end

  defp primary_color(%{primary_color_hex: nil}), do: "1E2A38"
  defp primary_color(%{primary_color_hex: "#" <> hex}), do: hex
  defp primary_color(%{primary_color_hex: hex}) when is_binary(hex), do: hex
  defp primary_color(_), do: "1E2A38"
end
