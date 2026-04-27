defmodule DrivewayOSWeb.Auth.ResetPasswordLive do
  @moduledoc """
  Customer lands here from the reset-link email. The token in the
  URL is a single-use AshAuth reset token. They type a new
  password (twice); on success we mint a fresh customer JWT and
  redirect through `/auth/customer/store-token` so they're signed
  in immediately.

  Bad/expired token: AshAuth's
  `password_reset_with_password` returns an error. We render a
  generic "this link doesn't work or has expired" page with a
  CTA back to `/forgot-password`.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook

  alias DrivewayOS.Accounts.Customer

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if socket.assigns[:current_tenant] do
      {:ok,
       socket
       |> assign(:page_title, "Set a new password")
       |> assign(:reset_token, token)
       |> assign(:errors, %{})}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event(
        "submit",
        %{"reset" => %{"password" => pw, "password_confirmation" => pwc}},
        socket
      ) do
    tenant = socket.assigns.current_tenant

    # The :password_reset_with_password action is an `:update`
    # whose `reset_token` argument identifies the row. Use the
    # strategy-level helper which decodes the JWT, fetches the
    # user, runs the update, and revokes the token in one shot.
    {:ok, strategy} = AshAuthentication.Info.strategy(Customer, :password)

    case AshAuthentication.Strategy.action(
           strategy,
           :reset,
           %{
             "reset_token" => socket.assigns.reset_token,
             "password" => pw,
             "password_confirmation" => pwc
           },
           tenant: tenant.id
         ) do
      {:ok, %{__metadata__: %{token: jwt}}} ->
        encoded = URI.encode_www_form(jwt)
        return_to = URI.encode_www_form("/")

        {:noreply,
         redirect(socket,
           to: ~p"/auth/customer/store-token?token=#{encoded}&return_to=#{return_to}"
         )}

      {:ok, _} ->
        {:noreply, push_navigate(socket, to: ~p"/sign-in")}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        {:noreply, assign(socket, :errors, errors_to_map(errors))}

      _ ->
        {:noreply, assign(socket, :errors, %{base: "This reset link is invalid or expired."})}
    end
  end

  defp errors_to_map(errors) do
    Enum.reduce(errors, %{}, fn err, acc ->
      field = Map.get(err, :field) || :base
      message = Map.get(err, :message) || inspect(err)
      Map.put(acc, field, message)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center bg-base-200 px-4 py-12">
      <div class="card w-full max-w-md bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-2xl">Set a new password</h1>

          <div :if={@errors[:base]} class="alert alert-error mt-2 text-sm">
            <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
            <div class="flex-1">
              <p>{@errors[:base]}</p>
              <p class="text-xs mt-1">
                <.link navigate={~p"/forgot-password"} class="link">
                  Request a fresh link
                </.link>
              </p>
            </div>
          </div>

          <form id="reset-password-form" phx-submit="submit" class="space-y-4 mt-2">
            <div>
              <label class="label" for="reset-password">
                <span class="label-text font-medium">New password</span>
              </label>
              <input
                id="reset-password"
                type="password"
                name="reset[password]"
                class="input input-bordered w-full"
                required
                minlength="10"
                autocomplete="new-password"
                autofocus
              />
              <p :if={@errors[:password]} class="text-error text-xs mt-1">
                {@errors[:password]}
              </p>
              <p class="text-xs text-base-content/60 mt-1">
                Min 10 chars · upper, lower, and a number.
              </p>
            </div>
            <div>
              <label class="label" for="reset-confirm">
                <span class="label-text font-medium">Confirm password</span>
              </label>
              <input
                id="reset-confirm"
                type="password"
                name="reset[password_confirmation]"
                class="input input-bordered w-full"
                required
                autocomplete="new-password"
              />
            </div>

            <button type="submit" class="btn btn-primary w-full">
              Set password + sign in
            </button>
          </form>
        </div>
      </div>
    </main>
    """
  end
end
