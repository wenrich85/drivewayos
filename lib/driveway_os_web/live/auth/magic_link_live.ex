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
    rl_key = "magic:#{tenant.id}:#{normalized}"

    # Same enumeration-safety pattern as forgot-password: render
    # the success state regardless, but only do the actual lookup
    # + email work if we're under the rate limit. Limit is per
    # email so a single user can't be DDoS'd into spending the
    # tenant's email budget.
    case DrivewayOS.RateLimiter.check(rl_key, 3, 60 * 60 * 1000) do
      :ok ->
        with {:ok, customer} <- lookup_customer(normalized, tenant.id),
             {:ok, token, _claims} <- mint_token(customer) do
          link_url = magic_link_url(tenant, token)
          send_email(tenant, customer, link_url)
        end

      {:error, :rate_limited, _} ->
        :ok
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
    |> Mailer.deliver(Mailer.for_tenant(tenant))
  rescue
    # Don't crash the LV if SMTP is briefly down — the user just
    # sees the same "check your email" message and can retry.
    _ -> :error
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center bg-base-200 px-4 py-12">
      <div class="w-full max-w-md space-y-6">
        <header class="text-center space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">Email me a sign-in link</h1>
          <p class="text-sm text-base-content/70">
            One-click access to <span class="font-semibold">{@current_tenant.display_name}</span>.
            No password needed.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-4">
            <div :if={@sent?} role="alert" class="alert alert-success">
              <span class="hero-check-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
              <div class="flex-1 text-sm">
                <div class="font-semibold">Check your email</div>
                <div class="opacity-80">
                  If your address is on file, you'll have a sign-in link in a few seconds.
                </div>
              </div>
            </div>

            <form :if={not @sent?} id="magic-link-form" phx-submit="submit" class="space-y-4">
              <div>
                <label class="label" for="ml-email">
                  <span class="label-text font-medium">Email</span>
                </label>
                <input
                  id="ml-email"
                  type="email"
                  name="signin[email]"
                  autocomplete="email"
                  class="input input-bordered w-full"
                  required
                />
              </div>

              <button type="submit" class="btn btn-primary w-full gap-2">
                <span class="hero-envelope w-5 h-5" aria-hidden="true"></span>
                Email me a link
              </button>
            </form>

            <div class="divider text-xs my-2">or</div>

            <a href={~p"/sign-in"} class="btn btn-ghost w-full gap-2">
              <span class="hero-key w-5 h-5" aria-hidden="true"></span>
              Sign in with password
            </a>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
