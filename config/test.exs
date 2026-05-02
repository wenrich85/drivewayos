import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :driveway_os, DrivewayOS.Repo,
  username: System.get_env("DB_USER", "wrich"),
  password: System.get_env("DB_PASS", ""),
  hostname: "localhost",
  database: "driveway_os_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Endpoint runs the server in test so Wallaby (real Chrome) can hit
# it. Tests not tagged `:browser` are unaffected — they don't make
# HTTP requests at all.
config :driveway_os, DrivewayOSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "k/lHyCcA7FvESDOw0yolZJ+IpAXPVcB5hzbSJKCOHuIgzrOPtMEV0knaEfX9jJuK",
  server: true,
  # Allow LiveView socket connections from any tenant subdomain in test —
  # Wallaby visits {slug}.lvh.me:4002 during browser tests.
  check_origin: ["//lvh.me", "//*.lvh.me"]

# In test we don't send emails
config :driveway_os, DrivewayOS.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Platform-tier token signing secret (test).
config :driveway_os,
       :platform_token_signing_secret,
       "test-only-platform-secret-change-in-production-at-least-64-chars-long"

# Customer-tier token signing secret (test).
config :driveway_os,
       :token_signing_secret,
       "test-only-customer-secret-change-in-production-at-least-64-chars-long"

config :driveway_os, :platform_host, "lvh.me"
config :driveway_os, :session_cookie_domain, ".lvh.me"

# Don't start the reminder scheduler GenServer in test — tests
# drive its dispatch path directly with a deterministic `now`.
config :driveway_os, :start_schedulers?, false

# Oban runs in :manual mode — jobs are not auto-executed. Tests use
# `perform_job/2` (unit-style) and `assert_enqueued/1` (integration-
# style) from `Oban.Testing`. No supervisor is required for either.
config :driveway_os, Oban, testing: :manual

# Stripe placeholders (test env). Mox replaces all real API calls.
config :driveway_os, :stripe_client_id, "ca_test_placeholder"
config :driveway_os, :stripe_secret_key, "sk_test_placeholder"
config :driveway_os, :stripe_webhook_secret, "whsec_test_placeholder"

# Postmark placeholder (test env). Mox replaces all real API calls.
config :driveway_os, :postmark_account_token, "test-account-token-placeholder"
config :driveway_os, :postmark_affiliate_ref_id, nil

# Zoho placeholders (test env). Mox replaces all real API calls.
config :driveway_os, :zoho_client, DrivewayOS.Accounting.ZohoClient.Mock
config :driveway_os, :zoho_client_id, "test-zoho-client-id"
config :driveway_os, :zoho_client_secret, "test-zoho-client-secret"
config :driveway_os, :zoho_affiliate_ref_id, nil

# --- Wallaby (browser tests) ---
# Tests must be tagged `:browser` to use this; everything else runs
# in the regular Sandbox. Wallaby points at port 4002 (the test
# endpoint) and uses ChromeDriver in headless mode.
config :wallaby,
  driver: Wallaby.Chrome,
  base_url: "http://lvh.me:4002",
  screenshot_on_failure: true,
  # ChromeDriver MUST match the installed Chrome version. Brew's
  # chromedriver auto-bumps; pin to a versioned binary at
  # ~/.local/bin/chromedriver<major>. Override with CHROMEDRIVER_BIN
  # in CI. Note Wallaby's config key is `path:`, not `binary:`.
  chromedriver: [
    headless: true,
    path:
      System.get_env("CHROMEDRIVER_BIN") ||
        Path.expand("~/.local/bin/chromedriver147")
  ]

config :driveway_os, :sandbox, Ecto.Adapters.SQL.Sandbox

# Quiet Ash's missed-notification warnings in test — they fire on
# every nested-transaction create that doesn't pass return_notifications?:
# true. Harmless and very noisy.
config :ash, :missed_notifications, :ignore
