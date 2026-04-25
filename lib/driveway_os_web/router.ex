defmodule DrivewayOSWeb.Router do
  use DrivewayOSWeb, :router

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
    plug :fetch_live_flash
    plug :put_root_layout, html: {DrivewayOSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DrivewayOSWeb do
    pipe_through :browser

    live "/", LandingLive
    live "/signup", SignupLive
    live "/sign-in", Auth.SignInLive
    live "/register", Auth.RegisterLive
    live "/book", BookingLive
    live "/book/success/:id", BookingSuccessLive
    live "/appointments", AppointmentsLive

    get "/auth/customer/store-token", Auth.SessionController, :store_token
    get "/auth/customer/sign-out", Auth.SessionController, :sign_out
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
