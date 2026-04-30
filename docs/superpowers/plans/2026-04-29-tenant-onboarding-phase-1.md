# Tenant Onboarding Phase 1 — Mandatory Wizard + Postmark

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the mandatory linear wizard at `/admin/onboarding` that walks a freshly-provisioned tenant through Branding → Services → Schedule → Payment → Email, plus the first API-first email provider (Postmark) so booking confirmations actually deliver.

**Architecture:** Pure-function FSM (`Onboarding.Wizard`) backed by a jsonb `wizard_progress` map on Tenant that only persists `:skipped` flags. Per-step modules implement an `Onboarding.Step` behaviour. The Phase 0 `Onboarding.Provider` behaviour gains a `provision/2` callback; Stripe Connect returns `{:error, :hosted_required}`, Postmark fully provisions via API. Welcome email after provisioning is the verification probe. Signup redirects to `/admin/onboarding`.

**Tech Stack:** Elixir 1.18 / Phoenix LiveView 1.1 / Ash 3.24 / AshPostgres 2.9 / Swoosh (Postmark adapter) / Req (Postmark HTTP). Tests use ExUnit with `DrivewayOSWeb.ConnCase` and `DrivewayOS.DataCase`. Standard test command: `mix test`. The Postmark account-level token is read from `POSTMARK_ACCOUNT_TOKEN` env var.

**Spec:** `docs/superpowers/specs/2026-04-29-tenant-onboarding-phase-1-design.md` — read the "Architecture" + "Per-step decisions" sections before starting.

**Phase 0 (already shipped):** `docs/superpowers/plans/2026-04-28-tenant-onboarding-phase-0.md`. Provides `Onboarding.Provider` behaviour, `Registry`, `Providers.StripeConnect`, and an `OnboardingWizardLive` stub at `/admin/onboarding` that this phase replaces.

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `priv/repo/migrations/<ts>_add_wizard_progress_and_postmark_to_tenants.exs` | Adds `wizard_progress :map` (default `%{}`), `postmark_server_id :string`, `postmark_api_key :string` to `tenants`. |
| `lib/driveway_os/onboarding/step.ex` | `Step` behaviour: `id/0`, `title/0`, `complete?/1`, `render/1`, `submit/2`. |
| `lib/driveway_os/onboarding/wizard.ex` | Pure-function FSM. `steps/0`, `current_step/1`, `complete?/1`, `skip/2`, `unskip/2`, `skipped?/2`. |
| `lib/driveway_os/onboarding/steps/branding.ex` | Branding step. `complete?` ↔ `support_email` set. |
| `lib/driveway_os/onboarding/steps/services.ex` | Services step. `complete?` ↔ `not Platform.using_default_services?`. |
| `lib/driveway_os/onboarding/steps/schedule.ex` | Schedule step. `complete?` ↔ at least one BlockTemplate. |
| `lib/driveway_os/onboarding/steps/payment.ex` | Payment step — delegates to `Providers.StripeConnect.setup_complete?`. |
| `lib/driveway_os/onboarding/steps/email.ex` | Email step — delegates to `Providers.Postmark`. |
| `lib/driveway_os/onboarding/providers/postmark.ex` | Postmark provider. Implements `Onboarding.Provider` including the new `provision/2` callback. |
| `lib/driveway_os/notifications/postmark_client.ex` | HTTP wrapper over `api.postmarkapp.com`. Defines `PostmarkClient` behaviour for mocking. |
| `lib/driveway_os/notifications/postmark_client/http.ex` | Concrete HTTP impl using `Req`. |
| `test/driveway_os/onboarding/wizard_test.exs` | 8-test suite covering FSM helpers. |
| `test/driveway_os/onboarding/steps/branding_test.exs` | `complete?` predicate test. |
| `test/driveway_os/onboarding/steps/services_test.exs` | Same shape. |
| `test/driveway_os/onboarding/steps/schedule_test.exs` | Same shape. |
| `test/driveway_os/onboarding/steps/email_test.exs` | Same shape + `submit/2` with mocked Postmark client. |
| `test/driveway_os/onboarding/providers/postmark_test.exs` | Provider behaviour conformance + `provision/2` happy path + error paths. |
| `test/driveway_os/notifications/postmark_client_test.exs` | HTTP wrapper unit test (response parsing) + Mox-style mock. |

**Modified:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform/tenant.ex` | Add `wizard_progress`, `postmark_server_id`, `postmark_api_key` attributes. Add `:set_wizard_progress` update action. Update `:update` action to accept the new attrs. |
| `lib/driveway_os/onboarding/provider.ex` | Add `@callback provision(Tenant.t(), map()) :: {:ok, Tenant.t()} \| {:error, :hosted_required \| term()}`. |
| `lib/driveway_os/onboarding/providers/stripe_connect.ex` | Add `provision/2` returning `{:error, :hosted_required}`. |
| `lib/driveway_os/onboarding/registry.ex` | Add `Providers.Postmark` to `@providers` list. |
| `lib/driveway_os_web/live/admin/onboarding_wizard_live.ex` | Replace Phase 0 stub body with the actual wizard (current-step rendering, advance/skip handlers, completion redirect). |
| `lib/driveway_os_web/live/signup_live.ex` | `tenant_admin_signed_in_url/2` redirects to `/admin/onboarding` instead of `/admin`. |
| `lib/driveway_os_web/controllers/stripe_onboarding_controller.ex` | Callback redirects to `/admin/onboarding` if wizard incomplete, else `/admin`. |
| `lib/driveway_os_web/live/admin/dashboard_live.ex` | Replace `missing_branding?/1` and `using_default_services?/1` calls with `Steps.Branding.complete?/1` and `Steps.Services.complete?/1` so wizard + dashboard share one source of truth. |
| `lib/driveway_os/mailer.ex` | New `for_tenant/1` helper that returns Mailer config tuned to that tenant's Postmark credentials when set; falls back to default otherwise. |
| `lib/driveway_os/notifications/booking_email.ex` (or wherever transactional sends happen) | Use `Mailer.for_tenant(tenant)` for tenant-context sends instead of bare `Mailer.deliver/1`. |
| `config/runtime.exs` | Read `POSTMARK_ACCOUNT_TOKEN` env var into `:driveway_os, :postmark_account_token` for all envs. |
| `config/test.exs` | Configure mock `PostmarkClient` for tests. |
| `DEPLOY.md` | Add `POSTMARK_ACCOUNT_TOKEN` to the per-tenant integrations env-var table. |
| `test/test_helper.exs` | Mox `defmock` for `PostmarkClient`. |

---

## Task 1: Migration + Tenant attributes + `:set_wizard_progress` action

**Files:**
- Create: `priv/repo/migrations/<ts>_add_wizard_progress_and_postmark_to_tenants.exs` (use `mix ash_postgres.generate_migrations` after editing the resource)
- Modify: `lib/driveway_os/platform/tenant.ex`
- Test: `test/driveway_os/platform/tenant_test.exs` (extend if exists, create if not)

- [ ] **Step 1: Add the three new attributes to Tenant**

In `lib/driveway_os/platform/tenant.ex`, find the `attributes do` block. Add these alongside the existing attributes (place them logically — `wizard_progress` near the bottom of customer-facing fields, the two postmark fields next to `stripe_account_id` and `stripe_account_status`):

```elixir
    attribute :wizard_progress, :map do
      public? false
      default %{}
      description """
      Onboarding-wizard state. Map keyed by step id (e.g. "branding"),
      values are exactly "skipped" — done-ness is computed live via
      Step.complete?/1, never stored. Steps not in the map are pending.
      """
    end

    attribute :postmark_server_id, :string do
      public? false
      description "Postmark Server id assigned when the tenant completes the Email onboarding step."
    end

    attribute :postmark_api_key, :string do
      public? false
      sensitive? true
      description "Postmark Server-scoped API key. Used by the Mailer when sending in this tenant's context."
    end
```

- [ ] **Step 2: Update the `:update` action's `accept` list**

Find the existing `update :update do … accept [...]` action block. Add the three new attributes to the accept list so existing flows can edit them:

```elixir
update :update do
  primary? true

  accept [
    # ... existing attrs ...
    :wizard_progress,
    :postmark_server_id,
    :postmark_api_key
  ]
end
```

(Keep all existing `accept` entries — only ADD these three.)

- [ ] **Step 3: Add the `:set_wizard_progress` action**

In the `actions do` block, after the existing `:update` action, add:

```elixir
update :set_wizard_progress do
  argument :step, :atom, allow_nil?: false
  argument :status, :atom, allow_nil?: false

  validate fn changeset, _ ->
    case Ash.Changeset.get_argument(changeset, :status) do
      s when s in [:skipped, :pending] -> :ok
      other -> {:error, field: :status, message: "must be :skipped or :pending, got #{inspect(other)}"}
    end
  end

  change fn changeset, _ ->
    step = Ash.Changeset.get_argument(changeset, :step)
    status = Ash.Changeset.get_argument(changeset, :status)
    current = changeset.data.wizard_progress || %{}

    next =
      case status do
        :skipped -> Map.put(current, to_string(step), "skipped")
        :pending -> Map.delete(current, to_string(step))
      end

    Ash.Changeset.force_change_attribute(changeset, :wizard_progress, next)
  end
