defmodule DrivewayOSWeb.Auth.SignInLive do
  @moduledoc """
  Customer sign-in form. Always tenant-scoped — the form is mounted
  on `{slug}.lvh.me/sign-in`, so the current tenant is locked in by
  the `LoadTenant` plug + on_mount hook before this LV runs.

  Hitting `/sign-in` on the marketing host (no tenant in scope)
  bounces back to `/` — there's no tenant to sign into there.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook

  alias DrivewayOS.Accounts.Customer

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_tenant] do
      {:ok,
       socket
       |> assign(:page_title, "Sign in")
       |> assign(:form_email, "")
       |> assign(:error, nil)
       |> assign(:oauth_providers, DrivewayOS.Accounts.configured_oauth_providers())}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("submit", %{"signin" => %{"email" => email, "password" => password}}, socket) do
    tenant = socket.assigns.current_tenant

    case Customer
         |> Ash.Query.for_read(
           :sign_in_with_password,
           %{email: email, password: password},
           tenant: tenant.id
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, %{__metadata__: %{token: token}}} ->
        # LV can't write to session directly; bounce through the
        # session controller which puts the token in session and
        # redirects to the customer landing.
        {:noreply, redirect(socket, to: ~p"/auth/customer/store-token?token=#{token}")}

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
          <h1 class="text-3xl font-bold tracking-tight">Sign in</h1>
          <p class="text-sm text-base-content/70">
            Welcome back to <span class="font-semibold">{@current_tenant.display_name}</span>.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-4">
            <div :if={@error} role="alert" class="alert alert-error">
              <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
              <span class="text-sm">{@error}</span>
            </div>

            <form id="sign-in-form" phx-submit="submit" class="space-y-4">
              <div>
                <label class="label" for="signin-email">
                  <span class="label-text font-medium">Email</span>
                </label>
                <input
                  id="signin-email"
                  type="email"
                  name="signin[email]"
                  value={@form_email}
                  autocomplete="email"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <div>
                <label class="label" for="signin-password">
                  <span class="label-text font-medium">Password</span>
                </label>
                <input
                  id="signin-password"
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

            <div class="divider text-xs my-2">or</div>

            <a href="/magic-link" class="btn btn-ghost w-full gap-2">
              <span class="hero-envelope w-5 h-5" aria-hidden="true"></span>
              Email me a sign-in link
            </a>

            <%!-- OAuth providers — only the ones with valid env-var
                 credentials render. Empty list → no third "or
                 continue with" divider, no dead buttons. --%>
            <%= if @oauth_providers != [] do %>
              <div class="divider text-xs my-2">or continue with</div>

              <div class={"grid gap-2 grid-cols-#{length(@oauth_providers)}"}>
                <a
                  :if={:google in @oauth_providers}
                  href="/auth/customer/google"
                  class="btn btn-outline btn-sm gap-1"
                  aria-label="Sign in with Google"
                >
                  <span class="hero-globe-alt w-4 h-4" aria-hidden="true"></span> Google
                </a>
                <a
                  :if={:facebook in @oauth_providers}
                  href="/auth/customer/facebook"
                  class="btn btn-outline btn-sm"
                  aria-label="Sign in with Facebook"
                >
                  Facebook
                </a>
                <a
                  :if={:apple in @oauth_providers}
                  href="/auth/customer/apple"
                  class="btn btn-outline btn-sm"
                  aria-label="Sign in with Apple"
                >
                  Apple
                </a>
              </div>
            <% end %>
          </div>
        </section>

        <p class="text-center text-sm text-base-content/60">
          Don't have an account yet?
          <a href="/register" class="link link-primary font-medium">Create one</a>
        </p>
      </div>
    </main>
    """
  end
end
