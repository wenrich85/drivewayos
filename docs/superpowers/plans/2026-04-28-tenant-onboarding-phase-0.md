# Tenant Onboarding Phase 0 — Wizard Framework + Provider Abstraction

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the bones of a pluggable onboarding system: a `Provider` behaviour, a `Registry` that lists registered providers, the existing Stripe Connect flow refactored into the new shape, the admin dashboard checklist refactored to source provider items from the Registry, and a new `/admin/onboarding` LV stub that lists providers grouped by category.

**Architecture:** New top-level `DrivewayOS.Onboarding` namespace. Behaviour module defines the contract; concrete provider modules implement it; a Registry module aggregates them. The dashboard checklist becomes the first consumer of the Registry. A new wizard LiveView at `/admin/onboarding` exists as a stub directory of integrations. No tenant-visible behavior change versus today; same dashboard checklist rows, same Stripe Connect OAuth flow.

**Tech Stack:** Elixir 1.18 / Phoenix LiveView 1.1 / Ash 3.24. Tests use ExUnit with the existing `DrivewayOSWeb.ConnCase` and `DrivewayOS.DataCase` helpers. Standard project test command is `mix test`.

**Spec:** `docs/superpowers/specs/2026-04-28-tenant-onboarding-roadmap.md` — section "Architecture / The three layers" + "Phase 0" row.

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `lib/driveway_os/onboarding/provider.ex` | Behaviour module defining the contract every provider must implement (`id/0`, `category/0`, `display/0`, `configured?/0`, `setup_complete?/1`). |
| `lib/driveway_os/onboarding/registry.ex` | Aggregates known provider modules; queries by category and "needs setup for this tenant". Module attribute holds the canonical list. |
| `lib/driveway_os/onboarding/providers/stripe_connect.ex` | Stripe Connect provider implementation. Delegates `configured?/0` to the existing `DrivewayOS.Billing.StripeConnect` module so we don't fork the credential check. |
| `lib/driveway_os_web/live/admin/onboarding_wizard_live.ex` | Stub wizard LiveView at `/admin/onboarding`. Admin-only mount. Lists registered providers grouped by category with a "Configure" link per provider that points at the provider's `display.href`. |
| `test/driveway_os/onboarding/registry_test.exs` | Unit tests for `Registry.all/0`, `by_category/1`, `needing_setup/1`. |
| `test/driveway_os/onboarding/providers/stripe_connect_test.exs` | Tests for each behaviour callback on the StripeConnect provider. |
| `test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs` | Auth gate + content tests for the wizard LV. |

**Modified:**

| Path | Change |
|---|---|
| `lib/driveway_os_web/live/admin/dashboard_live.ex` | `build_checklist/4` is rewritten so the Stripe row comes from `Onboarding.Registry.needing_setup/1` (per-provider items) and the four internal-config rows (services, schedule, branding, domains) stay hardcoded. The hardcoded Stripe tuple is removed. |
| `lib/driveway_os_web/router.ex` | Add `live "/admin/onboarding", Admin.OnboardingWizardLive` to the same scope as `/admin`. |
| `test/driveway_os_web/live/admin_dashboard_test.exs` | Update the assertions inside the `first-run checklist` describe so they tolerate the Registry-sourced Stripe row (text/href stay the same, but make the test resilient if the Registry returns an empty list when client_id is unset — which the existing test "Stripe row hidden when client_id is unconfigured" already covers). |

---

## Task 1: Provider behaviour

The behaviour itself has no logic — it's just `@callback` definitions. We don't write a unit test for the behaviour module; the conformance tests for each implementing module are what matter.

**Files:**
- Create: `lib/driveway_os/onboarding/provider.ex`

- [ ] **Step 1: Create the behaviour module**