end
```

- [ ] **Step 4: Generate the migration**

Run from `/Volumes/mac_external/Development/Business/driveway_os/`:

```bash
mix ash_postgres.generate_migrations --name add_wizard_progress_and_postmark_to_tenants
```

Expected: a new file at `priv/repo/migrations/<timestamp>_add_wizard_progress_and_postmark_to_tenants.exs` with `add :wizard_progress, :map, default: %{}`, `add :postmark_server_id, :text`, `add :postmark_api_key, :text` clauses inside an `alter table(:tenants)` block.

- [ ] **Step 5: Apply the migration in test env**

```bash
MIX_ENV=test mix ecto.migrate
```

Expected: `Migrated <timestamp> in 0.0s` log line, no errors.

- [ ] **Step 6: Add tests for `:set_wizard_progress`**

In `test/driveway_os/platform/tenant_test.exs` (create the file if it doesn't exist):

```elixir
defmodule DrivewayOS.Platform.TenantTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "wp-#{System.unique_integer([:positive])}",
        display_name: "Wizard Progress Test",
        admin_email: "wp-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  describe ":set_wizard_progress" do
    test "marks a step as skipped", ctx do
      {:ok, updated} =
        ctx.tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{step: :branding, status: :skipped})
        |> Ash.update(authorize?: false)

      assert updated.wizard_progress == %{"branding" => "skipped"}
    end

    test "marks a previously-skipped step as pending by removing the key", ctx do
      {:ok, with_skip} =
        ctx.tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{step: :services, status: :skipped})
        |> Ash.update(authorize?: false)

      {:ok, cleared} =
        with_skip
        |> Ash.Changeset.for_update(:set_wizard_progress, %{step: :services, status: :pending})
        |> Ash.update(authorize?: false)

      assert cleared.wizard_progress == %{}
    end

    test "rejects status that isn't :skipped or :pending", ctx do
      assert {:error, _} =
               ctx.tenant
               |> Ash.Changeset.for_update(:set_wizard_progress, %{step: :branding, status: :done})
               |> Ash.update(authorize?: false)
    end
  end

  describe "postmark fields" do
    test "tenant starts with nil postmark_server_id and postmark_api_key", ctx do
      assert ctx.tenant.postmark_server_id == nil
      assert ctx.tenant.postmark_api_key == nil
    end

    test ":update can set postmark fields", ctx do
      {:ok, updated} =
        ctx.tenant
        |> Ash.Changeset.for_update(:update, %{
          postmark_server_id: "12345",
          postmark_api_key: "server-token-abc"
        })
        |> Ash.update(authorize?: false)

      assert updated.postmark_server_id == "12345"
      assert updated.postmark_api_key == "server-token-abc"
    end
  end
end
```

- [ ] **Step 7: Run the tests**

```bash
mix test test/driveway_os/platform/tenant_test.exs
```

Expected: 5/5 pass.

- [ ] **Step 8: Run full suite to confirm no regressions**

```bash
mix test
```

Expected: previous count (570 — Phase 0 final) + 5 new = 575, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/driveway_os/platform/tenant.ex \
        priv/repo/migrations/*_add_wizard_progress_and_postmark_to_tenants.exs \
        priv/resource_snapshots/repo/tenants/ \
        test/driveway_os/platform/tenant_test.exs
git commit -m "Tenant: wizard_progress map + Postmark credential fields"
```

---

## Task 2: `Onboarding.Step` behaviour

Pure spec module — no logic, no tests (conformance tested via implementing modules in later tasks).

**Files:**
- Create: `lib/driveway_os/onboarding/step.ex`

- [ ] **Step 1: Create the behaviour module**

```elixir
# lib/driveway_os/onboarding/step.ex
defmodule DrivewayOS.Onboarding.Step do
  @moduledoc """
  Behaviour every onboarding-wizard step implements.

  A step is one slice of the linear-required wizard at
  /admin/onboarding (Branding, Services, Schedule, Payment, Email).
  Each step owns its own form rendering and submit handling, and
  exposes a `complete?(tenant)` predicate that the wizard FSM uses
  to decide whether to skip past it.

  Done-ness is always computed from real state via `complete?/1` —
  never stored. Skip flags live in `tenant.wizard_progress` and are
  managed by `DrivewayOS.Onboarding.Wizard.skip/2`.

  See also: `DrivewayOS.Onboarding.Wizard` for the FSM helpers,
  and the spec at
  `docs/superpowers/specs/2026-04-29-tenant-onboarding-phase-1-design.md`.
  """

  alias DrivewayOS.Platform.Tenant

  @doc "Stable identifier (e.g. `:branding`). Used as the key in `wizard_progress`."
  @callback id() :: atom()

  @doc "Human-readable title rendered as the step heading (e.g. \"Make it yours\")."
  @callback title() :: String.t()

  @doc """
  True when this tenant has fulfilled this step's requirements based
  on real state (e.g. `not is_nil(tenant.support_email)` for Branding).
  Never reads `wizard_progress` — that's the wizard's concern, not the
  step's.
  """
  @callback complete?(Tenant.t()) :: boolean()

  @doc """
  Renders the step's form/UI inside the wizard layout. Receives
  socket assigns (current_tenant, current_customer, errors, etc.)
  and returns rendered HEEx.
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Handles the step's primary form submit. Returns:

    * `{:ok, socket}` — step succeeded; wizard advances.
    * `{:error, term}` — step failed; wizard stays on this step,
      surfaces the error.

  May write to the tenant or to provider-specific external services.
  """
  @callback submit(params :: map(), socket :: Phoenix.LiveView.Socket.t())
              :: {:ok, Phoenix.LiveView.Socket.t()} | {:error, term()}
end
```

- [ ] **Step 2: Verify it compiles**

```bash
mix compile
```

Expected: success, no warnings about this file.

- [ ] **Step 3: Commit**

```bash
git add lib/driveway_os/onboarding/step.ex
git commit -m "Onboarding: Step behaviour"
```

---

## Task 3: `Onboarding.Wizard` FSM

Pure-function module. TDD against a fake tenant struct.

**Files:**
- Create: `lib/driveway_os/onboarding/wizard.ex`
- Test: `test/driveway_os/onboarding/wizard_test.exs`

- [ ] **Step 1: Write the failing tests**

Note: the tests reference `Steps.Branding` etc. through their public ids (`:branding`, etc.). Since those modules don't exist yet (Tasks 7–11), the test uses a fake step list via `Wizard.put_steps_for_test/1` — a private testing seam. To avoid that, we'll instead use `Mox` to stub the modules. Actually, the simplest path: introduce a small indirection. The Wizard's `steps/0` returns the canonical module list. For testing, pass an explicit step list to internal helpers via a `with_steps/2` form. This keeps the production API clean while allowing tests.

Concrete approach: each Wizard query function accepts an optional second arg `steps` for testability:

```elixir
def current_step(tenant, steps \\ steps()), do: …
def complete?(tenant, steps \\ steps()), do: …
```

The default arg uses the module list. Tests pass fake module lists.

```elixir
# test/driveway_os/onboarding/wizard_test.exs
defmodule DrivewayOS.Onboarding.WizardTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Wizard
  alias DrivewayOS.Platform

  # Fake step modules used to test FSM mechanics in isolation
  # from the real Branding/Services/etc. impls (which arrive in
  # later tasks).
  defmodule FakeAlwaysComplete do
    @behaviour DrivewayOS.Onboarding.Step
    def id, do: :always_complete
    def title, do: "Always Complete"
    def complete?(_), do: true
    def render(_), do: nil
    def submit(_, socket), do: {:ok, socket}
  end

  defmodule FakeNeverComplete do
    @behaviour DrivewayOS.Onboarding.Step
    def id, do: :never_complete
    def title, do: "Never Complete"
    def complete?(_), do: false
    def render(_), do: nil
    def submit(_, socket), do: {:ok, socket}
  end

  defmodule FakeOtherNever do
    @behaviour DrivewayOS.Onboarding.Step
    def id, do: :other_never
    def title, do: "Other Never"
    def complete?(_), do: false
    def render(_), do: nil
    def submit(_, socket), do: {:ok, socket}
  end

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "wiz-#{System.unique_integer([:positive])}",
        display_name: "Wizard Test",
        admin_email: "wiz-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  describe "steps/0" do
    test "returns the canonical step module list in declared order" do
      steps = Wizard.steps()
      assert is_list(steps)
      assert length(steps) == 5
      assert Enum.at(steps, 0) == DrivewayOS.Onboarding.Steps.Branding
      assert Enum.at(steps, 4) == DrivewayOS.Onboarding.Steps.Email
    end
  end

  describe "current_step/2" do
    test "returns nil when all steps are complete", ctx do
      assert Wizard.current_step(ctx.tenant, [FakeAlwaysComplete]) == nil
    end

    test "returns the first non-complete, non-skipped step", ctx do
      assert Wizard.current_step(ctx.tenant, [FakeAlwaysComplete, FakeNeverComplete]) ==
               FakeNeverComplete
    end

    test "skips past steps marked :skipped in wizard_progress", ctx do
      {:ok, with_skip} =
        ctx.tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{
          step: :never_complete,
          status: :skipped
        })
        |> Ash.update(authorize?: false)

      # never_complete is :skipped, other_never is the next non-complete-non-skipped.
      assert Wizard.current_step(with_skip, [FakeAlwaysComplete, FakeNeverComplete, FakeOtherNever]) ==
               FakeOtherNever
    end
  end

  describe "complete?/2" do
    test "true when all steps are either complete or skipped", ctx do
      {:ok, with_skip} =
        ctx.tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{
          step: :never_complete,
          status: :skipped
        })
        |> Ash.update(authorize?: false)

      assert Wizard.complete?(with_skip, [FakeAlwaysComplete, FakeNeverComplete])
    end

    test "false when at least one step is pending", ctx do
      refute Wizard.complete?(ctx.tenant, [FakeAlwaysComplete, FakeNeverComplete])
    end

    test "true when the step list is empty" do
      assert Wizard.complete?(%{wizard_progress: %{}}, [])
    end
  end

  describe "skip/2 and unskip/2" do
    test "skip writes :skipped to wizard_progress", ctx do
      {:ok, skipped} = Wizard.skip(ctx.tenant, :branding)
      assert skipped.wizard_progress == %{"branding" => "skipped"}
    end

    test "unskip removes the key", ctx do
      {:ok, skipped} = Wizard.skip(ctx.tenant, :services)
      {:ok, cleared} = Wizard.unskip(skipped, :services)
      assert cleared.wizard_progress == %{}
    end
  end

  describe "skipped?/2" do
    test "true when the step id is in wizard_progress as 'skipped'", ctx do
      {:ok, skipped} = Wizard.skip(ctx.tenant, :payment)
      assert Wizard.skipped?(skipped, :payment)
    end

    test "false when the step id is absent from wizard_progress", ctx do
      refute Wizard.skipped?(ctx.tenant, :branding)
    end
  end
end
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
mix test test/driveway_os/onboarding/wizard_test.exs
```

