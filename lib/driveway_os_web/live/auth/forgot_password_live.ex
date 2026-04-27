defmodule DrivewayOSWeb.Auth.ForgotPasswordLive do
  @moduledoc """
  Forgot-password kickoff. Customer types their email; we always
  show the same "if that email exists, a link is on the way"
  message regardless of whether the address matched a row, so an
  attacker can't enumerate accounts.

  AshAuth's `request_password_reset_with_password` action does the
  heavy lifting — token mint + Sender invocation. We just feed it
  the email under the current tenant.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook

  alias DrivewayOS.Accounts.Customer

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_tenant] do
      {:ok,
       socket
       |> assign(:page_title, "Reset password")
       |> assign(:sent?, false)}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("submit", %{"forgot" => %{"email" => email}}, socket) do
    tenant = socket.assigns.current_tenant
    normalized = email |> to_string() |> String.trim() |> String.downcase()
    rl_key = "forgot:#{tenant.id}:#{normalized}"

    # Rate-limit before doing the work. We always render the
    # success state visibly so this doesn't become an enumeration
    # oracle ('I see "rate limited" → email exists') — limiter
    # decision happens silently.
    case DrivewayOS.RateLimiter.check(rl_key, 3, 60 * 60 * 1000) do
      :ok ->
        _ =
          Customer
          |> Ash.Query.for_read(:request_password_reset_with_password, %{email: normalized},
            tenant: tenant.id
          )
          |> Ash.read(authorize?: false)

      {:error, :rate_limited, _} ->
        :ok
    end

    {:noreply, assign(socket, :sent?, true)}
  rescue
    _ -> {:noreply, assign(socket, :sent?, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center bg-base-200 px-4 py-12">
      <div class="card w-full max-w-md bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-2xl">Reset your password</h1>

          <%= if @sent? do %>
            <div class="alert alert-success mt-2">
              <span class="hero-check-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
              <div class="text-sm">
                If that email is on file with {@current_tenant.display_name}, a reset
                link is on its way. Check your inbox in a minute or two.
              </div>
            </div>
            <div class="text-sm text-base-content/60 mt-3">
              <.link navigate={~p"/sign-in"} class="link">Back to sign in</.link>
            </div>
          <% else %>
            <p class="text-base-content/70 text-sm mb-2">
              Enter the email you signed up with. We'll send you a link to set a new
              password — works whether or not you remember the old one.
            </p>

            <form id="forgot-password-form" phx-submit="submit" class="space-y-4">
              <div>
                <label class="label" for="forgot-email">
                  <span class="label-text font-medium">Email</span>
                </label>
                <input
                  id="forgot-email"
                  type="email"
                  name="forgot[email]"
                  class="input input-bordered w-full"
                  required
                  autocomplete="email"
                  autofocus
                />
              </div>

              <button type="submit" class="btn btn-primary w-full">
                Send reset link
              </button>

              <div class="text-sm text-center text-base-content/60">
                <.link navigate={~p"/sign-in"} class="link link-hover">Back to sign in</.link>
              </div>
            </form>
          <% end %>
        </div>
      </div>
    </main>
    """
  end
end