```elixir
# lib/driveway_os/onboarding/provider.ex
defmodule DrivewayOS.Onboarding.Provider do
  @moduledoc """
  Behaviour every onboarding-integration provider implements.

  A "provider" here is an external service (Stripe, Postmark, Square,
  etc.) that a tenant can connect during onboarding. The behaviour
  is intentionally minimal — five callbacks that together let the
  wizard render a card for each provider, decide whether it's
  configured at the platform level, and decide whether THIS tenant
  has finished connecting it.

  See also: `DrivewayOS.Onboarding.Registry` for the canonical list
  of providers, and `docs/superpowers/specs/2026-04-28-tenant-onboarding-roadmap.md`
  for why the abstraction exists.
  """

  alias DrivewayOS.Platform.Tenant

  @typedoc "Logical category — :payment, :email, :accounting, etc."
  @type category :: atom()

  @typedoc "Static display config rendered as a checklist / wizard card."
  @type display :: %{
          required(:title) => String.t(),
          required(:blurb) => String.t(),
          required(:cta_label) => String.t(),
          required(:href) => String.t()
        }

  @doc "Stable identifier (e.g. `:stripe_connect`). Used as a map key."
  @callback id() :: atom()

  @doc "Logical category this provider belongs to."
  @callback category() :: category()

  @doc "Title / blurb / CTA copy + the URL the CTA points at."
  @callback display() :: display()

  @doc """
  True when the platform has the credentials needed to drive this
  provider (e.g. `STRIPE_CLIENT_ID` is set). False when the
  integration is dormant on this server — the wizard hides such
  providers entirely rather than offering a dead-end CTA.
  """
  @callback configured?() :: boolean()

  @doc """
  True when the given tenant has finished connecting this provider
  (e.g. has a `stripe_account_id`). The wizard / dashboard
  checklist hides the row when this returns true.
  """
  @callback setup_complete?(Tenant.t()) :: boolean()
end
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile`
Expected: success (warnings about unused warnings about pre-existing things in other files are OK; no new warnings about this file).

- [ ] **Step 3: Commit**

```bash
git add lib/driveway_os/onboarding/provider.ex
git commit -m "Onboarding: Provider behaviour"
```

---

## Task 2: StripeConnect provider implementation

**Files:**
- Create: `lib/driveway_os/onboarding/providers/stripe_connect.ex`
- Test: `test/driveway_os/onboarding/providers/stripe_connect_test.exs`

- [ ] **Step 1: Write failing tests covering all five callbacks**

```elixir
# test/driveway_os/onboarding/providers/stripe_connect_test.exs
defmodule DrivewayOS.Onboarding.Providers.StripeConnectTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Providers.StripeConnect, as: Provider
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant, admin: _admin}} =
      Platform.provision_tenant(%{
        slug: "scprov-#{System.unique_integer([:positive])}",
        display_name: "Stripe Provider Test",
        admin_email: "scprov-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :stripe_connect" do
    assert Provider.id() == :stripe_connect
  end

  test "category/0 is :payment" do
    assert Provider.category() == :payment
  end

  test "display/0 returns title, blurb, cta_label, href" do
    d = Provider.display()
    assert is_binary(d.title)
    assert is_binary(d.blurb)
    assert is_binary(d.cta_label)
    assert d.href == "/onboarding/stripe/start"
  end

  test "configured?/0 mirrors Billing.StripeConnect.configured?/0" do
    # Test config has stripe_client_id set, so configured? is true.
    assert Provider.configured?() == DrivewayOS.Billing.StripeConnect.configured?()

    # Flipping the env flips the answer.
    original = Application.get_env(:driveway_os, :stripe_client_id)
    Application.put_env(:driveway_os, :stripe_client_id, "")
    on_exit(fn -> Application.put_env(:driveway_os, :stripe_client_id, original) end)

    refute Provider.configured?()
  end

  test "setup_complete?/1 reflects whether the tenant has a stripe_account_id", ctx do
    refute Provider.setup_complete?(ctx.tenant)

    {:ok, with_acct} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_test_123"})
      |> Ash.update(authorize?: false)

    assert Provider.setup_complete?(with_acct)
  end
end
```

- [ ] **Step 2: Run the tests; verify they fail**

Run: `mix test test/driveway_os/onboarding/providers/stripe_connect_test.exs`
Expected: failures with `(UndefinedFunctionError) function DrivewayOS.Onboarding.Providers.StripeConnect.id/0 is undefined (module DrivewayOS.Onboarding.Providers.StripeConnect is not available)`.

- [ ] **Step 3: Implement the provider**

