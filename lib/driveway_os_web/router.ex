defmodule DrivewayOSWeb.Router do
  use DrivewayOSWeb, :router
  use AshAuthentication.Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # Subdomain → tenant. Runs early so downstream code can rely on
    # `conn.assigns[:current_tenant]` and `:tenant_context`. Halts
    # with 404 for unknown subdomains.
    plug DrivewayOSWeb.Plugs.LoadTenant
    # Resolve session JWT to a tenant-scoped Customer. No-ops for
    # marketing/admin contexts. Cross-tenant verification is built
    # in via AshAuthentication's "tenant" JWT claim.
    plug DrivewayOSWeb.Plugs.LoadCustomer
    plug DrivewayOSWeb.Plugs.LoadPlatformUser
    plug :fetch_live_flash
    plug :put_root_layout, html: {DrivewayOSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Stripe webhooks need no CSRF, no session, no LoadTenant — they
  # carry their own auth (signature) and own tenant resolution
  # (`stripe-account` header).
  pipeline :webhook do
    plug :accepts, ["json"]
  end

  scope "/webhooks", DrivewayOSWeb do
    pipe_through :webhook

    post "/stripe", StripeWebhookController, :handle
  end

  # Health check — load-balancer probe. Skips tenant + auth so
  # deploys can curl it from the bare host without DNS plumbing.
  scope "/", DrivewayOSWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  scope "/", DrivewayOSWeb do
    pipe_through :browser

    live "/", LandingLive
    live "/signup", SignupLive
    live "/sign-in", Auth.SignInLive
    live "/magic-link", Auth.MagicLinkLive
    live "/register", Auth.RegisterLive
    live "/forgot-password", Auth.ForgotPasswordLive
    live "/reset-password/:token", Auth.ResetPasswordLive
    live "/book", BookingLive
    live "/book/success/:id", BookingSuccessLive
    live "/appointments", AppointmentsLive
    live "/appointments/:id", AppointmentDetailLive
    live "/subscriptions/:id", SubscriptionDetailLive
    get "/appointments/:id/calendar.ics", CalendarController, :appointment
    live "/me", CustomerProfileLive
    live "/admin", Admin.DashboardLive
    live "/admin/onboarding", Admin.OnboardingWizardLive
    live "/admin/activity", Admin.ActivityLive
    live "/admin/today/print", Admin.TodayPrintLive
    live "/admin/domains", Admin.CustomDomainsLive
    live "/admin/schedule", Admin.ScheduleLive
    live "/admin/services", Admin.ServicesLive
    live "/admin/customers", Admin.CustomersLive
    live "/admin/customers/:id", Admin.CustomerDetailLive
    live "/admin/appointments", Admin.AppointmentsLive

    get "/admin/appointments.csv",
        AdminAppointmentsExportController,
        :appointments
    live "/admin/branding", Admin.BrandingLive

    get "/auth/customer/store-token", Auth.SessionController, :store_token
    get "/auth/customer/sign-out", Auth.SessionController, :sign_out
    get "/auth/customer/verify-email", EmailVerificationController, :verify
    post "/auth/customer/resend-verification", EmailVerificationController, :resend

    # OAuth-strategy routes for Customer (Google/Facebook/Apple).
    # AshAuthentication generates /auth/customer/{provider} +
    # /auth/customer/{provider}/callback under this prefix; the
    # AuthController handles the success + failure callbacks.
    auth_routes Auth.AuthController, DrivewayOS.Accounts.Customer, path: "/auth/customer"

    get "/onboarding/stripe/start", StripeOnboardingController, :start
    get "/onboarding/stripe/callback", StripeOnboardingController, :callback

    # Platform-admin (the SaaS operator — us). All under admin.lvh.me.
    live "/platform-sign-in", Platform.SignInLive
    live "/tenants", Platform.TenantsLive
    live "/metrics", Platform.MetricsLive
    live "/plans", Platform.PlansLive
    get "/auth/platform/store-token", Platform.SessionController, :store_token
    get "/auth/platform/sign-out", Platform.SessionController, :sign_out

    get "/platform/impersonate/:id", Platform.ImpersonationController, :start
  end

  # Other scopes may use custom stacks.
  # scope "/api", DrivewayOSWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:driveway_os, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DrivewayOSWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
