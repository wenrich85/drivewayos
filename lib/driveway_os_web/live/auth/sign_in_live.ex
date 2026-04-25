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
       |> assign(:error, nil)}
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
      <div class="card w-full max-w-md bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-2xl">Sign in</h1>
          <p class="text-base-content/70 mb-2">
            Welcome back to {@current_tenant.display_name}.
          </p>

          <div :if={@error} class="alert alert-error text-sm">{@error}</div>

          <form id="sign-in-form" phx-submit="submit" class="space-y-4">
            <div>
              <label class="label" for="signin-email">
                <span class="label-text">Email</span>
              </label>
              <input
                id="signin-email"
                type="email"
                name="signin[email]"
                value={@form_email}
                class="input input-bordered w-full"
                required
              />
            </div>

            <div>
              <label class="label" for="signin-password">
                <span class="label-text">Password</span>
              </label>
              <input
                id="signin-password"
                type="password"
                name="signin[password]"
                class="input input-bordered w-full"
                required
              />
            </div>

            <button type="submit" class="btn btn-primary w-full">Sign in</button>
          </form>

          <div class="divider text-xs">or continue with</div>

          <div class="space-y-2">
            <a href="/auth/customer/google" class="btn btn-outline w-full">Google</a>
            <a href="/auth/customer/facebook" class="btn btn-outline w-full">Facebook</a>
            <a href="/auth/customer/apple" class="btn btn-outline w-full">Apple</a>
          </div>

          <%!-- Customer self-registration form lands in a follow-up
               slice. For now, OAuth providers above (when configured)
               handle new-user signup as a side effect of first sign-in
               via the `:register_with_*` upserting actions. --%>
        </div>
      </div>
    </main>
    """
  end
end