```elixir
# lib/driveway_os/onboarding/providers/stripe_connect.ex
defmodule DrivewayOS.Onboarding.Providers.StripeConnect do
  @moduledoc """
  Stripe Connect onboarding provider — the V1 payment integration.

  This module is a thin adapter around the existing
  `DrivewayOS.Billing.StripeConnect` module: the OAuth + state +
  account creation logic stays where it's already tested and
  working, and this layer just answers the questions the
  `Onboarding.Provider` behaviour asks ("what's your category?",
  "is the tenant set up?", etc.) so the wizard + Registry can
  treat it uniformly with future providers.
  """
  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Billing.StripeConnect, as: Billing
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :stripe_connect

  @impl true
  def category, do: :payment

  @impl true
  def display do
    %{
      title: "Take card payments",
      blurb:
        "Connect a Stripe account so customers can pay at booking time. " <>
          "We'll add a small platform fee per charge.",
      cta_label: "Connect Stripe",
      href: "/onboarding/stripe/start"
    }
  end

  @impl true
  def configured?, do: Billing.configured?()

  @impl true
  def setup_complete?(%Tenant{stripe_account_id: id}), do: not is_nil(id)
end
```

- [ ] **Step 4: Run the tests; verify they pass**

Run: `mix test test/driveway_os/onboarding/providers/stripe_connect_test.exs`
Expected: 5 passes, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/providers/stripe_connect.ex \
        test/driveway_os/onboarding/providers/stripe_connect_test.exs
git commit -m "Onboarding: StripeConnect provider implementing Provider behaviour"
```

---

## Task 3: Registry

**Files:**
- Create: `lib/driveway_os/onboarding/registry.ex`
- Test: `test/driveway_os/onboarding/registry_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/driveway_os/onboarding/registry_test.exs
defmodule DrivewayOS.Onboarding.RegistryTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Registry
  alias DrivewayOS.Onboarding.Providers.StripeConnect
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "reg-#{System.unique_integer([:positive])}",
        display_name: "Registry Test",
        admin_email: "reg-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "all/0 includes the StripeConnect provider" do
    assert StripeConnect in Registry.all()
  end

  test "by_category/1 filters to providers in that category" do
    assert StripeConnect in Registry.by_category(:payment)
    assert Registry.by_category(:nonsense) == []
  end

  test "needing_setup/1 returns providers that are configured AND not yet set up", ctx do
    # Default test tenant has no stripe_account_id, and stripe_client_id
    # is set in test config → StripeConnect should appear.
    assert StripeConnect in Registry.needing_setup(ctx.tenant)
  end

  test "needing_setup/1 hides providers that are already set up for this tenant", ctx do
    {:ok, with_acct} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_x_123"})
      |> Ash.update(authorize?: false)

    refute StripeConnect in Registry.needing_setup(with_acct)
  end

  test "needing_setup/1 hides providers that aren't configured at the platform level", ctx do
    original = Application.get_env(:driveway_os, :stripe_client_id)
    Application.put_env(:driveway_os, :stripe_client_id, "")
    on_exit(fn -> Application.put_env(:driveway_os, :stripe_client_id, original) end)

    refute StripeConnect in Registry.needing_setup(ctx.tenant)
  end
end
```

- [ ] **Step 2: Run the tests; verify they fail**

Run: `mix test test/driveway_os/onboarding/registry_test.exs`
Expected: failures with `(UndefinedFunctionError) function DrivewayOS.Onboarding.Registry.all/0 is undefined`.

- [ ] **Step 3: Implement the Registry**

```elixir
# lib/driveway_os/onboarding/registry.ex
defmodule DrivewayOS.Onboarding.Registry do
  @moduledoc """
  Canonical list of onboarding providers + helpers for querying them.

  The list is a module attribute rather than runtime config because
  every supported provider lives in this codebase — there's no
  tenant-supplied or runtime-discovered set. New providers land via
  PR (add the module here + add the implementation file).

  Consumers:
    * `DrivewayOSWeb.Admin.DashboardLive` — composes the dashboard
      checklist from `needing_setup/1`.
    * `DrivewayOSWeb.Admin.OnboardingWizardLive` — renders one
      section per category from `by_category/1`.
  """

  alias DrivewayOS.Platform.Tenant

  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect
  ]

  @doc "All registered providers, in declaration order."
  @spec all() :: [module()]
  def all, do: @providers

  @doc "Providers whose `category/0` matches `cat`."
  @spec by_category(atom()) :: [module()]
  def by_category(cat) when is_atom(cat) do
    Enum.filter(@providers, &(&1.category() == cat))
  end

  @doc """
  Providers the given tenant should still be prompted to set up.
  Filters by both `configured?/0` (don't surface dead-end CTAs for
  providers the platform itself isn't configured for) and
  `setup_complete?/1` (don't keep nagging once they've connected).
  """
  @spec needing_setup(Tenant.t()) :: [module()]
  def needing_setup(%Tenant{} = tenant) do
    @providers
    |> Enum.filter(& &1.configured?())
    |> Enum.reject(& &1.setup_complete?(tenant))
  end