Expected: failures with `(UndefinedFunctionError) function DrivewayOS.Onboarding.Wizard.steps/0 is undefined`.

- [ ] **Step 3: Implement the module**

```elixir
# lib/driveway_os/onboarding/wizard.ex
defmodule DrivewayOS.Onboarding.Wizard do
  @moduledoc """
  Pure-function FSM helpers for the onboarding wizard at
  /admin/onboarding.

  The wizard walks five mandatory-linear steps. Each step is an
  `Onboarding.Step` implementation. State lives in
  `tenant.wizard_progress` (a jsonb map keyed by step id), but only
  `:skipped` flags are persisted — `:done` is computed via the
  step's own `complete?/1` predicate.

  This module is data-in / data-out — no GenServer, no compile-time
  registry beyond a module attribute, no side effects except the
  Ash update calls in `skip/2` and `unskip/2`. The default step
  list can be overridden via the second arg on `current_step/2` and
  `complete?/2` to make testing trivial.
  """

  alias DrivewayOS.Platform.Tenant

  @steps [
    DrivewayOS.Onboarding.Steps.Branding,
    DrivewayOS.Onboarding.Steps.Services,
    DrivewayOS.Onboarding.Steps.Schedule,
    DrivewayOS.Onboarding.Steps.Payment,
    DrivewayOS.Onboarding.Steps.Email
  ]

  @doc "Canonical wizard step list, in declaration order."
  @spec steps() :: [module()]
  def steps, do: @steps

  @doc """
  First step that's not complete? AND not skipped, walking
  the step list in order. Returns nil when every step is in a
  terminal state (complete or skipped) — the wizard caller treats
  nil as "wizard is done, redirect to /admin".
  """
  @spec current_step(map(), [module()]) :: module() | nil
  def current_step(tenant, steps \\ steps()) do
    Enum.find(steps, fn step ->
      not step.complete?(tenant) and not skipped?(tenant, step.id())
    end)
  end

  @doc """
  True when every step is either complete or skipped. False if any
  step is still pending. Empty step list returns true (vacuously).
  """
  @spec complete?(map(), [module()]) :: boolean()
  def complete?(tenant, steps \\ steps()) do
    Enum.all?(steps, fn step ->
      step.complete?(tenant) or skipped?(tenant, step.id())
    end)
  end

  @doc "Whether the given step id is marked :skipped in wizard_progress."
  @spec skipped?(map(), atom()) :: boolean()
  def skipped?(%{wizard_progress: progress}, step_id) when is_atom(step_id) do
    Map.get(progress || %{}, to_string(step_id)) == "skipped"
  end

  def skipped?(_, _), do: false

  @doc """
  Persist `step_id` as :skipped in the tenant's wizard_progress.
  Returns `{:ok, updated_tenant}` or `{:error, _}`.
  """
  @spec skip(Tenant.t(), atom()) :: {:ok, Tenant.t()} | {:error, term()}
  def skip(%Tenant{} = tenant, step_id) when is_atom(step_id) do
    tenant
    |> Ash.Changeset.for_update(:set_wizard_progress, %{step: step_id, status: :skipped})
    |> Ash.update(authorize?: false)
  end

  @doc """
  Remove the skip flag for `step_id` from wizard_progress (i.e.
  un-skip it; the step becomes pending again).
  """
  @spec unskip(Tenant.t(), atom()) :: {:ok, Tenant.t()} | {:error, term()}
  def unskip(%Tenant{} = tenant, step_id) when is_atom(step_id) do
    tenant
    |> Ash.Changeset.for_update(:set_wizard_progress, %{step: step_id, status: :pending})
    |> Ash.update(authorize?: false)
  end
end
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
mix test test/driveway_os/onboarding/wizard_test.exs
```

Expected: 9 passes, 0 failures (one test in `steps/0` block, three each in current_step/complete?, two each in skip/skipped).

The `steps/0` test will pass even though `Steps.Branding` etc. don't exist yet — Elixir module references in module attributes don't resolve at compile time unless used. The module list is just a list of atoms.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/wizard.ex \
        test/driveway_os/onboarding/wizard_test.exs
git commit -m "Onboarding: Wizard FSM helpers"
```

---

## Task 4: Provider behaviour gains `provision/2` + Stripe Connect impl

**Files:**
- Modify: `lib/driveway_os/onboarding/provider.ex`
- Modify: `lib/driveway_os/onboarding/providers/stripe_connect.ex`
- Modify: `test/driveway_os/onboarding/providers/stripe_connect_test.exs`

- [ ] **Step 1: Add the new callback to the Provider behaviour**

In `lib/driveway_os/onboarding/provider.ex`, add this `@callback` block at the end of the existing callbacks (after `setup_complete?/1`):

```elixir
  @doc """
  Provision the integration for `tenant`. API-first providers do
  the actual external setup here (POST to the provider's API,
  store credentials on the tenant, send any verification email).
  Hosted-redirect providers return `{:error, :hosted_required}` —
  the wizard then routes the operator to `display.href` instead.

  Args is a per-provider map (e.g. for an API-first provider that
  needs a tenant-supplied display name). For hosted-redirect
  providers, the args map is ignored.

  Returns:
    * `{:ok, updated_tenant}` — provisioning succeeded; persist + advance
    * `{:error, :hosted_required}` — caller should fall back to display.href
    * `{:error, term}` — provisioning failed; surface to the operator
  """
  @callback provision(Tenant.t(), map()) ::
              {:ok, Tenant.t()} | {:error, :hosted_required | term()}
```

- [ ] **Step 2: Add the Stripe Connect impl**

In `lib/driveway_os/onboarding/providers/stripe_connect.ex`, add this after the existing `setup_complete?/1` impl:

```elixir
  @impl true
  def provision(_tenant, _params), do: {:error, :hosted_required}
```

- [ ] **Step 3: Add a test for the Stripe Connect provision/2 impl**

Append to `test/driveway_os/onboarding/providers/stripe_connect_test.exs` (inside the existing module, before the closing `end`):

```elixir
  test "provision/2 returns {:error, :hosted_required}", ctx do
    assert {:error, :hosted_required} = Provider.provision(ctx.tenant, %{})
  end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/driveway_os/onboarding/providers/stripe_connect_test.exs
```

Expected: 6 passes (5 existing + 1 new), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/provider.ex \
        lib/driveway_os/onboarding/providers/stripe_connect.ex \
        test/driveway_os/onboarding/providers/stripe_connect_test.exs
git commit -m "Onboarding: Provider gains provision/2; StripeConnect returns :hosted_required"
```

---

## Task 5: PostmarkClient HTTP wrapper

**Files:**
- Create: `lib/driveway_os/notifications/postmark_client.ex` (behaviour)
- Create: `lib/driveway_os/notifications/postmark_client/http.ex` (concrete impl)
- Test: `test/driveway_os/notifications/postmark_client_test.exs`

- [ ] **Step 1: Add Mox dep if not present**

Check `mix.exs`. If `:mox` is already in `deps`, skip. Otherwise add:

```elixir
{:mox, "~> 1.0", only: :test}
```

Then `mix deps.get`.

(Project may already have Mox per the StripeClientMock pattern in `test_helper.exs`. Confirm with `grep mox mix.exs` first.)

- [ ] **Step 2: Write the failing tests**

```elixir
# test/driveway_os/notifications/postmark_client_test.exs
defmodule DrivewayOS.Notifications.PostmarkClientTest do
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Notifications.PostmarkClient

  setup :verify_on_exit!

  describe "behaviour shape" do
    test "create_server/2 returns {:ok, %{server_id, api_key}} on success" do
      expect(PostmarkClient.Mock, :create_server, fn "test-shop", _opts ->
        {:ok, %{server_id: 12345, api_key: "server-token-abc"}}
      end)

      assert {:ok, %{server_id: 12345, api_key: "server-token-abc"}} =
               PostmarkClient.Mock.create_server("test-shop", [])
    end

    test "create_server/2 returns {:error, reason} on Postmark failure" do
      expect(PostmarkClient.Mock, :create_server, fn _, _ ->
        {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
      end)

      assert {:error, %{status: 401}} = PostmarkClient.Mock.create_server("test", [])
    end
  end
end
```

- [ ] **Step 3: Configure the Mox in test_helper**

In `test/test_helper.exs`, add at the appropriate place (near the existing mocks):

```elixir
Mox.defmock(DrivewayOS.Notifications.PostmarkClient.Mock,
  for: DrivewayOS.Notifications.PostmarkClient
)

Application.put_env(:driveway_os, :postmark_client, DrivewayOS.Notifications.PostmarkClient.Mock)
```

- [ ] **Step 4: Run; verify failure**

```bash
mix test test/driveway_os/notifications/postmark_client_test.exs
```

Expected: `(UndefinedFunctionError) function DrivewayOS.Notifications.PostmarkClient.Mock... not available` or behaviour-not-defined error.

- [ ] **Step 5: Define the behaviour**

