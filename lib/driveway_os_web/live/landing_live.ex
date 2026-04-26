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

  Design system: docs/DESIGN_SYSTEM.md. Tenant view uses the
  --tenant-primary CSS variable so the operator's primary_color_hex
  flows through every accent (CTA background, headline color); the
  marketing view stays platform-blue.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Branding

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns[:tenant_context] do
      :platform_admin ->
        {:ok, push_navigate(socket, to: ~p"/platform-sign-in")}

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def render(%{current_tenant: nil} = assigns), do: marketing(assigns)
  def render(%{current_tenant: %{}} = assigns), do: tenant(assigns)

  # ---- Marketing (platform-branded, no tenant) ----

  defp marketing(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200">
      <div class="max-w-5xl mx-auto px-6 py-24 sm:py-32">
        <div class="max-w-3xl space-y-8">
          <span class="inline-flex items-center gap-2 rounded-full bg-primary/10 text-primary px-3 py-1 text-xs font-semibold uppercase tracking-wide">
            <span class="hero-sparkles w-4 h-4" aria-hidden="true"></span> Private beta
          </span>

          <h1 class="text-5xl sm:text-6xl font-bold tracking-tight text-base-content">
            The operating system for <span class="text-primary">mobile detail shops</span>.
          </h1>

          <p class="text-xl text-base-content/70 max-w-2xl">
            One platform, many shops — each with its own brand, its own
            domain, its own Stripe account. You bring the customers, we
            run the shop.
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <a href="/signup" class="btn btn-accent btn-lg gap-2">
              <span class="hero-rocket-launch w-5 h-5" aria-hidden="true"></span> Start your shop
            </a>
            <a href="#features" class="btn btn-ghost btn-lg">Learn more</a>
          </div>

          <p class="text-sm text-base-content/60 pt-2">
            Currently in private development. Drop your email at signup and we'll get you set up.
          </p>
        </div>

        <section id="features" class="mt-24 grid grid-cols-1 md:grid-cols-3 gap-6">
          <article class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <span class="hero-globe-alt w-8 h-8 text-primary" aria-hidden="true"></span>
              <h3 class="card-title text-lg mt-2">Your own URL</h3>
              <p class="text-sm text-base-content/70">
                Run on a subdomain, or bring your own domain. CNAME-verified, SSL-ready.
              </p>
            </div>
          </article>

          <article class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <span class="hero-credit-card w-8 h-8 text-primary" aria-hidden="true"></span>
              <h3 class="card-title text-lg mt-2">Stripe Connect</h3>
              <p class="text-sm text-base-content/70">
                Charges land in your Stripe account, not ours. Pay nothing to set up.
              </p>
            </div>
          </article>

          <article class="card bg-base-100 shadow-sm border border-base-300">
            <div class="card-body p-6">
              <span class="hero-calendar-days w-8 h-8 text-primary" aria-hidden="true"></span>
              <h3 class="card-title text-lg mt-2">Booking that fits</h3>
              <p class="text-sm text-base-content/70">
                Define weekly availability blocks. Customers book the slots you actually have.
              </p>
            </div>
          </article>
        </section>
      </div>
    </main>
    """
  end

  # ---- Tenant landing (customer-facing, tenant-branded) ----

  defp tenant(assigns) do
    assigns = assign(assigns, :tenant_color, "#" <> primary_color(assigns.current_tenant))

    ~H"""
    <main
      class="min-h-screen bg-base-200"
      style={"--tenant-primary: #{@tenant_color};"}
    >
      <div class="max-w-3xl mx-auto px-6 py-20 sm:py-28">
        <div class="space-y-8">
          <img
            :if={@current_tenant.logo_url}
            src={@current_tenant.logo_url}
            alt={@current_tenant.display_name}
            class="h-16 w-auto"
          />

          <h1
            class="text-5xl sm:text-6xl font-bold tracking-tight"
            style="color: var(--tenant-primary);"
          >
            {Branding.display_name(@current_tenant)}
          </h1>

          <p class="text-xl text-base-content/70 max-w-2xl">
            Mobile detailing at your door. Book a wash in minutes.
          </p>

          <div class="flex flex-wrap items-center gap-3 pt-2">
            <%!-- Primary CTA always — tenant brand color --%>
            <a
              href="/book"
              class="btn btn-lg gap-2 text-white border-0"
              style="background-color: var(--tenant-primary);"
            >
              <span class="hero-sparkles w-5 h-5" aria-hidden="true"></span> Book a wash
            </a>

            <%!-- Signed-in customer: show their landing options. --%>
            <a :if={@current_customer} href="/appointments" class="btn btn-ghost btn-lg gap-2">
              <span class="hero-calendar w-5 h-5" aria-hidden="true"></span> My appointments
            </a>
            <a
              :if={@current_customer && @current_customer.role == :admin}
              href="/admin"
              class="btn btn-ghost btn-lg gap-2"
            >
              <span class="hero-cog-6-tooth w-5 h-5" aria-hidden="true"></span> Admin
            </a>
            <a
              :if={@current_customer}
              href="/auth/customer/sign-out"
              class="btn btn-ghost btn-lg gap-2"
            >
              <span class="hero-arrow-left-on-rectangle w-5 h-5" aria-hidden="true"></span> Sign out
            </a>

            <%!-- Signed-out: invite to register / sign in. --%>
            <a
              :if={is_nil(@current_customer)}
              href="/sign-in"
              class="btn btn-ghost btn-lg gap-2"
            >
              <span class="hero-arrow-right-on-rectangle w-5 h-5" aria-hidden="true"></span> Sign in
            </a>
            <a
              :if={is_nil(@current_customer)}
              href="/register"
              class="btn btn-ghost btn-lg"
            >
              Create account
            </a>
          </div>

          <%!-- Email-verification soft nudge --%>
          <div
            :if={@current_customer && is_nil(@current_customer.email_verified_at)}
            class="alert alert-warning shadow-sm"
            role="alert"
          >
            <span class="hero-exclamation-triangle w-5 h-5 shrink-0" aria-hidden="true"></span>
            <div class="flex-1 text-sm">
              <span class="font-semibold">Verify your email</span>
              — check your inbox for the link we sent when you signed up.
            </div>
            <form action="/auth/customer/resend-verification" method="post" class="m-0">
              <input
                type="hidden"
                name="_csrf_token"
                value={Phoenix.Controller.get_csrf_token()}
              />
              <button class="btn btn-sm" type="submit">Resend</button>
            </form>
          </div>

          <p :if={@current_customer} class="text-sm text-base-content/60 pt-2">
            Signed in as <span class="font-semibold">{@current_customer.name}</span>
          </p>
        </div>

        <%!-- Trust strip below the fold --%>
        <section class="mt-20 grid grid-cols-1 sm:grid-cols-3 gap-4 text-sm">
          <div class="flex items-start gap-3">
            <span
              class="hero-map-pin w-5 h-5 shrink-0 text-base-content/50 mt-0.5"
              aria-hidden="true"
            ></span>
            <div>
              <div class="font-semibold">We come to you</div>
              <div class="text-base-content/60">Driveway, garage, parking lot — wherever your car lives.</div>
            </div>
          </div>
          <div class="flex items-start gap-3">
            <span
              class="hero-clock w-5 h-5 shrink-0 text-base-content/50 mt-0.5"
              aria-hidden="true"
            ></span>
            <div>
              <div class="font-semibold">Real availability</div>
              <div class="text-base-content/60">Pick from concrete time slots — no back-and-forth.</div>
            </div>
          </div>
          <div class="flex items-start gap-3">
            <span
              class="hero-lock-closed w-5 h-5 shrink-0 text-base-content/50 mt-0.5"
              aria-hidden="true"
            ></span>
            <div>
              <div class="font-semibold">Pay securely</div>
              <div class="text-base-content/60">Stripe-powered. Card details never touch our servers.</div>
            </div>
          </div>
        </section>
      </div>
    </main>
    """
  end

  defp primary_color(%{primary_color_hex: nil}), do: "0d9488"
  defp primary_color(%{primary_color_hex: "#" <> hex}), do: hex
  defp primary_color(%{primary_color_hex: hex}) when is_binary(hex), do: hex
  defp primary_color(_), do: "0d9488"
end
