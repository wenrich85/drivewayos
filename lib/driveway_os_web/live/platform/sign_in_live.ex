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
      <div class="card w-full max-w-md bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-2xl">Platform sign in</h1>
          <p class="text-base-content/70 mb-2">DrivewayOS operators only.</p>

          <div :if={@error} class="alert alert-error text-sm">{@error}</div>

          <form id="platform-signin-form" phx-submit="submit" class="space-y-4">
            <div>
              <label class="label" for="psi-email"><span class="label-text">Email</span></label>
              <input
                id="psi-email"
                type="email"
                name="signin[email]"
                value={@form_email}
                class="input input-bordered w-full"
                required
              />
            </div>

            <div>
              <label class="label" for="psi-password">
                <span class="label-text">Password</span>
              </label>
              <input
                id="psi-password"
                type="password"
                name="signin[password]"
                class="input input-bordered w-full"
                required
              />
            </div>

            <button type="submit" class="btn btn-primary w-full">Sign in</button>
          </form>
        </div>
      </div>
    </main>
    """
  end
end