```elixir
# lib/driveway_os/notifications/postmark_client.ex
defmodule DrivewayOS.Notifications.PostmarkClient do
  @moduledoc """
  Behaviour for talking to the Postmark API. Defined as a behaviour
  so tests can use Mox to bypass HTTP and assert on the calls
  Postmark.provision/2 makes.

  The concrete HTTP impl lives in
  `DrivewayOS.Notifications.PostmarkClient.Http`. Tests configure
  `Mox.defmock` for `DrivewayOS.Notifications.PostmarkClient.Mock`
  in `test_helper.exs`.

  Resolve the runtime impl via `client/0` — in dev/prod that's the
  HTTP module; in test it's the Mox.
  """

  alias DrivewayOS.Notifications.PostmarkClient.Http

  @doc """
  Create a Postmark Server scoped to one DrivewayOS tenant.
  Returns {:ok, %{server_id: integer, api_key: binary}} on success.
  Returns {:error, %{status: integer, body: term}} on HTTP error.
  """
  @callback create_server(name :: String.t(), opts :: keyword()) ::
              {:ok, %{server_id: integer(), api_key: String.t()}}
              | {:error, term()}

  @doc "Resolve the configured client module (HTTP in prod, Mock in test)."
  @spec client() :: module()
  def client do
    Application.get_env(:driveway_os, :postmark_client, Http)
  end

  @doc "Convenience wrapper that delegates to the configured client."
  @spec create_server(String.t(), keyword()) ::
          {:ok, %{server_id: integer(), api_key: String.t()}} | {:error, term()}
  def create_server(name, opts \\ []), do: client().create_server(name, opts)
end
```

- [ ] **Step 6: Implement the HTTP module**

```elixir
# lib/driveway_os/notifications/postmark_client/http.ex
defmodule DrivewayOS.Notifications.PostmarkClient.Http do
  @moduledoc """
  Concrete HTTP impl of the PostmarkClient behaviour. Talks to
  https://api.postmarkapp.com using `Req`.

  Auth: account-level token via `:postmark_account_token`
  application config (set from POSTMARK_ACCOUNT_TOKEN env var in
  runtime.exs). Each Server creation call returns a Server-scoped
  api_key that the caller stores per-tenant.
  """

  @behaviour DrivewayOS.Notifications.PostmarkClient

  @endpoint "https://api.postmarkapp.com"

  @impl true
  def create_server(name, opts) when is_binary(name) do
    color = Keyword.get(opts, :color, "Blue")

    body = %{
      "Name" => name,
      "Color" => color,
      "RawEmailEnabled" => false,
      "DeliveryHookUrl" => nil,
      "InboundHookUrl" => nil
    }

    request =
      Req.new(
        base_url: @endpoint,
        headers: [
          {"X-Postmark-Account-Token", account_token()},
          {"Accept", "application/json"}
        ],
        json: body,
        receive_timeout: 10_000
      )

    case Req.post(request, url: "/servers") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, %{server_id: body["ID"], api_key: body["ApiTokens"] |> List.first()}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  defp account_token do
    case Application.get_env(:driveway_os, :postmark_account_token) do
      nil -> raise "POSTMARK_ACCOUNT_TOKEN not configured"
      "" -> raise "POSTMARK_ACCOUNT_TOKEN not configured"
      token -> token
    end
  end
end
```

- [ ] **Step 7: Run tests; verify they pass**

```bash
mix test test/driveway_os/notifications/postmark_client_test.exs
```

Expected: 2 passes, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/driveway_os/notifications/postmark_client.ex \
        lib/driveway_os/notifications/postmark_client/http.ex \
        test/driveway_os/notifications/postmark_client_test.exs \
        test/test_helper.exs
git commit -m "Notifications: PostmarkClient behaviour + HTTP impl + Mox"
```

---

## Task 6: Postmark provider

**Files:**
- Create: `lib/driveway_os/onboarding/providers/postmark.ex`
- Modify: `lib/driveway_os/onboarding/registry.ex` (add Postmark to `@providers`)
- Test: `test/driveway_os/onboarding/providers/postmark_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/driveway_os/onboarding/providers/postmark_test.exs
defmodule DrivewayOS.Onboarding.Providers.PostmarkTest do
  use DrivewayOS.DataCase, async: false

  import Mox
  import Swoosh.TestAssertions

  alias DrivewayOS.Onboarding.Providers.Postmark, as: Provider
  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "pm-#{System.unique_integer([:positive])}",
        display_name: "Postmark Test",
        admin_email: "pm-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "id/0 is :postmark" do
    assert Provider.id() == :postmark
  end

  test "category/0 is :email" do
    assert Provider.category() == :email
  end

  test "display/0 returns the canonical card copy" do
    d = Provider.display()
    assert d.title == "Send booking emails"
    assert d.cta_label == "Set up email"
    assert d.href == "/admin/onboarding"
  end

  test "configured?/0 mirrors POSTMARK_ACCOUNT_TOKEN env" do
    original = Application.get_env(:driveway_os, :postmark_account_token)

    Application.put_env(:driveway_os, :postmark_account_token, "abc")
    assert Provider.configured?()

    Application.put_env(:driveway_os, :postmark_account_token, "")
    refute Provider.configured?()

    on_exit(fn -> Application.put_env(:driveway_os, :postmark_account_token, original) end)
  end

  test "setup_complete?/1 reflects postmark_server_id presence", ctx do
    refute Provider.setup_complete?(ctx.tenant)

    {:ok, with_server} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_server_id: "12345"})
      |> Ash.update(authorize?: false)

    assert Provider.setup_complete?(with_server)
  end

  describe "provision/2" do
    test "happy path: creates server, persists creds, sends welcome email", ctx do
      expect(PostmarkClient.Mock, :create_server, fn name, _opts ->
        assert name == "drivewayos-#{ctx.tenant.slug}"
        {:ok, %{server_id: 99_001, api_key: "server-token-xyz"}}
      end)

      assert {:ok, updated} = Provider.provision(ctx.tenant, %{})
      assert updated.postmark_server_id == "99001"
      assert updated.postmark_api_key == "server-token-xyz"

      assert_email_sent(fn email ->
        assert email.subject =~ "set up to send email"
        assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      end)
    end

    test "Postmark API error: returns {:error, reason} without persisting", ctx do
      expect(PostmarkClient.Mock, :create_server, fn _, _ ->
        {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
      end)

      assert {:error, %{status: 401}} = Provider.provision(ctx.tenant, %{})

      reloaded = Ash.get!(DrivewayOS.Platform.Tenant, ctx.tenant.id, authorize?: false)
      assert reloaded.postmark_server_id == nil
      assert reloaded.postmark_api_key == nil
    end
  end
end
```

- [ ] **Step 2: Run; verify they fail**

```bash
mix test test/driveway_os/onboarding/providers/postmark_test.exs
```

Expected: failures because the module doesn't exist yet.

- [ ] **Step 3: Implement the provider**

```elixir
# lib/driveway_os/onboarding/providers/postmark.ex
defmodule DrivewayOS.Onboarding.Providers.Postmark do
  @moduledoc """
  Postmark onboarding provider — V1 email integration.

  Fully API-first: `provision/2` POSTs to Postmark's `/servers`
  endpoint, persists the resulting `server_id` + `api_key` on the
  tenant, then sends a welcome/verification email through the
  newly-provisioned server. The welcome send doubles as the
  deliverability probe — if it fails, we surface the error and
  don't advance the wizard.

  Account-level auth: read `POSTMARK_ACCOUNT_TOKEN` via
  `:postmark_account_token` application config (configured in
  runtime.exs). When unset, `configured?/0` returns false and the
  Email step + dashboard checklist hide themselves.
  """

  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :postmark

  @impl true
  def category, do: :email

  @impl true
  def display do
    %{
      title: "Send booking emails",
      blurb:
        "Wire up Postmark so confirmations, reminders, and receipts " <>
          "go to your customers from your shop's address.",
      cta_label: "Set up email",
      href: "/admin/onboarding"
    }
  end

  @impl true
  def configured? do
    case Application.get_env(:driveway_os, :postmark_account_token) do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  @impl true
  def setup_complete?(%Tenant{postmark_server_id: id}), do: not is_nil(id)

  @impl true
  def provision(%Tenant{} = tenant, _params) do
    with {:ok, %{server_id: server_id, api_key: api_key}} <-
           PostmarkClient.create_server("drivewayos-#{tenant.slug}"),
         {:ok, updated} <- save_credentials(tenant, server_id, api_key),
         :ok <- send_welcome_email(updated) do
      {:ok, updated}
    end
  end

  defp save_credentials(tenant, server_id, api_key) do
    tenant
    |> Ash.Changeset.for_update(:update, %{
      postmark_server_id: to_string(server_id),
      postmark_api_key: api_key
    })
    |> Ash.update(authorize?: false)
  end

  defp send_welcome_email(tenant) do
    {:ok, admin} = first_admin(tenant)

    Mailer.deliver(welcome_email(tenant, admin), Mailer.for_tenant(tenant))
    :ok
  rescue
    e -> {:error, %{reason: :welcome_email_failed, exception: Exception.message(e)}}
  end

  defp first_admin(tenant) do
    case DrivewayOS.Accounts.tenant_admins(tenant.id) do
      [admin | _] -> {:ok, admin}
      _ -> {:error, :no_admin}
    end
  end

  defp welcome_email(tenant, admin) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({admin.name, to_string(admin.email)})
    |> Swoosh.Email.from(DrivewayOS.Branding.from_address(tenant))
    |> Swoosh.Email.subject("Your shop is set up to send email")
    |> Swoosh.Email.text_body("""
    Hi #{admin.name},

    #{tenant.display_name} is now wired up to send transactional
    emails through Postmark. From this point on, booking
    confirmations, reminders, and receipts will go to your customers
    from your shop's email address.

    No action needed — this email is just confirmation that the
    connection works.

    -- DrivewayOS
    """)
  end
end
```

- [ ] **Step 4: Add Postmark to the Registry**

In `lib/driveway_os/onboarding/registry.ex`, find the `@providers` module attribute. Add Postmark:

```elixir
  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect,
    DrivewayOS.Onboarding.Providers.Postmark
  ]
