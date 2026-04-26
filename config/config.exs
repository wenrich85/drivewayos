# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :driveway_os,
  namespace: DrivewayOS,
  ecto_repos: [DrivewayOS.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  # Ash domains live here. Each domain module is registered as it's
  # added — V1 starts with Platform (Tenant + PlatformUser) in the
  # first slice.
  ash_domains: [
    DrivewayOS.Platform,
    DrivewayOS.Accounts,
    DrivewayOS.Scheduling,
    DrivewayOS.Fleet
  ]

# Ash conventions
config :ash,
  use_all_identities_in_manage_relationship?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  custom_types: [],
  known_types: []

config :spark, formatter: [remove_parens?: true]

# Configure the endpoint
config :driveway_os, DrivewayOSWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DrivewayOSWeb.ErrorHTML, json: DrivewayOSWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DrivewayOS.PubSub,
  live_view: [signing_salt: "NMV6JKNU"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :driveway_os, DrivewayOS.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  driveway_os: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  driveway_os: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