end
```

- [ ] **Step 4: Run the tests; verify they pass**

Run: `mix test test/driveway_os/onboarding/registry_test.exs`
Expected: 5 passes, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/registry.ex \
        test/driveway_os/onboarding/registry_test.exs
git commit -m "Onboarding: Registry"
```

---

## Task 4: Refactor the dashboard checklist to use the Registry

The Stripe row currently lives in `build_checklist/4` as a hardcoded tuple. We replace that one line with a call to the Registry, which returns the same shape. Existing dashboard tests must continue to pass without modification — that's the proof the refactor is behaviour-preserving.

**Files:**
- Modify: `lib/driveway_os_web/live/admin/dashboard_live.ex` (the `build_checklist/4` function and its `alias` block)

- [ ] **Step 1: Add the Registry alias**

In `lib/driveway_os_web/live/admin/dashboard_live.ex`, find the existing `alias` block (around line 20). Add `alias DrivewayOS.Onboarding.Registry` next to the existing aliases (alphabetical order — between `Mailer` and `Notifications.BookingEmail`). Leave the existing `alias DrivewayOS.Billing.StripeConnect` line in place — `build_checklist` no longer references it but other code in the module still does (the inline comment about hiding the row when client_id is unset).

```elixir
  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.BookingEmail
  alias DrivewayOS.Onboarding.Registry
  alias DrivewayOS.Platform.CustomDomain
```

- [ ] **Step 2: Replace the hardcoded Stripe row in `build_checklist/4`**

Find the function (around line 371). Replace the entire body with a version that pulls provider rows from the Registry:

```elixir
  defp build_checklist(tenant, blocks, custom_domains, services) do
    provider_items =
      tenant
      |> Registry.needing_setup()
      |> Enum.map(fn module ->
        %{title: t, blurb: b, cta_label: c, href: h} = module.display()
        {t, b, c, h}
      end)

    internal_items = [
      using_default_services?(services) &&
        {"Set your service menu",
         "Rename, reprice, or replace the two starter washes (Basic + Deep Clean) with what you actually offer.",
         "Edit services",
         "/admin/services"},
      Enum.empty?(blocks) &&
        {"Set your weekly hours",
         "Customers can only pick from time slots you've published. Add at least one weekly availability block.",
         "Set hours",
         "/admin/schedule"},
      missing_branding?(tenant) &&
        {"Make it yours",
         "Upload your logo, set a support email, and pick a brand color so the booking page feels like your shop.",
         "Customize",
         "/admin/branding"},
      Enum.empty?(custom_domains) &&
        {"Run on your own domain",
         "Optional. Point a hostname like book.yourshop.com here so customers don't see the DrivewayOS subdomain.",
         "Add domain",
         "/admin/domains"}
    ]
    |> Enum.filter(& &1)

    provider_items ++ internal_items
  end
```

Confirm by reading the file: there is no longer any `tenant.stripe_account_id` reference inside `build_checklist`. The Registry handles it via `setup_complete?/1` on the StripeConnect provider.

- [ ] **Step 3: Run the existing dashboard tests; verify all pass**

Run: `mix test test/driveway_os_web/live/admin_dashboard_test.exs`
Expected: 27 tests pass, 0 failures. The existing tests cover:
- "shows open items when the tenant is fresh" — asserts "Connect Stripe" + "Set your weekly hours" appear
- "Stripe row hidden when client_id is unconfigured" — asserts `Connect Stripe` does NOT appear when client_id is empty
- "hides items that are done" — asserts the row goes away when stripe_account_id is set

