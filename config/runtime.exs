import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/driveway_os start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :driveway_os, DrivewayOSWeb.Endpoint, server: true
end

# Bind the dev/prod endpoint to PORT (default 4000). The test
# endpoint stays on 4002 (configured in config/test.exs) so Wallaby
# doesn't fight a running dev server for the port.
if config_env() != :test do
  config :driveway_os, DrivewayOSWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# OAuth provider redirect base — the public-facing URL prefix
# providers send users back to after they consent. Read in any env
# (dev/prod alike) so the OAuth buttons on the sign-in page render
# the moment credentials are configured. Tests don't need it.
# See docs/OAUTH_SETUP.md.
if config_env() != :test do
  case System.get_env("OAUTH_REDIRECT_BASE") do
    nil -> :ok
    "" -> :ok
    base -> config :driveway_os, :oauth_redirect_base, base
  end
end

# Stripe Connect credentials live here (not gated to :prod) so a
# dev with test keys can wire up the OAuth flow against
# https://dashboard.stripe.com/test. Missing values default to ""
# so `Application.fetch_env!` doesn't raise; callers must guard for
# the empty case (see `Plans.stripe_configured?/0` and the CTA on
# /admin which hides itself when unset).
if config_env() != :test do
  config :driveway_os,
    stripe_client_id: System.get_env("STRIPE_CLIENT_ID") || "",
    stripe_secret_key: System.get_env("STRIPE_SECRET_KEY") || "",
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "",
    postmark_account_token: System.get_env("POSTMARK_ACCOUNT_TOKEN") || "",
    postmark_affiliate_ref_id: System.get_env("POSTMARK_AFFILIATE_REF_ID"),
    zoho_client_id: System.get_env("ZOHO_CLIENT_ID") || "",
    zoho_client_secret: System.get_env("ZOHO_CLIENT_SECRET") || "",
    zoho_affiliate_ref_id: System.get_env("ZOHO_AFFILIATE_REF_ID"),
    square_app_id: System.get_env("SQUARE_APP_ID") || "",
    square_app_secret: System.get_env("SQUARE_APP_SECRET") || "",
    square_webhook_signature_key: System.get_env("SQUARE_WEBHOOK_SIGNATURE_KEY") || "",
    square_affiliate_ref_id: System.get_env("SQUARE_AFFILIATE_REF_ID")

  # Optional sandbox/prod toggle for Square. Defaults to prod
  # (https://connect.squareup.com) when unset.
  case System.get_env("SQUARE_OAUTH_BASE") do
    nil -> :ok
    "" -> :ok
    base -> config :driveway_os, :square_oauth_base, base
  end

  case System.get_env("SQUARE_API_BASE") do
    nil -> :ok
    "" -> :ok
    base -> config :driveway_os, :square_api_base, base
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # DigitalOcean / RDS / most managed Postgres tiers require SSL.
  # Off by default so local prod-like Docker runs against a plain
  # localhost Postgres still work; flip via DB_SSL=true.
  ssl_opts =
    if System.get_env("DB_SSL") in ~w(true 1) do
      [verify: :verify_none]
    else
      false
    end

  config :driveway_os, DrivewayOS.Repo,
    ssl: ssl_opts,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # PHX_HOST is the public-facing hostname. It's load-bearing — every
  # email link, calendar invite, and `url(@socket, ...)` call resolves
  # through it. Defaulting to "example.com" silently ships broken
  # links in production, so we raise instead.
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      For example: drivewayos.com
      """

  config :driveway_os, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  endpoint_opts = [
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
  ]

  # Opt-in HTTPS redirect + HSTS. We keep this off by default so a
  # bare `mix release` run inside a non-TLS-fronted environment
  # (e.g. a local prod-like rebuild, a staging setup behind plain
  # HTTP) doesn't infinite-redirect itself. Set FORCE_SSL=true at
  # the actual prod tier (DigitalOcean app or behind any TLS
  # terminator).
  endpoint_opts =
    if System.get_env("FORCE_SSL") in ~w(true 1) do
      Keyword.put(endpoint_opts, :force_ssl, hsts: true)
    else
      endpoint_opts
    end

  config :driveway_os, DrivewayOSWeb.Endpoint, endpoint_opts

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :driveway_os, DrivewayOSWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :driveway_os, DrivewayOSWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Platform-tier (DrivewayOS operator) token signing secret. Separate
  # from any future customer signing secret so each population can be
  # rotated independently.
  config :driveway_os,
    platform_token_signing_secret:
      System.get_env("PLATFORM_TOKEN_SIGNING_SECRET") ||
        raise("PLATFORM_TOKEN_SIGNING_SECRET is required")

  # Customer-tier token signing secret. End-customers signing in to a
  # tenant's branded shop.
  config :driveway_os,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") || raise("TOKEN_SIGNING_SECRET is required")

  # Top-level platform host (e.g. "drivewayos.com"). Tenants live at
  # `{slug}.<platform_host>`.
  config :driveway_os,
    platform_host: System.get_env("PLATFORM_HOST") || "drivewayos.com"

  # ## Mailer (SMTP) — used by booking confirmation emails.
  # Swap to a different adapter if you'd rather use an HTTP API
  # (Mailgun / SendGrid / Postmark).
  if smtp_host = System.get_env("SMTP_HOST") do
    config :driveway_os, DrivewayOS.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      ssl: false,
      tls: :always,
      auth: :always,
      retries: 2

    # SMTP needs the swoosh API client off (only for HTTP adapters)
    config :swoosh, :api_client, false
  end

end
