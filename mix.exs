defmodule DrivewayOS.MixProject do
  @moduledoc """
  Build + dependency manifest.

  ## Platform versions

  We pin to a known-good runtime so dev / CI / prod all match:

      Elixir   1.18.x   (compile-time enforced below)
      OTP      27.x     (Dockerfile + .tool-versions; no Mix knob)
      Postgres 16.x     (config/runtime.exs; min_pg_version is 16)

  ## Dependency policy

  Constraints below use `~> MAJOR.MINOR` per Elixir convention. That
  means we accept patch + minor bumps within the same major
  automatically (`mix deps.update`), but a major bump requires
  editing this file. When you bump a constraint, update the
  resolved version in `mix.lock` AND verify `mix precommit` is
  green before committing — `mix.lock` is the source of truth for
  what actually ships.

  When you ADD a new dep:
    1. Group it with related deps (Phoenix, Ash, payments, …)
    2. Add a one-line comment if the choice isn't obvious
    3. Pin to the current minor (`~> X.Y`), not just major
  """
  use Mix.Project

  def project do
    [
      app: :driveway_os,
      version: "0.1.0",
      # Pinned to 1.18 because we use string-key sigils, atom-keyed
      # maps in pattern matches, and other 1.18-only ergonomics.
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {DrivewayOS.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # --- Phoenix + LiveView core ---
      {:phoenix, "~> 1.8.5"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_ecto, "~> 4.7"},
      # Bandit > Cowboy as the HTTP/WebSocket server.
      {:bandit, "~> 1.10"},

      # --- Ecto + Postgres ---
      {:ecto_sql, "~> 3.13"},
      # Postgrex tracks ecto_sql; allow whatever ecto_sql wants.
      {:postgrex, ">= 0.0.0"},

      # --- Ash + multitenancy stack ---
      # Bumping ash usually requires bumping the whole family
      # (postgres / phoenix / authentication) together. Test
      # carefully and check ash's CHANGELOG for migration notes.
      {:ash, "~> 3.24"},
      {:ash_postgres, "~> 2.9"},
      {:ash_phoenix, "~> 2.3"},
      {:ash_authentication, "~> 4.13"},
      {:ash_authentication_phoenix, "~> 2.16"},
      # picosat is the SAT solver Ash uses for policy/aggregate
      # planning. Optional but pulled in to silence the
      # simple_sat-vs-picosat warning at boot.
      {:picosat_elixir, "~> 0.2"},
      # Password hashing for AshAuthentication's password strategy.
      {:bcrypt_elixir, "~> 3.3"},

      # --- Frontend toolchain (compile-time only in prod) ---
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},

      # --- Mail (Swoosh) ---
      {:swoosh, "~> 1.25"},
      # SMTP adapter — runtime-required only in prod (config gates
      # it on the SMTP_HOST env var). Tests use Swoosh.Adapters.Test.
      {:gen_smtp, "~> 1.3"},

      # --- HTTP client (used by StripeClient.Live for OAuth + by
      # whatever ad-hoc API call we need) ---
      {:req, "~> 0.5"},

      # --- Telemetry / observability ---
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},

      # --- I18n + JSON + DNS clustering ---
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dns_cluster, "~> 0.2.0"},

      # --- Background jobs ---
      {:oban, "~> 2.21"},

      # --- Payments (Stripe Connect Standard) ---
      {:stripity_stripe, "~> 3.2"},

      # --- Dev/test helpers ---
      # Required by Spark.Formatter (Ash DSL formatter plugin).
      {:sourceror, "~> 1.12", only: [:dev, :test]},
      # Lazy_html for LiveViewTest's HTML matchers.
      {:lazy_html, ">= 0.1.0", only: :test},
      # Browser-level (real Chrome via ChromeDriver) UI testing.
      # Tagged so plain `mix test` skips them; opt-in via
      # `mix test --include browser`. Pin chromedriver to the
      # exact installed Chrome version (see config/test.exs).
      {:wallaby, "~> 0.30", runtime: false, only: :test},
      # Behaviour-mocking for the StripeClient boundary so tests
      # don't hit Stripe's real API.
      {:mox, "~> 1.2", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind driveway_os", "esbuild driveway_os"],
      "assets.deploy": [
        "tailwind driveway_os --minify",
        "esbuild driveway_os --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
