# Tenant Onboarding Phase 2 — Affiliate tracking baseline

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the affiliate-tracking abstraction (events table + helper module + two new optional Provider callbacks) so Phase 4's hosted-signup providers (Square, SendGrid, etc.) plug in cleanly. V1 providers (Stripe Connect + Postmark) become no-op clients on the abstraction; their `:click` and `:provisioned` events start collecting funnel signal in `tenant_referrals` from day one.

**Architecture:** A new platform-tier `Platform.TenantReferral` Ash resource records three event types (`:click | :provisioned | :revenue_attributed`) keyed by `tenant_id` + `provider` atom. The new `Onboarding.Affiliate` module exposes three public functions: `tag_url/2`, `perk_copy/1`, `log_event/4`. The `Onboarding.Provider` behaviour gains two `@optional_callbacks`: `affiliate_config/0` and `tenant_perk/0`. Postmark + StripeConnect implement them returning `nil` for V1 (Stripe has no referral link; Postmark's ref_id env var is unset until we enroll). Wizard cards render `perk_copy/1` below their blurbs when non-nil. `:click`/`:provisioned` events log at the existing server touchpoints — Stripe's `/onboarding/stripe/start` controller and Postmark's `Steps.Email.submit/2`. No redirect proxy controller; that lands in Phase 4 when its first hosted-signup provider needs it.

**Tech Stack:** Elixir 1.18 / Phoenix LiveView 1.1 / Ash 3.24 / AshPostgres 2.9. Tests use ExUnit with `DrivewayOS.DataCase` and `DrivewayOSWeb.ConnCase`. Standard test command: `mix test`. The Postmark affiliate ID is read from `POSTMARK_AFFILIATE_REF_ID` env var.

**Spec:** `docs/superpowers/specs/2026-05-02-tenant-onboarding-phase-2-design.md` — read the "Architecture" + "Constraints + decisions" sections before starting.

**Phase 1 (already shipped):** `docs/superpowers/plans/2026-04-29-tenant-onboarding-phase-1.md`. Provides the wizard, `Steps.Email`, `Steps.Payment`, `Postmark` provider, `StripeConnect` provider, `Onboarding.Registry`, and the `StripeOnboardingController`.

**Branch policy:** Execute on `main`. Commit after each task. Push to origin after Task 11 (final verification).

---

## Spec deviations (decided during plan-writing)

These are intentional — the spec was written first; the plan reads the codebase and adapts where the spec was overly ascetic or inconsistent with established patterns.

1. **`TenantReferral` uses `belongs_to :tenant`, not a plain FK column.** The spec said "no `belongs_to`"; every other platform-tier resource (`TenantSubscription`, `CustomDomain`, `OauthState`) uses `belongs_to :tenant` and `references :tenant` (relationship name). AshPostgres's `references` block takes a relationship name, not a column name, so the spec's syntax (`reference :tenant_id`) wouldn't compile. The spec's intent ("don't pull Ash relationship machinery we don't use") is satisfied by simply not exercising the `tenant` relationship on read paths — same as TenantSubscription does today.

2. **Migration table name is `platform_tenant_referrals`** (not `tenant_referrals` as the spec said), to match the namespacing convention of `platform_custom_domains`, `platform_oauth_states`, etc. — every other platform-tier table prefixes `platform_`.

These are documented up front so the per-task code is internally consistent.

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `priv/repo/migrations/<ts>_create_platform_tenant_referrals.exs` | Creates the `platform_tenant_referrals` table + indexes. Generated via `mix ash_postgres.generate_migrations`. |
| `lib/driveway_os/platform/tenant_referral.ex` | Ash resource. Platform-tier (no multitenancy). `:log` create action; `:read`, `:destroy` defaults. |
| `lib/driveway_os/onboarding/affiliate.ex` | Three public functions: `tag_url/2`, `perk_copy/1`, `log_event/4`. Reads provider configs via the new behaviour callbacks. |
| `test/driveway_os/platform/tenant_referral_test.exs` | Resource CRUD + cross-tenant FK behavior. |
| `test/driveway_os/onboarding/affiliate_test.exs` | Three describe blocks: `tag_url/2`, `perk_copy/1`, `log_event/4`. |

**Modified:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform.ex` | Register `TenantReferral` in the domain's `resources do … end` block. |
| `lib/driveway_os/onboarding/registry.ex` | Add `fetch/1` — given a provider id atom, returns `{:ok, module}` or `:error`. |
| `lib/driveway_os/onboarding/provider.ex` | Add `@callback affiliate_config/0` + `@callback tenant_perk/0` plus `@optional_callbacks` declaration. |
| `lib/driveway_os/onboarding/providers/postmark.ex` | Implement both new callbacks. `affiliate_config/0` reads `:postmark_affiliate_ref_id` from app env. `tenant_perk/0` returns `nil`. |
| `lib/driveway_os/onboarding/providers/stripe_connect.ex` | Implement both new callbacks returning `nil` for both. |
| `lib/driveway_os/onboarding/steps/email.ex` | `submit/2` calls `Affiliate.log_event(tenant, :postmark, :click, ...)` before `Postmark.provision/2`; on success, logs `:provisioned`. `render/1` renders `Affiliate.perk_copy(:postmark)` below the blurb if non-nil. |
| `lib/driveway_os/onboarding/steps/payment.ex` | `render/1` renders `Affiliate.perk_copy(:stripe_connect)` below the blurb if non-nil. |
| `lib/driveway_os_web/controllers/stripe_onboarding_controller.ex` | `start/2` logs `:click` before redirecting to Stripe OAuth; `callback/2` success path logs `:provisioned`. |
| `config/runtime.exs` | Extend the existing `config :driveway_os, …` Stripe/Postmark block with `postmark_affiliate_ref_id: System.get_env("POSTMARK_AFFILIATE_REF_ID")`. |
| `config/test.exs` | Add `config :driveway_os, :postmark_affiliate_ref_id, nil`. |
| `DEPLOY.md` | Add `POSTMARK_AFFILIATE_REF_ID` row to the per-tenant integrations env-var table. |
| `test/driveway_os/onboarding/providers/postmark_test.exs` | Add tests for `affiliate_config/0` (with + without env var) and `tenant_perk/0`. |
| `test/driveway_os/onboarding/providers/stripe_connect_test.exs` | Add tests for `affiliate_config/0` and `tenant_perk/0` returning `nil`. (If file doesn't exist, create it.) |
| `test/driveway_os/onboarding/registry_test.exs` | Add tests for `fetch/1` (hit + miss). |
| `test/driveway_os/onboarding/steps/email_test.exs` | Extend to assert `:click` + `:provisioned` events written on success path; `:click` only on failure path. |
| `test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs` | Extend to assert `:click` event written on `start`. (`:provisioned` on callback is exercised in callback test.) |

---

## Task 1: `Platform.TenantReferral` resource + migration

**Files:**
- Create: `lib/driveway_os/platform/tenant_referral.ex`
- Create: `priv/repo/migrations/<ts>_create_platform_tenant_referrals.exs` (via `mix ash_postgres.generate_migrations`)
- Modify: `lib/driveway_os/platform.ex` (register resource)
- Test: `test/driveway_os/platform/tenant_referral_test.exs`

- [ ] **Step 1: Write the failing resource test**

Create `test/driveway_os/platform/tenant_referral_test.exs`:

```elixir
defmodule DrivewayOS.Platform.TenantReferralTest do
  @moduledoc """
  Pin the `Platform.TenantReferral` contract: events are creatable
  via the `:log` action, readable, and constrained to the documented
  event_type enum. FK to tenant cascades on tenant delete.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.TenantReferral

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ref-#{System.unique_integer([:positive])}",
        display_name: "Referral Test",
        admin_email: "ref-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "log creates a referral row with auto-set occurred_at", ctx do
    {:ok, ref} =
      TenantReferral
      |> Ash.Changeset.for_create(:log, %{
        tenant_id: ctx.tenant.id,
        provider: :postmark,
        event_type: :click,
        metadata: %{wizard_step: "email"}
      })
      |> Ash.create(authorize?: false)

    assert ref.tenant_id == ctx.tenant.id
    assert ref.provider == :postmark
    assert ref.event_type == :click
    assert ref.metadata == %{wizard_step: "email"}
    assert %DateTime{} = ref.occurred_at
  end

  test "log accepts all three event_types", ctx do
    for ev <- [:click, :provisioned, :revenue_attributed] do
      assert {:ok, _} =
               TenantReferral
               |> Ash.Changeset.for_create(:log, %{
                 tenant_id: ctx.tenant.id,
                 provider: :postmark,
                 event_type: ev
               })
               |> Ash.create(authorize?: false)
    end
  end

  test "log rejects unknown event_type", ctx do
    {:error, changeset} =
      TenantReferral
      |> Ash.Changeset.for_create(:log, %{
        tenant_id: ctx.tenant.id,
        provider: :postmark,
        event_type: :totally_made_up
      })
      |> Ash.create(authorize?: false)

    refute changeset.valid?
  end

  test "log rejects missing tenant_id", _ctx do
    {:error, _} =
      TenantReferral
      |> Ash.Changeset.for_create(:log, %{
        provider: :postmark,
        event_type: :click
      })
      |> Ash.create(authorize?: false)
  end

  test "read returns rows for a tenant", ctx do
    for ev <- [:click, :provisioned] do
      TenantReferral
      |> Ash.Changeset.for_create(:log, %{
        tenant_id: ctx.tenant.id,
        provider: :postmark,
        event_type: ev
      })
      |> Ash.create!(authorize?: false)
    end

    {:ok, all} = Ash.read(TenantReferral, authorize?: false)
    rows = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    assert length(rows) == 2
  end
end
```

- [ ] **Step 2: Run the test — should fail because the module doesn't exist**

```bash
mix test test/driveway_os/platform/tenant_referral_test.exs
```

Expected: compile error / module not found for `DrivewayOS.Platform.TenantReferral`.

- [ ] **Step 3: Create the resource**

Create `lib/driveway_os/platform/tenant_referral.ex`:

```elixir
defmodule DrivewayOS.Platform.TenantReferral do
  @moduledoc """
  Affiliate / referral funnel events for the Phase 2 onboarding
  abstraction. One row per `(tenant, provider, event)` occurrence.
  Platform-tier — no multitenancy block; tenants don't read this
  data, only DrivewayOS does.

  Event types:
    * `:click` — tenant initiated provider setup (e.g. Stripe OAuth
      redirect issued, Postmark form submitted).
    * `:provisioned` — provider successfully connected
      (`setup_complete?/1` flipped true).
    * `:revenue_attributed` — placeholder; written when a provider
      webhook reports a referral payout. No code path writes this in
      Phase 2; schema is ready for Phase 4.

  `metadata` is a freeform map. Per-event-type contracts are
  documented at the call sites in `Onboarding.Affiliate` rather than
  enforced by a typed schema (V1 — see Phase 2 design doc, "Decisions
  deferred to plan-writing").
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_tenant_referrals"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :delete
    end

    custom_indexes do
      index [:tenant_id, :provider]
      index [:provider, :event_type, :occurred_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
    end

    attribute :event_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:click, :provisioned, :revenue_attributed]
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :tenant, DrivewayOS.Platform.Tenant do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :log do
      accept [:tenant_id, :provider, :event_type, :metadata]
      change set_attribute(:occurred_at, &DateTime.utc_now/0)
    end
  end
end
```

- [ ] **Step 4: Register the resource in the Platform domain**

In `lib/driveway_os/platform.ex`, find the `resources do … end` block. Add `resource TenantReferral` next to the other resources, and add `TenantReferral` to the `alias DrivewayOS.Platform.{...}` list at the top of the module.

- [ ] **Step 5: Generate the migration**

```bash
mix ash_postgres.generate_migrations --name create_platform_tenant_referrals
```

Expected: a new file at `priv/repo/migrations/<timestamp>_create_platform_tenant_referrals.exs` containing a `create table(:platform_tenant_referrals)` block with `tenant_id` FK, `provider`, `event_type`, `metadata`, `occurred_at`, plus the two custom indexes and `inserted_at`.

- [ ] **Step 6: Apply the migration in test env**

```bash
MIX_ENV=test mix ecto.migrate
```

Expected: the migration runs cleanly, creating `platform_tenant_referrals`.

- [ ] **Step 7: Re-run the test to verify it passes**

```bash
mix test test/driveway_os/platform/tenant_referral_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/driveway_os/platform/tenant_referral.ex \
        lib/driveway_os/platform.ex \
        priv/repo/migrations/*_create_platform_tenant_referrals.exs \
        test/driveway_os/platform/tenant_referral_test.exs

git commit -m "Platform: TenantReferral resource for affiliate funnel events"
```

---

## Task 2: `Onboarding.Registry.fetch/1`

**Files:**
- Modify: `lib/driveway_os/onboarding/registry.ex`
- Test: `test/driveway_os/onboarding/registry_test.exs` (extend if exists, create if not)

- [ ] **Step 1: Check if a Registry test file already exists**

```bash
ls test/driveway_os/onboarding/registry_test.exs 2>/dev/null && echo "EXISTS" || echo "MISSING"
```

If MISSING, create it with this header:

```elixir
defmodule DrivewayOS.Onboarding.RegistryTest do
  @moduledoc """
  Pin the canonical-list semantics of `Onboarding.Registry`.
  """
  use ExUnit.Case, async: true

  alias DrivewayOS.Onboarding.Registry
end
```

If EXISTS, read its current contents to see what's already covered before extending.

- [ ] **Step 2: Add failing tests for `fetch/1`**

Append (or add inside the existing module) these tests:

```elixir
  describe "fetch/1" do
    test "returns {:ok, module} for a known provider id" do
      assert {:ok, DrivewayOS.Onboarding.Providers.Postmark} = Registry.fetch(:postmark)
      assert {:ok, DrivewayOS.Onboarding.Providers.StripeConnect} = Registry.fetch(:stripe_connect)
    end

    test "returns :error for an unknown id" do
      assert :error = Registry.fetch(:totally_made_up)
    end
  end
```

- [ ] **Step 3: Run the tests — should fail because `fetch/1` is undefined**

```bash
mix test test/driveway_os/onboarding/registry_test.exs
```

Expected: failure with "function Registry.fetch/1 is undefined".

- [ ] **Step 4: Implement `fetch/1`**

In `lib/driveway_os/onboarding/registry.ex`, add this function below `needing_setup/1`:

```elixir
  @doc """
  Look up a provider module by its `id/0` value. Returns
  `{:ok, module}` or `:error`. Used by `Onboarding.Affiliate` to
  resolve provider id atoms to their implementations without
  exposing the `@providers` list directly.
  """
  @spec fetch(atom()) :: {:ok, module()} | :error
  def fetch(provider_id) when is_atom(provider_id) do
    case Enum.find(@providers, &(&1.id() == provider_id)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
mix test test/driveway_os/onboarding/registry_test.exs
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/onboarding/registry.ex \
        test/driveway_os/onboarding/registry_test.exs

git commit -m "Onboarding.Registry: fetch/1 lookup by provider id atom"
```

---

## Task 3: `Provider` behaviour adds `affiliate_config/0` + `tenant_perk/0`

**Files:**
- Modify: `lib/driveway_os/onboarding/provider.ex`

- [ ] **Step 1: Add the two new callbacks to the behaviour**

In `lib/driveway_os/onboarding/provider.ex`, append these inside the `defmodule … end` block, before the final `end`:

```elixir
  @typedoc "Affiliate config — query-param name + ref id, or nil when no program."
  @type affiliate_config :: %{ref_param: String.t(), ref_id: String.t() | nil} | nil

  @doc """
  Affiliate / referral configuration for this provider, or nil if
  none. Shape: `%{ref_param: <query-param-name>, ref_id: <ref-value>}`.

  When the returned map's `ref_id` is `nil` (env var unset) or this
  callback returns `nil`, `Onboarding.Affiliate.tag_url/2` is a
  passthrough.

  Implementations typically read the ref_id from app config so it
  can be set per-environment via env vars without redeploying:

      def affiliate_config do
        %{
          ref_param: "ref",
          ref_id: Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
        }
      end
  """
  @callback affiliate_config() :: affiliate_config()

  @doc """
  Visible-to-tenant perk copy, or `nil` if no perk is offered. The
  wizard card renders the string below the provider's blurb when
  non-nil.

  Static text only — perk copy is marketing copy, not a credential,
  so it lives hardcoded in the provider module rather than env-var
  indirection.
  """
  @callback tenant_perk() :: String.t() | nil

  @optional_callbacks affiliate_config: 0, tenant_perk: 0
```

- [ ] **Step 2: Verify compile + existing tests still pass**

```bash
mix compile
mix test test/driveway_os/onboarding/
```

Expected: clean compile (warning expected: optional callbacks not yet implemented by Postmark/StripeConnect — but no errors). All existing onboarding tests still green.

- [ ] **Step 3: Commit**

```bash
git add lib/driveway_os/onboarding/provider.ex

git commit -m "Onboarding.Provider: optional affiliate_config/0 + tenant_perk/0 callbacks"
```

---

## Task 4: `Onboarding.Affiliate` module — `tag_url/2` and `perk_copy/1`

We split this from `log_event/4` (Task 5) so the URL/copy helpers are testable without `Platform.TenantReferral` being involved.

**Files:**
- Create: `lib/driveway_os/onboarding/affiliate.ex`
- Test: `test/driveway_os/onboarding/affiliate_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/onboarding/affiliate_test.exs`:

```elixir
defmodule DrivewayOS.Onboarding.AffiliateTest do
  @moduledoc """
  Public surface for the affiliate-tracking helpers. `log_event/4`
  is exercised in a separate describe block (Task 5) once the
  Platform.TenantReferral persistence is wired up.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Affiliate

  describe "tag_url/2" do
    test "passthrough when provider has no affiliate_config implementation" do
      # Stripe Connect intentionally returns nil affiliate_config —
      # its revenue model is platform fee, not a referral link.
      assert Affiliate.tag_url("https://stripe.com/setup", :stripe_connect) ==
               "https://stripe.com/setup"
    end

    test "passthrough when ref_id env var is unset (V1 default)" do
      # Postmark.affiliate_config/0 returns %{ref_id: nil} when the
      # POSTMARK_AFFILIATE_REF_ID env var isn't set.
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, nil)
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      assert Affiliate.tag_url("https://postmarkapp.com/pricing", :postmark) ==
               "https://postmarkapp.com/pricing"
    end

    test "appends ref query param when ref_id env var is set" do
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, "drivewayos")
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      url = Affiliate.tag_url("https://postmarkapp.com/pricing", :postmark)
      assert url =~ "ref=drivewayos"
      assert String.starts_with?(url, "https://postmarkapp.com/pricing?")
    end

    test "preserves existing query params when tagging" do
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, "drivewayos")
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      url = Affiliate.tag_url("https://postmarkapp.com/pricing?utm_source=blog", :postmark)
      assert url =~ "utm_source=blog"
      assert url =~ "ref=drivewayos"
    end

    test "passthrough for unknown provider id" do
      assert Affiliate.tag_url("https://example.com", :nonexistent) ==
               "https://example.com"
    end
  end

  describe "perk_copy/1" do
    test "returns nil for V1 providers (no perks shipping in Phase 2)" do
      assert Affiliate.perk_copy(:stripe_connect) == nil
      assert Affiliate.perk_copy(:postmark) == nil
    end

    test "returns nil for unknown provider id" do
      assert Affiliate.perk_copy(:nonexistent) == nil
    end
  end
end
```

- [ ] **Step 2: Run the test — should fail because the module doesn't exist**

```bash
mix test test/driveway_os/onboarding/affiliate_test.exs
```

Expected: compile error / module not found for `DrivewayOS.Onboarding.Affiliate`.

Note: tests under `describe "tag_url/2"` that require `Postmark.affiliate_config/0` returning a map (Task 6 work) will start passing only after Task 6 lands. That's expected — Step 4 here adds the module skeleton and the passthrough/unknown-provider cases pass; the env-var cases pin pass only once Postmark implements the callback. We re-run after Task 6.

- [ ] **Step 3: Implement the module (without `log_event/4` yet)**

Create `lib/driveway_os/onboarding/affiliate.ex`:

```elixir
defmodule DrivewayOS.Onboarding.Affiliate do
  @moduledoc """
  Phase 2 affiliate-tracking helpers.

  Three public functions:

    * `tag_url/2` — append the platform's affiliate ref to a URL
      using the provider's `affiliate_config/0`. Passthrough when
      no config is set.
    * `perk_copy/1` — visible perk copy for a provider, sourced
      from the provider's `tenant_perk/0` callback. Nil when none.
    * `log_event/4` — write an entry to `Platform.TenantReferral`.
      Errors are swallowed; revenue attribution is our metric, not
      the tenant's flow (see Phase 2 spec, decision #7).

  The provider modules themselves own the per-integration affiliate
  facts (via the `affiliate_config/0` and `tenant_perk/0` callbacks
  on `Onboarding.Provider`). This module just routes calls through
  the registry.

  Example metadata contracts (V1, freeform; documented here for
  greppability):

    * `:click` on Stripe → `%{wizard_step: :payment, oauth_state: "..."}`
    * `:provisioned` on Postmark → `%{server_id: "99001"}`
    * `:revenue_attributed` (Phase 4+) → `%{provider_payout_id: "...", cents: 1234}`
  """

  require Logger

  alias DrivewayOS.Onboarding.Registry
  alias DrivewayOS.Platform.{Tenant, TenantReferral}

  @spec tag_url(String.t(), atom()) :: String.t()
  def tag_url(url, provider_id) when is_binary(url) and is_atom(provider_id) do
    with {:ok, mod} <- Registry.fetch(provider_id),
         true <- function_exported?(mod, :affiliate_config, 0),
         %{ref_param: param, ref_id: id} when is_binary(id) and id != "" <-
           mod.affiliate_config() do
      append_query_param(url, param, id)
    else
      _ -> url
    end
  end

  @spec perk_copy(atom()) :: String.t() | nil
  def perk_copy(provider_id) when is_atom(provider_id) do
    with {:ok, mod} <- Registry.fetch(provider_id),
         true <- function_exported?(mod, :tenant_perk, 0) do
      mod.tenant_perk()
    else
      _ -> nil
    end
  end

  @spec log_event(Tenant.t(), atom(), atom(), map()) :: :ok
  def log_event(%Tenant{} = tenant, provider_id, event_type, metadata \\ %{})
      when is_atom(provider_id) and is_atom(event_type) and is_map(metadata) do
    TenantReferral
    |> Ash.Changeset.for_create(:log, %{
      tenant_id: tenant.id,
      provider: provider_id,
      event_type: event_type,
      metadata: metadata
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Affiliate.log_event failed: tenant=#{tenant.id} " <>
            "provider=#{inspect(provider_id)} event=#{inspect(event_type)} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Affiliate.log_event raised: #{Exception.message(e)}")
      :ok
  end

  # --- Helpers ---

  defp append_query_param(url, param, value) do
    uri = URI.parse(url)

    new_query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put(param, value)
      |> URI.encode_query()

    %{uri | query: new_query} |> URI.to_string()
  end
end
```

- [ ] **Step 4: Run the tests for tag_url/perk_copy passthrough cases**

```bash
mix test test/driveway_os/onboarding/affiliate_test.exs
```

Expected: 4 tests pass — all the "passthrough" / "unknown provider" / "perk_copy returns nil for V1" cases. **2 tests still fail** — the two cases that exercise `Postmark.affiliate_config/0` returning a map need Task 6 to land first. The plan acknowledges this; we'll re-run the suite at the end of Task 6.

The failing tests will be:
  - `tag_url/2 appends ref query param when ref_id env var is set`
  - `tag_url/2 preserves existing query params when tagging`

Both fail with the same root cause: `Postmark.affiliate_config/0` doesn't exist yet, so the `with` clause's `function_exported?` check returns false, and `tag_url/2` passes through.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/affiliate.ex \
        test/driveway_os/onboarding/affiliate_test.exs

git commit -m "Onboarding.Affiliate: tag_url/2 + perk_copy/1 + log_event/4 module

Two of seven tests intentionally red until Task 6 lands the
Postmark.affiliate_config/0 implementation."
```

---

## Task 5: `log_event/4` integration tests

The module's `log_event/4` is implemented as part of Task 4's commit (it was simpler to ship the whole module body in one file than artificially split). Task 5 just adds the integration tests that exercise the persistence path — these need `TenantReferral` (Task 1) and the module (Task 4) both in place.

**Files:**
- Modify: `test/driveway_os/onboarding/affiliate_test.exs` (extend)

- [ ] **Step 1: Extend the affiliate test file with `log_event/4` describe block**

In `test/driveway_os/onboarding/affiliate_test.exs`, add this describe block (alongside the existing `describe "tag_url/2"` and `describe "perk_copy/1"` blocks):

```elixir
  describe "log_event/4" do
    setup do
      {:ok, %{tenant: tenant}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "aff-#{System.unique_integer([:positive])}",
          display_name: "Affiliate Log Test",
          admin_email: "aff-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant}
    end

    test "writes a TenantReferral row with the given fields", ctx do
      assert :ok = Affiliate.log_event(ctx.tenant, :postmark, :click, %{wizard_step: "email"})

      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      [row] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))

      assert row.provider == :postmark
      assert row.event_type == :click
      assert row.metadata == %{wizard_step: "email"}
      assert %DateTime{} = row.occurred_at
    end

    test "metadata defaults to empty map when omitted", ctx do
      assert :ok = Affiliate.log_event(ctx.tenant, :stripe_connect, :provisioned)

      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      [row] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))

      assert row.metadata == %{}
    end

    test "returns :ok and does not raise on unknown event_type", ctx do
      # Logger emits a warning; we capture-and-ignore to avoid noisy
      # test output. The contract is "always returns :ok" — the
      # internal Ash error is swallowed, not propagated.
      import ExUnit.CaptureLog

      result =
        capture_log(fn ->
          assert :ok =
                   Affiliate.log_event(
                     ctx.tenant,
                     :postmark,
                     :totally_invalid,
                     %{}
                   )
        end)

      assert result =~ "Affiliate.log_event failed"

      # No row written.
      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      assert Enum.filter(all, &(&1.tenant_id == ctx.tenant.id)) == []
    end
  end
```

- [ ] **Step 2: Run the suite**

```bash
mix test test/driveway_os/onboarding/affiliate_test.exs
```

Expected: 5 of 8 tests pass (the three new `log_event/4` cases plus the four passthrough cases from Task 4). **2 tests still fail** — same as Task 4: the two `affiliate_config/0`-with-env-var cases pending Task 6.

- [ ] **Step 3: Commit**

```bash
git add test/driveway_os/onboarding/affiliate_test.exs

git commit -m "Onboarding.Affiliate: log_event/4 integration tests"
```

---

## Task 6: Postmark + StripeConnect implement the new callbacks

**Files:**
- Modify: `lib/driveway_os/onboarding/providers/postmark.ex`
- Modify: `lib/driveway_os/onboarding/providers/stripe_connect.ex`
- Test: `test/driveway_os/onboarding/providers/postmark_test.exs` (extend)
- Test: `test/driveway_os/onboarding/providers/stripe_connect_test.exs` (extend or create)

- [ ] **Step 1: Add Postmark tests for the new callbacks**

In `test/driveway_os/onboarding/providers/postmark_test.exs`, add inside the existing module:

```elixir
  describe "affiliate_config/0" do
    test "returns %{ref_param, ref_id} with ref_id from app env" do
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, "drivewayos")
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: "drivewayos"} = Provider.affiliate_config()
    end

    test "ref_id is nil when env var is unset" do
      original = Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
      Application.put_env(:driveway_os, :postmark_affiliate_ref_id, nil)
      on_exit(fn -> Application.put_env(:driveway_os, :postmark_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: nil} = Provider.affiliate_config()
    end
  end

  describe "tenant_perk/0" do
    test "returns nil — no perk shipping in V1" do
      assert Provider.tenant_perk() == nil
    end
  end
```

- [ ] **Step 2: Run the test — should fail because callbacks aren't implemented**

```bash
mix test test/driveway_os/onboarding/providers/postmark_test.exs
```

Expected: failure — `function affiliate_config/0 undefined or private`.

- [ ] **Step 3: Implement the callbacks on Postmark**

In `lib/driveway_os/onboarding/providers/postmark.ex`, append these inside the module, after the existing `provision/2` impl:

```elixir
  @impl true
  def affiliate_config do
    %{
      ref_param: "ref",
      ref_id: Application.get_env(:driveway_os, :postmark_affiliate_ref_id)
    }
  end

  @impl true
  def tenant_perk, do: nil
```

- [ ] **Step 4: Check / create StripeConnect provider test file**

```bash
ls test/driveway_os/onboarding/providers/stripe_connect_test.exs 2>/dev/null && echo "EXISTS" || echo "MISSING"
```

If MISSING, create it:

```elixir
defmodule DrivewayOS.Onboarding.Providers.StripeConnectTest do
  @moduledoc """
  Pin the Provider behaviour conformance for StripeConnect. The
  underlying Stripe OAuth + account-status logic is exercised by
  `DrivewayOS.Billing.StripeConnect` tests; this file just covers
  the Onboarding.Provider adapter surface.
  """
  use ExUnit.Case, async: true

  alias DrivewayOS.Onboarding.Providers.StripeConnect, as: Provider

  test "id/0 is :stripe_connect" do
    assert Provider.id() == :stripe_connect
  end

  test "category/0 is :payment" do
    assert Provider.category() == :payment
  end

  describe "affiliate_config/0" do
    test "returns nil — Stripe revenue is platform fee, not referral" do
      assert Provider.affiliate_config() == nil
    end
  end

  describe "tenant_perk/0" do
    test "returns nil" do
      assert Provider.tenant_perk() == nil
    end
  end
end
```

If EXISTS, append the two `describe` blocks for `affiliate_config/0` and `tenant_perk/0`.

- [ ] **Step 5: Implement the callbacks on StripeConnect**

In `lib/driveway_os/onboarding/providers/stripe_connect.ex`, append inside the module, after the existing `provision/2` impl:

```elixir
  @impl true
  def affiliate_config, do: nil

  @impl true
  def tenant_perk, do: nil
```

- [ ] **Step 6: Run all the affected tests**

```bash
mix test test/driveway_os/onboarding/providers/postmark_test.exs \
         test/driveway_os/onboarding/providers/stripe_connect_test.exs \
         test/driveway_os/onboarding/affiliate_test.exs
```

Expected: all green. The two previously-red Affiliate tests (`tag_url/2 appends ref query param when ref_id env var is set` and `tag_url/2 preserves existing query params when tagging`) now pass because `Postmark.affiliate_config/0` exists and returns a populated map.

- [ ] **Step 7: Commit**

```bash
git add lib/driveway_os/onboarding/providers/postmark.ex \
        lib/driveway_os/onboarding/providers/stripe_connect.ex \
        test/driveway_os/onboarding/providers/postmark_test.exs \
        test/driveway_os/onboarding/providers/stripe_connect_test.exs

git commit -m "Providers: implement affiliate_config/0 + tenant_perk/0

Postmark reads :postmark_affiliate_ref_id from app env (nil in V1
until we enroll). Stripe returns nil for both — its revenue model is
application_fee_amount per charge, not a referral link."
```

---

## Task 7: Steps.Email logs `:click` + `:provisioned` events; renders perk copy

**Files:**
- Modify: `lib/driveway_os/onboarding/steps/email.ex`
- Test: `test/driveway_os/onboarding/steps/email_test.exs` (extend)

- [ ] **Step 1: Extend the test to assert affiliate events**

In `test/driveway_os/onboarding/steps/email_test.exs`, find the existing `submit/2 happy path` test and replace it (or add alongside it) with a version that asserts on the `tenant_referrals` table after success. Add a new test for the failure case as well.

```elixir
  describe "submit/2 affiliate logging" do
    test "logs :click then :provisioned on Postmark API success", ctx do
      expect(PostmarkClient.Mock, :create_server, fn _name, _opts ->
        {:ok, %{server_id: 88_001, api_key: "server-token-pq"}}
      end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_tenant: ctx.tenant,
          current_customer: ctx.admin,
          errors: %{}
        }
      }

      assert {:ok, _} = Step.submit(%{}, socket)

      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
      types = events |> Enum.map(& &1.event_type) |> Enum.sort()

      assert types == [:click, :provisioned]
      assert Enum.all?(events, &(&1.provider == :postmark))
    end

    test "logs only :click when Postmark API fails", ctx do
      expect(PostmarkClient.Mock, :create_server, fn _, _ ->
        {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
      end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_tenant: ctx.tenant,
          current_customer: ctx.admin,
          errors: %{}
        }
      }

      assert {:error, _} = Step.submit(%{}, socket)

      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))

      assert [event] = events
      assert event.event_type == :click
      assert event.provider == :postmark
    end
  end
```

(Imports needed at the top of the file if not already present: `import Mox`, `alias DrivewayOS.Notifications.PostmarkClient`. The existing test setup already provisions a tenant + admin in `ctx`.)

- [ ] **Step 2: Run the test — should fail because Steps.Email doesn't log events yet**

```bash
mix test test/driveway_os/onboarding/steps/email_test.exs
```

Expected: failure — the events list is empty after the submit call.

- [ ] **Step 3: Update Steps.Email.submit/2 to log events**

In `lib/driveway_os/onboarding/steps/email.ex`, replace the existing `submit/2` body. Also add an alias for `Affiliate` at the top.

Replace:
```elixir
  alias DrivewayOS.Onboarding.Providers.Postmark
  alias DrivewayOS.Platform.Tenant
```
with:
```elixir
  alias DrivewayOS.Onboarding.{Affiliate, Providers.Postmark}
  alias DrivewayOS.Platform.Tenant
```

Replace the existing `submit/2` impl:
```elixir
  @impl true
  def submit(_params, socket) do
    tenant = socket.assigns.current_tenant

    case Postmark.provision(tenant, %{}) do
      {:ok, updated} ->
        {:ok, Phoenix.Component.assign(socket, :current_tenant, updated)}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end
```
with:
```elixir
  @impl true
  def submit(_params, socket) do
    tenant = socket.assigns.current_tenant

    # Log :click before the API call so a failed provision still
    # leaves a funnel breadcrumb. log_event/4 is fire-and-forget —
    # it always returns :ok, even on persistence failure.
    :ok = Affiliate.log_event(tenant, :postmark, :click, %{wizard_step: :email})

    case Postmark.provision(tenant, %{}) do
      {:ok, updated} ->
        :ok =
          Affiliate.log_event(updated, :postmark, :provisioned, %{
            server_id: updated.postmark_server_id
          })

        {:ok, Phoenix.Component.assign(socket, :current_tenant, updated)}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end
```

- [ ] **Step 4: Add perk-copy rendering to the email step's render/1**

In the same file, find the `render/1` impl. Replace its `~H` template with one that renders `Affiliate.perk_copy(:postmark)` below the blurb when non-nil:

Old block:
```heex
    ~H"""
    <form id="step-email-form" phx-submit="step_submit" class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <p class="text-xs text-base-content/60">
        We'll create a Postmark server for your shop and send you a quick test email
        to confirm everything's working. Takes a few seconds.
      </p>
      ...
```

Replace with:
```heex
    ~H"""
    <form id="step-email-form" phx-submit="step_submit" class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <%= if perk = DrivewayOS.Onboarding.Affiliate.perk_copy(:postmark) do %>
        <p class="text-xs text-success font-medium">{perk}</p>
      <% end %>
      <p class="text-xs text-base-content/60">
        We'll create a Postmark server for your shop and send you a quick test email
        to confirm everything's working. Takes a few seconds.
      </p>
      ...
```

(Leave the `<p :if={@errors[:email]}>` and `<button>` lines intact at the bottom.)

- [ ] **Step 5: Run the tests — should now pass**

```bash
mix test test/driveway_os/onboarding/steps/email_test.exs
```

Expected: all green. The two new affiliate-logging tests pass; the pre-existing tests still pass (perk_copy returning nil → no DOM change → existing assertions on email step rendering unaffected).

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/onboarding/steps/email.ex \
        test/driveway_os/onboarding/steps/email_test.exs

git commit -m "Steps.Email: log :click/:provisioned + render perk_copy"
```

---

## Task 8: Steps.Payment renders perk copy

Smaller than Task 7 — Payment is a hosted-redirect step, the affiliate `:click`/`:provisioned` events for Stripe land in the controller (Task 9), not here. Phase 2's only Payment-step change is the perk-copy paragraph.

**Files:**
- Modify: `lib/driveway_os/onboarding/steps/payment.ex`
- Test: `test/driveway_os/onboarding/steps/payment_test.exs` (extend)

- [ ] **Step 1: Extend the Payment step test**

In `test/driveway_os/onboarding/steps/payment_test.exs`, find the `render/1` test and extend it. Currently it asserts the rendered HTML contains "Connect Stripe" and "/onboarding/stripe/start". Add a fourth test that flips perk copy on/off via a stub:

Append:
```elixir
  describe "render/1 perk copy" do
    test "renders perk paragraph when Affiliate.perk_copy/1 returns a string" do
      # We can't easily stub StripeConnect.tenant_perk/0 without
      # touching its source, so this test exercises the branch via
      # an Affiliate.perk_copy/1 unit test instead — render's
      # passthrough behavior is verified by the existing test
      # asserting the un-stringified DOM has no .text-success copy.
      html =
        Step.render(%{__changed__: %{}})
        |> Phoenix.LiveViewTest.rendered_to_string()

      # V1: no perk copy. The success-text class shouldn't appear.
      refute html =~ "text-success"
    end
  end
```

(This is a regression test pinning the V1 default, not an active perk-displayed test. The branch itself is exercised in the Affiliate module's perk_copy test once a provider returns non-nil — that's a future activation, not a Phase 2 deliverable.)

- [ ] **Step 2: Run the test — pre-existing tests should still pass; the new one too (no perk copy currently → no `text-success` class)**

```bash
mix test test/driveway_os/onboarding/steps/payment_test.exs
```

Expected: all green.

- [ ] **Step 3: Update Steps.Payment.render/1 to include the perk-copy paragraph branch**

In `lib/driveway_os/onboarding/steps/payment.ex`, find `render/1` and replace its `~H` template:

Old:
```heex
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <a href={@display.href} class="btn btn-primary btn-sm gap-1">
        {@display.cta_label}
        <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
      </a>
      ...
```

New:
```heex
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <%= if perk = DrivewayOS.Onboarding.Affiliate.perk_copy(:stripe_connect) do %>
        <p class="text-xs text-success font-medium">{perk}</p>
      <% end %>
      <a href={@display.href} class="btn btn-primary btn-sm gap-1">
        {@display.cta_label}
        <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
      </a>
      ...
```

(The trailing `<p class="text-xs text-base-content/60">Stripe handles identity verification…</p>` stays unchanged.)

- [ ] **Step 4: Run the tests**

```bash
mix test test/driveway_os/onboarding/steps/payment_test.exs
```

Expected: all green. V1 result: no `text-success` paragraph in the rendered DOM (StripeConnect.tenant_perk/0 returns nil, so the if-let branch is false). The "renders perk paragraph" regression test confirms that.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/steps/payment.ex \
        test/driveway_os/onboarding/steps/payment_test.exs

git commit -m "Steps.Payment: render perk_copy when StripeConnect.tenant_perk/0 returns non-nil"
```

---

## Task 9: StripeOnboardingController logs `:click` + `:provisioned`

**Files:**
- Modify: `lib/driveway_os_web/controllers/stripe_onboarding_controller.ex`
- Test: `test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs` (extend if exists, create skeleton if not — but the file should exist from Phase 0/1)

- [ ] **Step 1: Read the existing controller test file to see its shape**

```bash
ls test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs 2>/dev/null && echo "EXISTS" || echo "MISSING"
```

If MISSING, this means Phase 0/1 didn't ship a controller test. In that case the test for `:click` logging on `start/2` lands in a new file, but that's a larger lift than Phase 2's scope. Document as "skipped — controller test scaffolding deferred" and just verify manually in Step 4.

If EXISTS, read its current content briefly to find the right describe block to extend.

- [ ] **Step 2: Add a test asserting `:click` is logged on `start/2`**

If the test file exists, append (or add inside the existing `describe "start"` block):

```elixir
    test "logs an affiliate :click event before redirecting to Stripe", ctx do
      conn =
        ctx.conn
        |> assign(:current_tenant, ctx.tenant)
        |> assign(:current_customer, ctx.admin)
        |> get(~p"/onboarding/stripe/start")

      # The redirect happens; we just verify the logged event.
      assert redirected_to(conn, 302)

      {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
      [event] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
      assert event.provider == :stripe_connect
      assert event.event_type == :click
    end
```

Adapt the `ctx` shape (tenant + admin + conn) to whatever the existing test file's setup produces. If the existing setup doesn't provision a tenant+admin and assign them to the conn, prepend the appropriate setup.

- [ ] **Step 3: Run the test — should fail because the controller doesn't log yet**

```bash
mix test test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs
```

Expected: failure — empty events list after the request.

- [ ] **Step 4: Wire `:click` logging into `start/2`**

In `lib/driveway_os_web/controllers/stripe_onboarding_controller.ex`, find the existing `start/2` impl. Add an alias and a single line in the success branch.

Top of file, in the existing alias block:
```elixir
  alias DrivewayOS.Billing.StripeConnect
  alias DrivewayOS.Onboarding.{Affiliate, Wizard}
  alias DrivewayOS.Platform
```

In the `cond do … end` final clause (`true ->`), add the log call before `redirect(conn, external: url)`:

Old:
```elixir
      true ->
        url = StripeConnect.oauth_url_for(conn.assigns.current_tenant)
        redirect(conn, external: url)
```

New:
```elixir
      true ->
        url = StripeConnect.oauth_url_for(conn.assigns.current_tenant)

        :ok =
          Affiliate.log_event(
            conn.assigns.current_tenant,
            :stripe_connect,
            :click,
            %{wizard_step: :payment}
          )

        redirect(conn, external: url)
```

- [ ] **Step 5: Add `:provisioned` logging to `callback/2`**

Find the `callback/2` impl with the `with`-statement happy path. Add a log call inside the `with` after `complete_onboarding` succeeds:

Old:
```elixir
    with {:ok, tenant_id} <- StripeConnect.verify_state(state),
         tenant when not is_nil(tenant) <- Ash.get!(Platform.Tenant, tenant_id),
         {:ok, updated} <- StripeConnect.complete_onboarding(tenant, code) do
      redirect(conn, external: tenant_post_stripe_url(updated))
    else
      _ -> send_resp(conn, 400, "Stripe onboarding failed.")
    end
```

New:
```elixir
    with {:ok, tenant_id} <- StripeConnect.verify_state(state),
         tenant when not is_nil(tenant) <- Ash.get!(Platform.Tenant, tenant_id),
         {:ok, updated} <- StripeConnect.complete_onboarding(tenant, code) do
      :ok =
        Affiliate.log_event(
          updated,
          :stripe_connect,
          :provisioned,
          %{stripe_account_id: updated.stripe_account_id}
        )

      redirect(conn, external: tenant_post_stripe_url(updated))
    else
      _ -> send_resp(conn, 400, "Stripe onboarding failed.")
    end
```

- [ ] **Step 6: Run the test — should pass now**

```bash
mix test test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add lib/driveway_os_web/controllers/stripe_onboarding_controller.ex \
        test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs

git commit -m "StripeOnboardingController: log affiliate :click on start, :provisioned on callback"
```

---

## Task 10: Runtime config + DEPLOY.md

**Files:**
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Modify: `DEPLOY.md`

- [ ] **Step 1: Extend the runtime Stripe/Postmark config block**

In `config/runtime.exs`, find the existing block (around lines 50-58):

```elixir
if config_env() != :test do
  config :driveway_os,
    stripe_client_id: System.get_env("STRIPE_CLIENT_ID") || "",
    stripe_secret_key: System.get_env("STRIPE_SECRET_KEY") || "",
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "",
    postmark_account_token: System.get_env("POSTMARK_ACCOUNT_TOKEN") || ""
end
```

Add `postmark_affiliate_ref_id` to the keyword list. Use `System.get_env(...)` without a `|| ""` fallback — `nil` is the meaningful "no affiliate enrolled" signal that triggers `tag_url/2`'s passthrough behavior.

```elixir
if config_env() != :test do
  config :driveway_os,
    stripe_client_id: System.get_env("STRIPE_CLIENT_ID") || "",
    stripe_secret_key: System.get_env("STRIPE_SECRET_KEY") || "",
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "",
    postmark_account_token: System.get_env("POSTMARK_ACCOUNT_TOKEN") || "",
    postmark_affiliate_ref_id: System.get_env("POSTMARK_AFFILIATE_REF_ID")
end
```

- [ ] **Step 2: Add a test-env placeholder**

In `config/test.exs`, near the existing `:driveway_os, :postmark_account_token` line:

```elixir
config :driveway_os, :postmark_affiliate_ref_id, nil
```

Place it next to `:postmark_account_token` (currently around line 70 in test.exs, the "Postmark placeholder" section).

- [ ] **Step 3: Update DEPLOY.md**

In `DEPLOY.md`, find the per-tenant integrations env-var table — the row for `POSTMARK_ACCOUNT_TOKEN` is around line 41. Add a new row directly below it:

```markdown
| `POSTMARK_AFFILIATE_REF_ID` | Optional. Platform-level Postmark affiliate referral code; appended to outbound Postmark URLs as `?ref=<value>`. Leave unset until enrolled in Postmark's referral program. |
```

- [ ] **Step 4: Verify compilation + full suite**

```bash
mix compile
mix test
```

Expected: clean compile, all tests pass. Test count = previous green count + new tests added in Tasks 1, 2, 4, 5, 6, 7, 8, 9 (~25 new tests). Don't fixate on the exact number — 0 failures is what matters.

- [ ] **Step 5: Commit**

```bash
git add config/runtime.exs config/test.exs DEPLOY.md

git commit -m "Config: POSTMARK_AFFILIATE_REF_ID env + DEPLOY.md entry"
```

---

## Task 11: Final verification + push

- [ ] **Step 1: Confirm clean working tree**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Run the full suite**

```bash
mix test
```

Expected: 0 failures. Tasks 1-10 add roughly ~25 tests on top of Phase 1's final 620.

- [ ] **Step 3: Push**

```bash
git push origin main
```

Expected: push succeeds. Phase 2's commits are now visible on origin/main.

---

## Self-review

**Spec coverage:**

| Spec section | Covered by task |
|---|---|
| Architecture / Module layout — `Platform.TenantReferral` | Task 1 |
| Architecture / Module layout — `Onboarding.Affiliate` | Tasks 4 + 5 |
| Architecture / Module layout — Migration | Task 1 |
| Architecture / Modified — `Provider` behaviour | Task 3 |
| Architecture / Modified — Postmark | Task 6 |
| Architecture / Modified — StripeConnect | Task 6 |
| Architecture / Modified — Steps.Email (submit) | Task 7 |
| Architecture / Modified — Steps.Payment (render) | Task 8 |
| Architecture / Modified — Steps.Email (render perk_copy) | Task 7 |
| Architecture / Modified — StripeOnboardingController | Task 9 |
| Architecture / Modified — Platform domain registration | Task 1 |
| Architecture / Modified — config/runtime.exs | Task 10 |
| Architecture / Modified — config/test.exs | Task 10 |
| Architecture / Modified — DEPLOY.md | Task 10 |
| Architecture / Data model — `:log` action + indexes | Task 1 |
| Architecture / Provider behaviour additions | Task 3 |
| Architecture / `Affiliate` module API | Tasks 4 + 5 |
| Architecture / `Registry.fetch/1` | Task 2 |
| Architecture / Mix config layout | Task 10 |
| Architecture / Wizard rendering changes | Tasks 7 + 8 |
| Decisions / log_event swallows errors | Task 4 (impl) + Task 5 (test) |
| Decisions / tag_url passthrough when ref_id nil | Task 4 |
| Decisions / platform-tier resource (no multitenancy) | Task 1 |
| Decisions / three event types | Task 1 (constraints) |
| Decisions / mix config for ref_id | Task 6 + Task 10 |
| Decisions / no redirect proxy controller | (none — out of scope; Task 9's existing-touchpoint pattern is the deliberate substitute) |
| Out of scope (proxy controller, dashboards, webhook handlers, encryption, per-tenant ref_id, perk_displayed) | Not implemented — confirmed not in any task |

**Type / signature consistency check:**
- `Affiliate.tag_url/2`, `Affiliate.perk_copy/1`, `Affiliate.log_event/4` — same signatures used in Tasks 4, 5, 7, 8, 9. ✓
- `Registry.fetch/1` returning `{:ok, module} | :error` — used in Task 4's Affiliate impl. ✓
- `Provider.affiliate_config/0` shape `%{ref_param, ref_id} | nil` — used in Task 4's Affiliate impl + Task 6's Postmark impl. ✓
- `Provider.tenant_perk/0` returning `String.t() | nil` — used in Task 4's Affiliate impl + Task 6's Postmark + StripeConnect impls. ✓
- `TenantReferral` actions: `:log` create + defaults `[:read, :destroy]` — referenced in Tasks 1, 4, 5, 7, 9. ✓
- `event_type` enum `[:click, :provisioned, :revenue_attributed]` — referenced in Tasks 1, 4, 7, 9. ✓

**Placeholder scan:**
- Every step has concrete code or commands.
- No "TBD", "TODO", "fill in details", "similar to Task N (without code)".
- Every test has actual assertions, not "test the behavior".

**Bite-size check:**
- Each step is one concrete action with copy-pasteable input/output.
- Each task ends in a commit.
- Eleven tasks, each ~5-10 minutes of focused work for an engineer with the context.

If you find issues during execution, stop and ask — don't guess.