```

- [ ] **Step 5: Run the provider tests; verify they pass**

```bash
mix test test/driveway_os/onboarding/providers/postmark_test.exs test/driveway_os/onboarding/registry_test.exs
```

Expected: 7 + 5 = 12 passes (some Registry tests may need updating since the Postmark provider is now in the list — if so, the count changes by 1 in `all/0` test).

If a Registry test fails because `length(Registry.all())` is now 2 not 1, update the Registry test (the assertion `assert StripeConnect in Registry.all()` already supports membership rather than exact length, so it shouldn't fail — verify before assuming).

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/onboarding/providers/postmark.ex \
        lib/driveway_os/onboarding/registry.ex \
        test/driveway_os/onboarding/providers/postmark_test.exs
git commit -m "Onboarding: Postmark provider (API-first) + Registry registration"
```

---

## Task 7: Steps.Branding

**Files:**
- Create: `lib/driveway_os/onboarding/steps/branding.ex`
- Test: `test/driveway_os/onboarding/steps/branding_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/driveway_os/onboarding/steps/branding_test.exs
defmodule DrivewayOS.Onboarding.Steps.BrandingTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Branding
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "br-#{System.unique_integer([:positive])}",
        display_name: "Branding Step Test",
        admin_email: "br-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :branding" do
    assert Branding.id() == :branding
  end

  test "title/0 is human-readable" do
    assert is_binary(Branding.title())
  end

  test "complete?/1 false when support_email is nil", ctx do
    refute Branding.complete?(ctx.tenant)
  end

  test "complete?/1 true once support_email is set", ctx do
    {:ok, with_email} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{support_email: "support@acme.test"})
      |> Ash.update(authorize?: false)

    assert Branding.complete?(with_email)
  end
end
```

- [ ] **Step 2: Run; verify they fail**

```bash
mix test test/driveway_os/onboarding/steps/branding_test.exs
```

Expected: module-not-defined errors.

- [ ] **Step 3: Implement Steps.Branding**

```elixir
# lib/driveway_os/onboarding/steps/branding.ex
defmodule DrivewayOS.Onboarding.Steps.Branding do
  @moduledoc """
  Branding wizard step. Collects the four shop-identity fields the
  customer-facing booking page needs:

    * support_email (REQUIRED — gates step completion)
    * logo_url (optional)
    * primary_color_hex (optional, default #3b82f6 from DaisyUI)
    * support_phone (optional)

  Only support_email is required because it's the only field that
  *breaks* something if missing — confirmation emails would have
  no reply-to. Logo + color + phone are polish the operator can
  always come back to via /admin/branding.

  The form mirrors the field shape used by the existing
  /admin/branding LV; both write to Tenant via the same `:update`
  action.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :branding

  @impl true
  def title, do: "Make it yours"

  @impl true
  def complete?(%Tenant{support_email: nil}), do: false
  def complete?(%Tenant{support_email: ""}), do: false
  def complete?(%Tenant{support_email: _}), do: true

  @impl true
  def render(assigns) do
    ~H"""
    <form id="step-branding-form" phx-submit="step_submit" class="space-y-3">
      <div>
        <label class="label" for="branding-email">
          <span class="label-text font-medium">Support email *</span>
        </label>
        <input
          id="branding-email"
          type="email"
          name="branding[support_email]"
          value={@current_tenant.support_email || ""}
          placeholder="hello@yourshop.com"
          class="input input-bordered w-full"
          required
        />
        <p :if={@errors[:support_email]} class="text-error text-xs mt-1">
          {@errors[:support_email]}
        </p>
      </div>

      <div>
        <label class="label" for="branding-logo">
          <span class="label-text font-medium">Logo URL</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="branding-logo"
          type="url"
          name="branding[logo_url]"
          value={@current_tenant.logo_url || ""}
          placeholder="https://yourshop.com/logo.png"
          class="input input-bordered w-full"
        />
      </div>

      <div class="grid grid-cols-2 gap-3">
        <div>
          <label class="label" for="branding-color">
            <span class="label-text font-medium">Brand color</span>
            <span class="label-text-alt text-base-content/50">Optional</span>
          </label>
          <input
            id="branding-color"
            type="text"
            name="branding[primary_color_hex]"
            value={@current_tenant.primary_color_hex || "#3b82f6"}
            placeholder="#3b82f6"
            class="input input-bordered w-full font-mono"
          />
        </div>
        <div>
          <label class="label" for="branding-phone">
            <span class="label-text font-medium">Support phone</span>
            <span class="label-text-alt text-base-content/50">Optional</span>
          </label>
          <input
            id="branding-phone"
            type="tel"
            name="branding[support_phone]"
            value={@current_tenant.support_phone || ""}
            placeholder="+1 555-555-1234"
            class="input input-bordered w-full"
          />
        </div>
      </div>
    </form>
    """
  end

  @impl true
  def submit(%{"branding" => params}, socket) do
    tenant = socket.assigns.current_tenant

    attrs = %{
      support_email: params["support_email"] |> to_string() |> String.trim(),
      logo_url: params["logo_url"] |> to_string() |> String.trim() |> presence(),
      primary_color_hex: params["primary_color_hex"] |> to_string() |> String.trim() |> presence(),
      support_phone: params["support_phone"] |> to_string() |> String.trim() |> presence()
    }

    case tenant
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        {:ok, Phoenix.Component.assign(socket, :current_tenant, updated)}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        msg = errors |> Enum.map_join("; ", &Map.get(&1, :message, "is invalid"))
        {:error, msg}
    end
  end

  defp presence(""), do: nil
  defp presence(v), do: v
end
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
mix test test/driveway_os/onboarding/steps/branding_test.exs
```

Expected: 4 passes, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/steps/branding.ex \
        test/driveway_os/onboarding/steps/branding_test.exs
git commit -m "Onboarding: Steps.Branding"
```

---

## Task 8: Steps.Services

**Files:**
- Create: `lib/driveway_os/onboarding/steps/services.ex`
- Test: `test/driveway_os/onboarding/steps/services_test.exs`

The Services step's `complete?/1` is "the tenant's services are not the two literal seeded slugs (`basic-wash`, `deep-clean`)" — same predicate the dashboard already uses via `using_default_services?/1`. The submit handler is a redirect to `/admin/services` for the actual editing, since that LV already has the full CRUD UI. The wizard form itself is a tiny "Open service editor" button that navigates to /admin/services.

Reasoning: re-implementing service CRUD inline in the wizard would duplicate complex UX. A redirect is simpler. The user clicks "Open service editor", edits services on /admin/services, comes back to /admin/onboarding when ready.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/driveway_os/onboarding/steps/services_test.exs
defmodule DrivewayOS.Onboarding.Steps.ServicesTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Services, as: Step
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "sv-#{System.unique_integer([:positive])}",
        display_name: "Services Step Test",
        admin_email: "sv-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :services" do
    assert Step.id() == :services
  end

  test "complete?/1 false for a fresh tenant with default seeds", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "complete?/1 true once a default service is renamed", ctx do
    {:ok, [first | _]} =
      ServiceType
      |> Ash.Query.set_tenant(ctx.tenant.id)
      |> Ash.read(authorize?: false)

    first
    |> Ash.Changeset.for_update(:update, %{slug: "express-wash", name: "Express Wash"})
    |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

    reloaded =
      Ash.get!(DrivewayOS.Platform.Tenant, ctx.tenant.id, authorize?: false)

    assert Step.complete?(reloaded)
  end
end
```

- [ ] **Step 2: Run; verify they fail**

```bash
mix test test/driveway_os/onboarding/steps/services_test.exs
```

Expected: module-not-defined.

- [ ] **Step 3: Implement Steps.Services**

```elixir
# lib/driveway_os/onboarding/steps/services.ex
defmodule DrivewayOS.Onboarding.Steps.Services do
  @moduledoc """
  Services wizard step. The tenant ships with two seeded services
  (Basic Wash, Deep Clean); this step prompts them to rename, reprice,
  or replace them with their actual menu.

  The wizard step itself is a thin redirect to /admin/services where
  the full CRUD UI already lives — re-implementing service CRUD
  inline would duplicate complex UX. The wizard owner returns to
  /admin/onboarding when ready (browser back, or via the dashboard
  link).

  `complete?/1` mirrors the `using_default_services?/1` predicate
  the dashboard already uses: false when the tenant still has the
  literal seeded slug set; true once any seeded service is renamed
  or a new service is added.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

  @impl true
  def id, do: :services

  @impl true
  def title, do: "Set your service menu"

  @impl true
  def complete?(%Tenant{} = tenant) do
    {:ok, services} =
      ServiceType
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

    slugs = services |> Enum.map(& &1.slug) |> Enum.sort()
    slugs != ["basic-wash", "deep-clean"]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">
        Your shop ships with two starter services. Rename or replace them with
        what you actually offer — pricing, duration, descriptions all live there.
      </p>
      <a href="/admin/services" class="btn btn-primary btn-sm gap-1">
        Open service editor
        <span class="hero-arrow-top-right-on-square w-3 h-3" aria-hidden="true"></span>
      </a>
      <p class="text-xs text-base-content/60">
        We'll bring you back here when you're done.
      </p>
    </div>
    """
  end

  @impl true
  def submit(_params, socket) do
    # No inline form for this step — operator returns from /admin/services
    # via browser back. The wizard re-checks complete?/1 on every render.
    {:ok, socket}
  end
end
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
mix test test/driveway_os/onboarding/steps/services_test.exs
```

Expected: 3 passes, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/steps/services.ex \
        test/driveway_os/onboarding/steps/services_test.exs
