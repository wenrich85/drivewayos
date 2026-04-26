defmodule DrivewayOSWeb.FeatureCase do
  @moduledoc """
  Test case for browser-level (Wallaby) feature tests.

  Tests using this case are tagged `:browser` automatically and are
  EXCLUDED from `mix test` by default. Run them with:

      mix test --include browser

  ChromeDriver must be installed (brew install chromedriver). The
  endpoint runs on port 4002 in test (config/test.exs).

  Two helpers worth knowing about:

    * `tenant_url(session, tenant, path)` — Wallaby's
      `visit/2` doesn't preserve the host across nav; pass it the
      tenant + relative path to get to `{slug}.lvh.me:4002`.

    * `sign_in(session, customer)` — sets a customer JWT on the
      session via the standard sign-in form.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      alias DrivewayOS.Accounts.Customer
      alias DrivewayOS.Platform
      alias DrivewayOS.Platform.Tenant
      alias DrivewayOS.Scheduling.{Appointment, ServiceType}

      import DrivewayOSWeb.FeatureCase

      @moduletag :browser
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(DrivewayOS.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(DrivewayOS.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    {:ok, session: session}
  end

  @doc """
  Build a URL that targets a specific tenant's subdomain on the
  Wallaby endpoint. Use instead of `visit(session, "/path")` whenever
  you need to land on a tenant route.

      visit(session, tenant_url(tenant, "/book"))
  """
  def tenant_url(%{slug: slug}, path) do
    "http://#{slug}.lvh.me:4002" <> path
  end

  @doc """
  Build a URL on the marketing host (no tenant subdomain).
  """
  def marketing_url(path) do
    "http://lvh.me:4002" <> path
  end

  @doc """
  Provision a tenant + first admin via the same atomic transaction
  used by the signup form. Returns `%{tenant:, admin:}` ready for
  use in feature tests.
  """
  def provision_test_tenant!(opts \\ []) do
    suffix = System.unique_integer([:positive])

    {:ok, %{tenant: tenant, admin: admin}} =
      DrivewayOS.Platform.provision_tenant(%{
        slug: opts[:slug] || "feat-#{suffix}",
        display_name: opts[:display_name] || "Feature Test Shop",
        admin_email: opts[:admin_email] || "owner-#{suffix}@example.com",
        admin_name: opts[:admin_name] || "Feature Owner",
        admin_password: opts[:admin_password] || "Password123!",
        admin_phone: "+15125550100"
      })

    %{tenant: tenant, admin: admin}
  end

  @doc """
  Sign a customer in via the real /sign-in form and wait for the
  redirect chain (LV → /auth/customer/store-token controller → /)
  to settle before returning. Without the wait, the next `visit/2`
  in a test races the cookie write and lands on /sign-in instead
  of the requested page.
  """
  def sign_in_as(session, tenant, email, password \\ "Password123!") do
    import Wallaby.Browser
    import Wallaby.Query, only: [css: 2, button: 1, fillable_field: 1]

    session
    |> visit(tenant_url(tenant, "/sign-in"))
    |> fill_in(fillable_field("signin[email]"), with: email)
    |> fill_in(fillable_field("signin[password]"), with: password)
    |> click(button("Sign in"))
    # Tenant landing page renders only after the cookie is set —
    # blocks here until that's true (or Wallaby times out).
    |> assert_has(css("h1", text: tenant.display_name))
  end

  @doc """
  Register a new end-customer in `tenant`. Returns the Customer
  struct.
  """
  def register_customer!(tenant, opts \\ []) do
    suffix = System.unique_integer([:positive])

    {:ok, customer} =
      DrivewayOS.Accounts.Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: opts[:email] || "cust-#{suffix}@example.com",
          password: opts[:password] || "Password123!",
          password_confirmation: opts[:password] || "Password123!",
          name: opts[:name] || "Test Customer"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    customer
  end
end
