defmodule DrivewayOSWeb.Platform.SignInLive do
  @moduledoc """
  Platform-admin sign-in form at `admin.lvh.me/`. Authenticates a
  PlatformUser (us, the SaaS operator); on success redirects through
  Platform.SessionController to write the platform_token into the
  session, then lands on /tenants.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadPlatformUserHook

  alias DrivewayOS.Platform.PlatformUser

  @impl true
  def mount(_params, _session, socket) do
    cond do
      socket.assigns[:tenant_context] != :platform_admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      socket.assigns[:current_platform_user] ->
        {:ok, push_navigate(socket, to: ~p"/tenants")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Platform sign in")
         |> assign(:form_email, "")
         |> assign(:error, nil)}
    end
  end

  @impl true
  def handle_event("submit", %{"signin" => %{"email" => email, "password" => password}}, socket) do
    case PlatformUser
         |> Ash.Query.for_read(
           :sign_in_with_password,
           %{email: email, password: password}
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %{__metadata__: %{token: token}}} ->
        {:noreply, redirect(socket, to: ~p"/auth/platform/store-token?token=#{token}")}

      _ ->
        {:noreply,
         socket
         |> assign(:error, "Invalid email or password.")
         |> assign(:form_email, email)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center bg-base-200 px-4 py-12">
      <div class="w-full max-w-md space-y-6">
        <header class="text-center space-y-2">
          <span class="inline-flex items-center gap-2 rounded-full bg-primary/10 text-primary px-3 py-1 text-xs font-semibold uppercase tracking-wide">
            <span class="hero-shield-check w-4 h-4" aria-hidden="true"></span> Platform
          </span>
          <h1 class="text-3xl font-bold tracking-tight">DrivewayOS operators</h1>
          <p class="text-sm text-base-content/70">
            Sign in to manage tenants, suspend accounts, and inspect cross-tenant metrics.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-4">
            <div :if={@error} role="alert" class="alert alert-error">
              <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
              <span class="text-sm">{@error}</span>
            </div>

            <form id="platform-signin-form" phx-submit="submit" class="space-y-4">
              <div>
                <label class="label" for="psi-email">
                  <span class="label-text font-medium">Email</span>
                </label>
                <input
                  id="psi-email"
                  type="email"
                  name="signin[email]"
                  value={@form_email}
                  autocomplete="email"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <div>
                <label class="label" for="psi-password">
                  <span class="label-text font-medium">Password</span>
                </label>
                <input
                  id="psi-password"
                  type="password"
                  name="signin[password]"
                  autocomplete="current-password"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <button type="submit" class="btn btn-primary w-full gap-2">
                <span class="hero-arrow-right-on-rectangle w-5 h-5" aria-hidden="true"></span>
                Sign in
              </button>
            </form>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