git commit -m "Onboarding: Steps.Services"
```

---

## Task 9: Steps.Schedule

Mirror of Steps.Services — redirect to /admin/schedule for the actual editing.

**Files:**
- Create: `lib/driveway_os/onboarding/steps/schedule.ex`
- Test: `test/driveway_os/onboarding/steps/schedule_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/driveway_os/onboarding/steps/schedule_test.exs
defmodule DrivewayOS.Onboarding.Steps.ScheduleTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Schedule, as: Step
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.BlockTemplate

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "sc-#{System.unique_integer([:positive])}",
        display_name: "Schedule Step Test",
        admin_email: "sc-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :schedule" do
    assert Step.id() == :schedule
  end

  test "complete?/1 false when tenant has no block templates", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "complete?/1 true once at least one BlockTemplate exists", ctx do
    BlockTemplate
    |> Ash.Changeset.for_create(
      :create,
      %{
        weekday: 1,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      },
      tenant: ctx.tenant.id
    )
    |> Ash.create!(authorize?: false)

    assert Step.complete?(ctx.tenant)
  end
end
```

- [ ] **Step 2: Run; verify they fail**

```bash
mix test test/driveway_os/onboarding/steps/schedule_test.exs
```

Expected: module-not-defined.

- [ ] **Step 3: Implement Steps.Schedule**

```elixir
# lib/driveway_os/onboarding/steps/schedule.ex
defmodule DrivewayOS.Onboarding.Steps.Schedule do
  @moduledoc """
  Schedule wizard step. Customers can only see concrete time slots
  once the operator publishes weekly availability blocks; this step
  prompts them to create at least one.

  Like Steps.Services, the wizard step itself is a redirect to
  /admin/schedule where the full BlockTemplate editor already lives.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.BlockTemplate

  require Ash.Query

  @impl true
  def id, do: :schedule

  @impl true
  def title, do: "Set your weekly hours"

  @impl true
  def complete?(%Tenant{} = tenant) do
    {:ok, blocks} =
      BlockTemplate |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    not Enum.empty?(blocks)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">
        Customers can only book times when you're available. Add at least one
        weekly block — say, 9am–5pm Tuesdays — to get going.
      </p>
      <a href="/admin/schedule" class="btn btn-primary btn-sm gap-1">
        Open schedule editor
        <span class="hero-arrow-top-right-on-square w-3 h-3" aria-hidden="true"></span>
      </a>
      <p class="text-xs text-base-content/60">
        We'll bring you back here when you're done.
      </p>
    </div>
    """
  end

  @impl true
  def submit(_params, socket), do: {:ok, socket}
end
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
mix test test/driveway_os/onboarding/steps/schedule_test.exs
```

Expected: 3 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/steps/schedule.ex \
        test/driveway_os/onboarding/steps/schedule_test.exs
git commit -m "Onboarding: Steps.Schedule"
```

---

## Task 10: Steps.Payment

Wraps the existing `Providers.StripeConnect`. The wizard's Payment step is just a card with the "Connect Stripe" button that points at the existing OAuth URL `/onboarding/stripe/start`.

**Files:**
- Create: `lib/driveway_os/onboarding/steps/payment.ex`

(No test file needed — the underlying StripeConnect provider is already fully tested in `test/driveway_os/onboarding/providers/stripe_connect_test.exs`. The Step's `complete?/1` is a pass-through, so its behaviour is implicitly covered.)

- [ ] **Step 1: Implement the step**

```elixir
# lib/driveway_os/onboarding/steps/payment.ex
defmodule DrivewayOS.Onboarding.Steps.Payment do
  @moduledoc """
  Payment wizard step. Delegates everything to the
  `Providers.StripeConnect` provider — the OAuth + state +
  account-creation logic already lives there from Phase 0.

  This step is a thin presentational layer: the wizard renders the
  StripeConnect provider's `display.title` + `display.blurb` + a
  "Connect Stripe" link to `/onboarding/stripe/start`. The OAuth
  redirect comes back to `/onboarding/stripe/callback`, which
  redirects to `/admin/onboarding` when the wizard is incomplete
  (Task 13).
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Onboarding.Providers.StripeConnect
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :payment

  @impl true
  def title, do: "Take card payments"

  @impl true
  def complete?(%Tenant{} = tenant), do: StripeConnect.setup_complete?(tenant)

  @impl true
  def render(assigns) do
    display = StripeConnect.display()
    assigns = Map.put(assigns, :display, display)

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <a href={@display.href} class="btn btn-primary btn-sm gap-1">
        {@display.cta_label}
        <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
      </a>
      <p class="text-xs text-base-content/60">
        Stripe handles identity verification on their site; we'll bring you back here when you're done.
      </p>
    </div>
    """
  end

  @impl true
  def submit(_params, socket), do: {:ok, socket}
end
```

- [ ] **Step 2: Verify it compiles**

```bash
mix compile
```

Expected: success, no warnings about this file.

- [ ] **Step 3: Commit**

```bash
git add lib/driveway_os/onboarding/steps/payment.ex
git commit -m "Onboarding: Steps.Payment delegating to StripeConnect provider"
```

---

## Task 11: Steps.Email

Wraps `Providers.Postmark`. Submit calls `Postmark.provision/2`, advances on success, surfaces error otherwise.

**Files:**
- Create: `lib/driveway_os/onboarding/steps/email.ex`
- Test: `test/driveway_os/onboarding/steps/email_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/driveway_os/onboarding/steps/email_test.exs
defmodule DrivewayOS.Onboarding.Steps.EmailTest do
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Onboarding.Steps.Email, as: Step
  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "em-#{System.unique_integer([:positive])}",
        display_name: "Email Step Test",
        admin_email: "em-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "id/0 is :email" do
    assert Step.id() == :email
  end

  test "complete?/1 false when tenant has no postmark_server_id", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "submit/2 happy path: provisions Postmark and updates the socket", ctx do
    expect(PostmarkClient.Mock, :create_server, fn _name, _opts ->
      {:ok, %{server_id: 88_001, api_key: "server-token-pq"}}
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        current_tenant: ctx.tenant,
        current_customer: ctx.admin,
        errors: %{}
      }
    }

    assert {:ok, socket} = Step.submit(%{}, socket)
    assert socket.assigns.current_tenant.postmark_server_id == "88001"
  end

  test "submit/2 surfaces Postmark API error", ctx do
    expect(PostmarkClient.Mock, :create_server, fn _, _ ->
      {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{current_tenant: ctx.tenant, current_customer: ctx.admin, errors: %{}}
    }

    assert {:error, _} = Step.submit(%{}, socket)
  end
end
```

- [ ] **Step 2: Run; verify they fail**

```bash
mix test test/driveway_os/onboarding/steps/email_test.exs
```

Expected: module-not-defined.

- [ ] **Step 3: Implement Steps.Email**

```elixir
# lib/driveway_os/onboarding/steps/email.ex
defmodule DrivewayOS.Onboarding.Steps.Email do
  @moduledoc """
  Email wizard step. Wraps the Postmark provider.

  Unlike Payment (hosted-redirect), Email is API-first: the wizard
  submit calls `Providers.Postmark.provision/2` synchronously, which
  hits Postmark's /servers endpoint, persists credentials on the
  tenant, and sends a welcome email through the new server. The
  send doubles as the deliverability probe — failure is surfaced
  to the operator instead of advancing.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Onboarding.Providers.Postmark
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :email

  @impl true
  def title, do: "Send booking emails"

  @impl true
  def complete?(%Tenant{} = tenant), do: Postmark.setup_complete?(tenant)

  @impl true
  def render(assigns) do
    display = Postmark.display()
    assigns = Map.put(assigns, :display, display)

    ~H"""
    <form id="step-email-form" phx-submit="step_submit" class="space-y-3">
      <p class="text-sm text-base-content/70">{@display.blurb}</p>
      <p class="text-xs text-base-content/60">
        We'll create a Postmark server for your shop and send you a quick test email
        to confirm everything's working. Takes a few seconds.
      </p>
      <p :if={@errors[:email]} class="text-error text-sm">
        {@errors[:email]}
      </p>
      <button type="submit" class="btn btn-primary btn-sm gap-1">
        {@display.cta_label}
        <span class="hero-arrow-right w-3 h-3" aria-hidden="true"></span>
      </button>
    </form>
    """
  end

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

  defp format_reason(%{status: status, body: body}),
    do: "Postmark error #{status}: #{inspect(body)}"

  defp format_reason(other), do: inspect(other)
end
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
mix test test/driveway_os/onboarding/steps/email_test.exs
```

Expected: 4 passes, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/steps/email.ex \
        test/driveway_os/onboarding/steps/email_test.exs
git commit -m "Onboarding: Steps.Email"
```

---

## Task 12: OnboardingWizardLive rewrite

Replace the Phase 0 stub body with the actual wizard. Renders the current step via `Step.render/1`, handles `phx-submit="step_submit"` and `phx-click="skip_step"`, redirects to `/admin` when `Wizard.complete?/1`.

**Files:**
- Modify: `lib/driveway_os_web/live/admin/onboarding_wizard_live.ex`
- Modify: `test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs`

- [ ] **Step 1: Add new failing tests for the wizard**

Append to the existing test file (in the existing module, before its closing `end`):

```elixir
  describe "linear flow" do
    test "fresh tenant lands on the Branding step", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      assert html =~ "Make it yours"
      assert html =~ "Support email"
    end

    test "submitting Branding form advances to Services", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      html =
        lv
        |> form("#step-branding-form", %{
          "branding" => %{"support_email" => "hello@acme.test"}
        })
        |> render_submit()

      # After submit, the next pending step is Services (default
      # seeded services unchanged → Services.complete?/1 = false).
      assert html =~ "Set your service menu"
    end

    test "Skip-for-now marks step skipped + advances", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      html = render_click(lv, "skip_step", %{"step" => "branding"})

      reloaded =
        Ash.get!(DrivewayOS.Platform.Tenant, ctx.tenant.id, authorize?: false)

      assert reloaded.wizard_progress == %{"branding" => "skipped"}
      assert html =~ "Set your service menu"
    end

    test "wizard redirects to /admin when all steps are complete or skipped", ctx do
      # Mark every step as skipped (cheapest way to satisfy Wizard.complete?/1).
      for step_id <- [:branding, :services, :schedule, :payment, :email] do
        ctx.tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{step: step_id, status: :skipped})
        |> Ash.update!(authorize?: false)
      end

      conn = sign_in(ctx.conn, ctx.admin)

      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/admin/onboarding")
    end
  end
