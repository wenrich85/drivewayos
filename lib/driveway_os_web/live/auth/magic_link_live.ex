defmodule DrivewayOSWeb.Auth.MagicLinkLive do
  @moduledoc """
  Magic-link sign-in for tenant customers at
  `{slug}.lvh.me/magic-link`. Operator-friendly alternative to the
  password form: enter your email, click a link in your inbox.

  Security:
    * Always renders the same "check your email" success message,
      regardless of whether the email matched a Customer in this
      tenant — so an attacker can't enumerate accounts.
    * The minted token is a regular AshAuthentication customer
      JWT (signed with the customer signing secret + carrying the
      tenant claim) so the existing `/auth/customer/store-token`
      controller handles the click.
    * Tokens expire fast (default 15 min) since they're sent by
      email — long-lived sessions still come from password auth.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.MagicLinkEmail

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_tenant] do
      {:ok,
       socket
       |> assign(:page_title, "Sign in by email")
       |> assign(:sent?, false)}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("submit", %{"signin" => %{"email" => email}}, socket) do
    tenant = socket.assigns.current_tenant
    normalized = email |> to_string() |> String.trim() |> String.downcase()

    # Look up the customer in this tenant. We don't tell the user
    # whether the lookup succeeded — same UI either way.
    case lookup_customer(normalized, tenant.id) do
      {:ok, customer} ->
        case mint_token(customer) do
          {:ok, token, _claims} ->
            link_url = magic_link_url(tenant, token)
            send_email(tenant, customer, link_url)

          _ ->
            :noop
        end

      _ ->
        :noop
    end

    {:noreply, assign(socket, :sent?, true)}
  end

  defp lookup_customer(email, tenant_id) do
    Customer
    |> Ash.Query.filter(email == ^email)
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Customer{} = c} -> {:ok, c}
      _ -> :error
    end
  end

  # Mint a customer JWT. AshAuthentication automatically attaches
  # the `tenant` claim because Customer has `multitenancy :attribute`,
  # so the resulting token is unusable on other tenant subdomains.
  defp mint_token(customer) do
    AshAuthentication.Jwt.token_for_user(customer, %{}, token_lifetime: {15, :minutes})
  end

  defp magic_link_url(tenant, token) do
    host = Application.fetch_env!(:driveway_os, :platform_host)
    http_opts = Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)[:http] || []
    port = Keyword.get(http_opts, :port)

    {scheme, port_suffix} =
      cond do
        host == "lvh.me" -> {"http", ":#{port || 4000}"}
        port in [nil, 80, 443] -> {"https", ""}
        true -> {"https", ":#{port}"}
      end

    "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}/auth/customer/store-token?token=#{token}"
  end

  defp send_email(tenant, customer, link_url) do
    tenant
    |> MagicLinkEmail.sign_in(customer, link_url)
    |> Mailer.deliver()
  rescue
    # Don't crash the LV if SMTP is briefly down — the user just
    # sees the same "check your email" message and can retry.
    _ -> :error
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center bg-base-200 px-4 py-12">
      <div class="card w-full max-w-md bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-2xl">Email me a sign-in link</h1>
          <p class="text-base-content/70 mb-2">
            We'll send you a one-click link to {@current_tenant.display_name}.
          </p>

          <div :if={@sent?} class="alert alert-success text-sm">
            Check your email. If your address is on file, you'll have a sign-in link in a few seconds.
          </div>

          <form :if={not @sent?} id="magic-link-form" phx-submit="submit" class="space-y-4">
            <div>
              <label class="label" for="ml-email">
                <span class="label-text">Email</span>
              </label>
              <input
                id="ml-email"
                type="email"
                name="signin[email]"
                class="input input-bordered w-full"
                required
              />
            </div>
            <button type="submit" class="btn btn-primary w-full">Email me a link</button>
          </form>

          <div class="divider text-xs">or</div>
          <a href={~p"/sign-in"} class="btn btn-ghost btn-sm">Sign in with password instead</a>
        </div>
      </div>
    </main>
    """
  end
end