If any of those fail, the refactor changed behaviour — re-read the function and the failing test, fix the function (NOT the test), and re-run.

- [ ] **Step 4: Commit**

```bash
git add lib/driveway_os_web/live/admin/dashboard_live.ex
git commit -m "Dashboard checklist: source provider rows from Registry"
```

---

## Task 5: Wizard LiveView stub at /admin/onboarding

A directory page that lists registered providers grouped by category. Phase 1 will replace this with the actual linear wizard; for Phase 0 it exists so the route is reserved and the abstraction has a second consumer (the dashboard is the first).

**Files:**
- Create: `lib/driveway_os_web/live/admin/onboarding_wizard_live.ex`
- Create: `test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs`
- Modify: `lib/driveway_os_web/router.ex`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs
defmodule DrivewayOSWeb.Admin.OnboardingWizardLiveTest do
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "onb-#{System.unique_integer([:positive])}",
        display_name: "Onboarding Test",
        admin_email: "onb-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, regular} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "reg-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Regular"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, regular: regular}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    Plug.Test.init_test_session(conn, %{customer_token: token})
  end

  describe "auth" do
    test "anonymous → /sign-in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/admin/onboarding")
    end

    test "non-admin customer → /", ctx do
      conn = sign_in(ctx.conn, ctx.regular)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/admin/onboarding")
    end
  end

  describe "rendering" do
    test "admin sees a page listing the Stripe Connect provider under Payment", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      # Section header for the :payment category.
      assert html =~ "Payment"
      # The provider's display.title.
      assert html =~ "Take card payments"
      # The provider's display.cta_label inside an anchor with the href.
      assert html =~ ~s(href="/onboarding/stripe/start")
      assert html =~ "Connect Stripe"
    end

    test "providers that are already set up don't render", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_done_x"})
      |> Ash.update!(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      refute html =~ "Connect Stripe"
    end
  end
end
```

- [ ] **Step 2: Run the tests; verify they fail**

Run: `mix test test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs`
Expected: failures with route-not-found errors (the `/admin/onboarding` route doesn't exist yet).

- [ ] **Step 3: Implement the wizard LV**

```elixir
# lib/driveway_os_web/live/admin/onboarding_wizard_live.ex
defmodule DrivewayOSWeb.Admin.OnboardingWizardLive do
  @moduledoc """
  Stub wizard at `/admin/onboarding`. Phase 0 ships this as a
  directory of provider cards grouped by category — Phase 1 will
  replace the body with the actual linear wizard
  (Branding → Services → Schedule → Payment → Email).

  Lives next to the existing admin LVs so it picks up the same
  tenant + customer mounts. Auth: tenant-scoped + admin-only.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Onboarding.Registry

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Set up your shop")
         |> assign(:groups, group_pending(socket.assigns.current_tenant))}
    end
  end

  # Returns a list of {category, [provider_module, ...]} for the
  # categories where this tenant still has providers needing setup.
  # Empty categories drop out so an all-done shop sees an empty list.
  defp group_pending(tenant) do
    tenant
    |> Registry.needing_setup()
    |> Enum.group_by(& &1.category())
    |> Enum.sort_by(fn {category, _} -> category end)
  end

  defp category_label(:payment), do: "Payment"
  defp category_label(:email), do: "Email"
  defp category_label(:accounting), do: "Accounting"
  defp category_label(other), do: other |> Atom.to_string() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-3xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Dashboard
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">Set up your shop</h1>
          <p class="text-sm text-base-content/70 mt-1">
            Connect the integrations your shop needs. We'll walk you through each one.
          </p>
        </header>

        <div :if={@groups == []} class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body text-center py-10 px-4">
            <span class="hero-check-circle w-12 h-12 mx-auto text-success" aria-hidden="true"></span>
            <h2 class="mt-3 text-lg font-semibold">All set</h2>
            <p class="text-sm text-base-content/70 mt-1">
              Every available integration is connected. You're ready for customers.
            </p>
          </div>
        </div>

        <section
          :for={{category, providers} <- @groups}
          class="card bg-base-100 shadow-sm border border-base-300"
        >
          <div class="card-body p-6">
            <h2 class="card-title text-lg">{category_label(category)}</h2>
            <ul class="space-y-3 mt-2">
              <li
                :for={provider <- providers}
                class="flex gap-3 items-start bg-base-200/50 border border-base-300 rounded-lg p-4"
              >
                <% display = provider.display() %>
                <div class="flex-1 min-w-0">
                  <div class="font-semibold">{display.title}</div>
                  <div class="text-sm text-base-content/70 mt-0.5">{display.blurb}</div>
                </div>
                <a
                  href={display.href}
                  class="btn btn-primary btn-sm gap-1 shrink-0 self-center"
                >
                  {display.cta_label}
                  <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
                </a>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
```

- [ ] **Step 4: Add the route**

In `lib/driveway_os_web/router.ex`, find the existing `live "/admin", Admin.DashboardLive` line. Add the new route on the line after it (so the order matches the rough categorization of admin LVs already there):

```elixir
    live "/admin", Admin.DashboardLive
    live "/admin/onboarding", Admin.OnboardingWizardLive
    live "/admin/activity", Admin.ActivityLive
```

- [ ] **Step 5: Run the wizard tests; verify they pass**

Run: `mix test test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs`
Expected: 4 passes, 0 failures.

- [ ] **Step 6: Run the full suite; verify nothing else regressed**

Run: `mix test`
Expected: every previously-green test still passes; the new tests added in Tasks 2 + 3 + 5 also pass. Final count should be the previous green count plus 14 new tests (5 in Task 2, 5 in Task 3, 4 in Task 5).

- [ ] **Step 7: Commit**

```bash
git add lib/driveway_os_web/live/admin/onboarding_wizard_live.ex \
        test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs \
        lib/driveway_os_web/router.ex
git commit -m "Onboarding: wizard LV stub at /admin/onboarding"
```

---

## Task 6: Final verification + push

- [ ] **Step 1: Confirm clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`. If files are still modified, figure out which task's commit missed them and amend or add a new commit.

- [ ] **Step 2: Run the full suite one more time**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 3: Push**

```bash
git push origin main
```

Expected: push succeeds. The branch on origin now contains five commits (one per task plus the framework commit) with the full Phase 0 abstraction in place.

---

## Self-review

**Spec coverage:**
- Roadmap "Architecture / 1. Wizard framework" → Task 5 (LV stub) — partial (Phase 0 explicitly says "skeleton"; full step interface lands in Phase 1).
- Roadmap "Architecture / 2. Provider abstraction" → Tasks 1 + 2 + 3 (behaviour + Stripe + Registry).
- Roadmap "Architecture / 3. Cross-cutting concerns / Affiliate" → Deferred to Phase 2 per the roadmap. Not in this plan.
- Roadmap "Architecture / 3. Cross-cutting concerns / ApiHelpers" → Deferred to Phase 1 (when Postmark API client lands). Not needed for Stripe (hosted-redirect only). Not in this plan.
- Roadmap "Phase 0 / Stripe Connect refactored into the new shape with no behavior change" → Task 4 (dashboard refactored to use Registry). Existing dashboard tests passing without modification is the behaviour-preservation proof.
- Roadmap "Identical to today, but the bones are correct for everything below" → satisfied: same /admin checklist visible, same /onboarding/stripe/start OAuth flow, plus a new /admin/onboarding route that lists providers.

**Placeholder scan:** No "TBD" / "TODO" / "fill in details" / vague-error-handling / "similar to Task N" patterns. Every code block contains the actual code; every command lists the exact path; every expected output is named.

**Type / signature consistency:**
- `id/0`, `category/0`, `display/0`, `configured?/0`, `setup_complete?/1` — same names + arities used in the behaviour, the StripeConnect impl, the Registry, and the Wizard LV. ✓
- `display/0` always returns a 4-key map (`title`, `blurb`, `cta_label`, `href`) — used in StripeConnect impl, Registry test, dashboard `build_checklist`, wizard LV render, all consistent. ✓
- `Tenant.t()` used as the type for the tenant arg everywhere `setup_complete?/1` and `Registry.needing_setup/1` appear. ✓

**Scope:** Phase 0 only. No Phase 1 mandatory-wizard behaviour, no Postmark, no Affiliate module — those live in their own future plans per the roadmap.