```

- [ ] **Step 2: Run tests; verify the new ones fail**

```bash
mix test test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs
```

Expected: 4 new tests fail (wizard renders the Phase 0 stub, not the linear flow). Existing 4 may also need updating once we change the page content — fix in Step 4 below.

- [ ] **Step 3: Rewrite the wizard LV**

Replace the entire content of `lib/driveway_os_web/live/admin/onboarding_wizard_live.ex` with:

```elixir
defmodule DrivewayOSWeb.Admin.OnboardingWizardLive do
  @moduledoc """
  Mandatory linear wizard at `/admin/onboarding`. Walks a freshly-
  provisioned tenant through Branding → Services → Schedule →
  Payment → Email.

  State machine: `DrivewayOS.Onboarding.Wizard` (pure functions).
  Persistence: `tenant.wizard_progress` jsonb map (only `:skipped`
  flags persisted; done-ness is computed via each step's
  `complete?/1` predicate).

  When `Wizard.complete?/1` returns true, the LV redirects to
  `/admin` with a flash. Skip-for-later writes a :skipped flag and
  re-renders against the next step. The wizard does not lock the
  tenant in — direct navigation to `/admin` works mid-wizard.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Onboarding.Wizard

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      Wizard.complete?(socket.assigns.current_tenant) ->
        {:ok,
         socket
         |> put_flash(:info, "You're all set. Welcome to your dashboard.")
         |> push_navigate(to: ~p"/admin")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Set up your shop")
         |> assign(:errors, %{})
         |> assign_step()}
    end
  end

  defp assign_step(socket) do
    step = Wizard.current_step(socket.assigns.current_tenant)
    assign(socket, :current_step, step)
  end

  @impl true
  def handle_event("step_submit", params, socket) do
    step = socket.assigns.current_step

    case step.submit(params, socket) do
      {:ok, socket} ->
        socket = assign(socket, :errors, %{})

        if Wizard.complete?(socket.assigns.current_tenant) do
          {:noreply,
           socket
           |> put_flash(:info, "You're all set. Welcome to your dashboard.")
           |> push_navigate(to: ~p"/admin")}
        else
          {:noreply, assign_step(socket)}
        end

      {:error, message} ->
        {:noreply, assign(socket, :errors, %{base: message})}
    end
  end

  def handle_event("skip_step", %{"step" => step_id}, socket) do
    step_atom = String.to_existing_atom(step_id)
    {:ok, updated} = Wizard.skip(socket.assigns.current_tenant, step_atom)

    socket = assign(socket, :current_tenant, updated)

    if Wizard.complete?(updated) do
      {:noreply,
       socket
       |> put_flash(:info, "You're all set. Welcome to your dashboard.")
       |> push_navigate(to: ~p"/admin")}
    else
      {:noreply, assign_step(socket)}
    end
  end

  defp step_position(step) do
    Wizard.steps() |> Enum.find_index(&(&1 == step)) |> Kernel.+(1)
  end

  defp total_steps, do: length(Wizard.steps())

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Skip to dashboard
          </a>
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mt-3">
            Step {step_position(@current_step)} of {total_steps()}
          </p>
          <h1 class="text-3xl font-bold tracking-tight">{@current_step.title()}</h1>
        </header>

        <div :if={@errors[:base]} role="alert" class="alert alert-error text-sm">
          {@errors[:base]}
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            {@current_step.render(assigns)}
          </div>
        </section>

        <div class="flex justify-end">
          <button
            type="button"
            phx-click="skip_step"
            phx-value-step={@current_step.id()}
            class="btn btn-ghost btn-sm text-base-content/60"
          >
            Skip for now
          </button>
        </div>
      </div>
    </main>
    """
  end
end
```

- [ ] **Step 4: Update the existing rendering tests in the file**

The existing tests "admin sees a page listing the Stripe Connect provider under Payment" and "providers that are already set up don't render" were testing the Phase 0 stub. With the new wizard they need updating: a fresh tenant now lands on Branding (not on the Payment card directly), and the Stripe row is shown only when the wizard reaches the Payment step.

Replace those two tests (inside the existing `describe "rendering"` block) with:

```elixir
    test "admin lands on the Branding step on a fresh tenant", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      assert html =~ "Step 1 of 5"
      assert html =~ "Make it yours"
    end
```

(Remove the second old "already set up" test entirely — the redirect-to-/admin test in the new `describe "linear flow"` block covers the all-done case.)

- [ ] **Step 5: Run all wizard LV tests; verify all pass**

```bash
mix test test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs
```

Expected: auth tests (2) + rendering test (1, updated) + linear flow tests (4) = 7 passes, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os_web/live/admin/onboarding_wizard_live.ex \
        test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs
git commit -m "Onboarding: rewrite wizard LV — linear flow + step submit/skip"
```

---

## Task 13: Routing changes — signup redirect + Stripe callback redirect

**Files:**
- Modify: `lib/driveway_os_web/live/signup_live.ex`
- Modify: `lib/driveway_os_web/controllers/stripe_onboarding_controller.ex`
- Modify: `test/driveway_os_web/live/signup_live_test.exs`
- Modify: `test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs`

- [ ] **Step 1: Update SignupLive's redirect target**

Find the `tenant_admin_signed_in_url/2` helper in `lib/driveway_os_web/live/signup_live.ex`. Change `return_to`:

```elixir
defp tenant_admin_signed_in_url(tenant, admin) do
  {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

  base = tenant_root_base_url(tenant)
  return_to = URI.encode_www_form("/admin/onboarding")
  encoded_token = URI.encode_www_form(token)

  "#{base}/auth/customer/store-token?token=#{encoded_token}&return_to=#{return_to}"
end
```

(Was `/admin`; now `/admin/onboarding`.)

- [ ] **Step 2: Update the corresponding signup test**

In `test/driveway_os_web/live/signup_live_test.exs`, find the test "creates tenant + admin, redirects to tenant subdomain root". The assertion likely checks `return_to=%2Fadmin` — update to `return_to=%2Fadmin%2Fonboarding`. Read the test first; keep the rest of its assertions the same.

- [ ] **Step 3: Update the Stripe callback to honor the wizard**

In `lib/driveway_os_web/controllers/stripe_onboarding_controller.ex`, find the `callback/2` function. The success branch currently does `redirect(conn, external: tenant_admin_url(updated))` (going to `/admin`). Update it to route to `/admin/onboarding` if the wizard is incomplete:

```elixir
  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, tenant_id} <- StripeConnect.verify_state(state),
         tenant when not is_nil(tenant) <- Ash.get!(Platform.Tenant, tenant_id),
         {:ok, updated} <- StripeConnect.complete_onboarding(tenant, code) do
      redirect(conn, external: tenant_post_stripe_url(updated))
    else
      _ -> send_resp(conn, 400, "Stripe onboarding failed.")
    end
  end
```

Add a new private helper next to `tenant_admin_url/1`:

```elixir
  defp tenant_post_stripe_url(tenant) do
    base = tenant_admin_url(tenant) |> String.replace_suffix("/admin", "")

    if DrivewayOS.Onboarding.Wizard.complete?(tenant) do
      base <> "/admin"
    else
      base <> "/admin/onboarding"
    end
  end
```

(The string-suffix dance keeps us reusing `tenant_admin_url/1`'s scheme/host/port logic without duplicating it.)

Add an `alias DrivewayOS.Onboarding.Wizard` near the top of the controller if it isn't there already.

- [ ] **Step 4: Add a Stripe-callback test for the new redirect logic**

In `test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs`, append a new test inside the `describe "GET /onboarding/stripe/callback"` block:

```elixir
    test "wizard incomplete: callback redirects to /admin/onboarding",
         %{conn: conn, tenant: tenant} do
      # Mint a real state token by calling oauth_url_for first.
      DrivewayOS.Billing.StripeConnect.oauth_url_for(tenant)

      [%{token: state_token}] =
        DrivewayOS.Platform.OauthState
        |> Ash.read!(authorize?: false)

      # Stub Stripe code-exchange via the existing client mock pattern.
      DrivewayOS.Billing.StripeClientMock
      |> Mox.expect(:exchange_code, fn _code, _opts ->
        {:ok, %{stripe_user_id: "acct_test_x"}}
      end)

      conn =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> get("/onboarding/stripe/callback", %{
          "code" => "ac_test",
          "state" => state_token
        })

      assert redirected_to(conn, 302) =~ "/admin/onboarding"
    end
```

(The test mirrors the existing happy-path test in the file but asserts the new redirect target.)

- [ ] **Step 5: Run touched test files; verify all pass**

```bash
mix test test/driveway_os_web/live/signup_live_test.exs \
         test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs
```

Expected: all pass. The signup test's updated assertion now matches the new redirect target.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os_web/live/signup_live.ex \
        lib/driveway_os_web/controllers/stripe_onboarding_controller.ex \
        test/driveway_os_web/live/signup_live_test.exs \
        test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs
git commit -m "Routing: signup → /admin/onboarding, Stripe callback honors wizard state"
```

---

## Task 14: Dashboard refactor — share `complete?` predicates

The dashboard's `missing_branding?/1` and `using_default_services?/1` are now duplicated by `Steps.Branding.complete?/1` and `Steps.Services.complete?/1`. Replace the local predicates with calls to the steps so wizard + dashboard share one source of truth.

**Files:**
- Modify: `lib/driveway_os_web/live/admin/dashboard_live.ex`

- [ ] **Step 1: Update build_checklist to call Step.complete?**

In `dashboard_live.ex`, find `build_checklist/4`. The internal_items list currently has these two predicates:

```elixir
      using_default_services?(services) &&
        {"Set your service menu", ...},
      ...
      missing_branding?(tenant) &&
        {"Make it yours", ...},
```

Replace with:

```elixir
      not DrivewayOS.Onboarding.Steps.Services.complete?(tenant) &&
        {"Set your service menu", ...},
      ...
      not DrivewayOS.Onboarding.Steps.Branding.complete?(tenant) &&
        {"Make it yours", ...},
```

The tuple bodies stay identical. Only the predicate changes.

- [ ] **Step 2: Remove the now-dead local helpers**

Find `defp using_default_services?(services)` and `defp missing_branding?(tenant)` further down in the file. Delete both functions. (They were the only call sites; the new code calls into the Step modules.)

- [ ] **Step 3: Run the dashboard tests**

```bash
mix test test/driveway_os_web/live/admin_dashboard_test.exs
```

Expected: all 29 (or whatever the current count is) pass without modification — the predicate behaviour is identical, just sourced differently. If a test fails, the most likely reason is that the Services step calls into ServiceType.read which uses `Ash.Query.set_tenant`; the existing dashboard test setups should already provision a tenant context so this is a no-op concern.

- [ ] **Step 4: Commit**

```bash
git add lib/driveway_os_web/live/admin/dashboard_live.ex
git commit -m "Dashboard: source Branding/Services predicates from Onboarding.Steps"
```

---

## Task 15: Mailer — per-tenant Postmark routing

The Mailer needs to switch to a tenant-specific Postmark adapter when the tenant has provisioned Postmark; otherwise fall back to the existing shared SMTP config.

**Files:**
- Modify: `lib/driveway_os/mailer.ex`
- Modify: any send-site that has access to a `tenant` to use `Mailer.deliver(email, Mailer.for_tenant(tenant))`

- [ ] **Step 1: Inspect the existing Mailer + figure out the send sites**

Read `lib/driveway_os/mailer.ex` first. The current shape is likely just:

```elixir
defmodule DrivewayOS.Mailer do
  use Swoosh.Mailer, otp_app: :driveway_os
end
```

The send-sites we need to update are the ones in `lib/driveway_os/notifications/booking_email.ex` (or wherever booking confirmations go out). Find them with:

```bash
grep -rn "Mailer.deliver" lib/
```

- [ ] **Step 2: Add the `for_tenant/1` helper**

Update `lib/driveway_os/mailer.ex`:

```elixir
defmodule DrivewayOS.Mailer do
  use Swoosh.Mailer, otp_app: :driveway_os

  @doc """
  Returns Mailer config tuned to the given tenant. Tenants with a
  Postmark API key on file get a Swoosh.Adapters.Postmark config
  scoped to their server; tenants without one fall back to the
  default Mailer config (shared SMTP).

  Pass the result as the second argument to `Mailer.deliver/2`:

      DrivewayOS.Mailer.deliver(email, DrivewayOS.Mailer.for_tenant(tenant))
  """
  @spec for_tenant(DrivewayOS.Platform.Tenant.t()) :: keyword()
  def for_tenant(%DrivewayOS.Platform.Tenant{postmark_api_key: key}) when is_binary(key) and key != "" do
    [
      adapter: Swoosh.Adapters.Postmark,
      api_key: key
    ]
  end

  def for_tenant(_tenant), do: []
end
```

Empty keyword list means "use the Mailer's compile-time/runtime config" — Swoosh.Mailer.deliver/2 with `[]` falls back to the configured adapter unchanged.

- [ ] **Step 3: Update the send-sites**

In `lib/driveway_os/notifications/booking_email.ex` (and wherever else `Mailer.deliver/1` is called with access to a tenant), update calls of the form:

```elixir
Mailer.deliver(email)
```

to:

```elixir
Mailer.deliver(email, Mailer.for_tenant(tenant))
```

ONLY change call sites that have a `tenant` already in scope. Sites that don't (e.g. platform-wide admin emails to DrivewayOS staff) leave alone.

- [ ] **Step 4: Verify it compiles**

```bash
mix compile
```

Expected: no warnings about `Mailer.deliver/2`. If a call site has the wrong arity or types, fix.

- [ ] **Step 5: Run the full suite**

```bash
mix test
```

Expected: all green. The default test config uses `Swoosh.Adapters.Test` which captures emails to the process mailbox; passing `[]` as second arg to `deliver/2` doesn't override that. Tests that called `assert_email_sent/1` continue to work.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/mailer.ex \
        lib/driveway_os/notifications/booking_email.ex
git commit -m "Mailer: per-tenant Postmark routing for tenant-context sends"
```

---

## Task 16: Runtime config + DEPLOY.md

**Files:**
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Modify: `DEPLOY.md`

- [ ] **Step 1: Read POSTMARK_ACCOUNT_TOKEN in runtime.exs**

Find the existing Stripe envvar block in `config/runtime.exs`. Add Postmark next to it:

```elixir
if config_env() != :test do
  config :driveway_os,
    postmark_account_token: System.get_env("POSTMARK_ACCOUNT_TOKEN") || ""
end
```

Place it in the `if config_env() != :test do` block where Stripe envvars are read.

- [ ] **Step 2: Configure test.exs**

In `config/test.exs`, ensure the test env has a non-empty placeholder so `Postmark.configured?/0` returns true in tests that need it:

```elixir
config :driveway_os, :postmark_account_token, "test-account-token-placeholder"
```

- [ ] **Step 3: Update DEPLOY.md**

In `DEPLOY.md`, find the "Per-tenant integrations" env-var table. Add:

```markdown
| `POSTMARK_ACCOUNT_TOKEN` | Postmark account-level token used to provision tenant-scoped Servers via the API. |
```

Place it in the existing table next to the `STRIPE_*` entries.

- [ ] **Step 4: Verify compilation + full suite**

```bash
mix compile
mix test
```

Expected: clean compile, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add config/runtime.exs config/test.exs DEPLOY.md
git commit -m "Config: POSTMARK_ACCOUNT_TOKEN env + DEPLOY.md entry"
```

---

## Task 17: Final verification + push

- [ ] **Step 1: Confirm clean working tree**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Run the full suite**

```bash
mix test
```

Expected: 0 failures. Total count = previous green count (570) + new tests added in Tasks 1, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13 ≈ 575 + ~25 = ~600. Don't fixate on the exact number — 0 failures is what matters.

- [ ] **Step 3: Push**

```bash
git push origin main
```

Expected: push succeeds. Phase 1's commits are now visible on origin/main.

---

## Self-review

**Spec coverage:**

| Spec section | Covered by task |
|---|---|
| Architecture / Module layout (table) | All tasks land each module |
| Architecture / Data model | Task 1 |
| Architecture / `Step` behaviour | Task 2 |
| Architecture / `Wizard` FSM | Task 3 |
| Architecture / Provider gains `provision/2` | Task 4 |
| Architecture / Postmark provider | Task 6 |
| Architecture / PostmarkClient | Task 5 |
| Architecture / Welcome verification email | Task 6 (impl) + Task 11 (call site) |
| Architecture / `OnboardingWizardLive` rewrite | Task 12 |
| Architecture / Routing — signup | Task 13 |
| Architecture / Routing — Stripe callback | Task 13 |
| Architecture / Dashboard refactor | Task 14 |
| Architecture / Mailer integration | Task 15 |
| Constraints / FSM as pure functions | Task 3 |
| Constraints / jsonb persistence, only :skipped | Task 1 + Task 3 |
| Constraints / done is computed | Tasks 7–11 (each step's `complete?/1`) |
| Constraints / Branding done = support_email | Task 7 |
| Constraints / Postmark verified by test-send | Task 6 |
| Constraints / Wizard does not lock in | Task 12 (back-link to /admin) |
| Out of scope (affiliate tagging, encryption, custom domains, Resend, Phase 1.5 emails) | Not implemented — confirmed not in any task |
| Deferred decisions / logo storage | Task 7 — uses URL string, mirrors existing /admin/branding |
| Deferred decisions / API key encryption | Task 1 — landed plaintext with `sensitive? true` flag, encryption is a Phase 2 follow-up |

All spec requirements covered. No gaps.

**Placeholder scan:**

Searched for "TBD", "TODO", "fill in", "implement later", "Add appropriate error handling", "similar to Task". One legitimate use of `Tenant.t()` (a real Elixir typespec, not a placeholder). No actual placeholders or vague guidance.

**Type / signature consistency:**

| Function / type | Defined in | Used in |
|---|---|---|
| `Step.id/0`, `title/0`, `complete?/1`, `render/1`, `submit/2` | Task 2 | Tasks 7–11 (impls), Task 12 (caller) |
| `Wizard.steps/0`, `current_step/2`, `complete?/2`, `skip/2`, `unskip/2`, `skipped?/2` | Task 3 | Task 12 (caller), Task 13 (Stripe callback), Task 14 (dashboard) |
| `Provider.provision/2` | Task 4 | Task 6 (Postmark impl), Task 4 (StripeConnect impl returns `:hosted_required`) |
| `PostmarkClient.create_server/2` | Task 5 | Task 6 (Postmark.provision/2 calls it) |
| `:set_wizard_progress` action with `:step` + `:status` args | Task 1 | Task 3 (Wizard.skip/unskip), tests in Tasks 1, 3, 12 |
| `tenant.wizard_progress` map shape (`%{step_id_string => "skipped"}`) | Task 1 | Task 3 (Wizard.skipped?/2 checks `Map.get(progress, to_string(step_id)) == "skipped"`) |
| `tenant.postmark_server_id` + `postmark_api_key` | Task 1 | Task 6 (Postmark.setup_complete?/1, save_credentials/3) |
| `Mailer.for_tenant/1` returning `keyword()` | Task 15 | Task 6 (Postmark welcome email) |

All consistent. The map-key form (`to_string(step_id)`) is used uniformly — `set_wizard_progress` change writes string keys, `Wizard.skipped?/2` reads with `to_string/1`, the test asserts `%{"branding" => "skipped"}`.

No issues found. Plan is ready for execution.
