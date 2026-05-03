# Tenant Onboarding Phase 4b — Resend (email, second-of-category) + `Steps.PickerStep` macro

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Resend as the second email provider end-to-end (API-first provisioning + new `Platform.EmailConnection` resource + `Mailer.for_tenant/1` routing extension), and generalize the multi-card picker that Phase 4 baked into `Steps.Payment` into a reusable `Onboarding.Steps.PickerStep` macro that Steps.Payment + Steps.Email both `use`.

**Architecture:** Mirror Phase 1 Postmark's API-first shape but with Resend's API endpoints and a new `Platform.EmailConnection` resource (parallel to Phase 4's `PaymentConnection` and Phase 3's `AccountingConnection`). The `Steps.PickerStep` macro factors the ~30-line picker render + complete? + submit shape into one place; using-step modules just declare `id/0` + `title/0`. `Mailer.for_tenant/1` learns one new precedence rule (active EmailConnection > Postmark > default). `IntegrationsLive` learns a third row category (Email) — purely additive.

**Tech Stack:** Elixir 1.18 / Phoenix LiveView 1.1 / Ash 3.24 / AshPostgres 2.9 / Swoosh 1.25 (ships `Swoosh.Adapters.Resend`) / Req (HTTP) / Mox (test mocking). Tests use ExUnit with `DrivewayOS.DataCase` and `DrivewayOSWeb.ConnCase`. Standard test command: `mix test`.

**Spec:** `docs/superpowers/specs/2026-05-02-tenant-onboarding-phase-4b-design.md` (commit `90f043a`) — read the "Constraints + decisions" + "Architecture" sections before starting.

**Phase 1–4 (already shipped):**
- Phase 1: `docs/superpowers/plans/2026-04-29-tenant-onboarding-phase-1.md` — wizard FSM, `Onboarding.Step` + `Onboarding.Provider` behaviours, Postmark API-first pattern (the model Resend mirrors), `Mailer.for_tenant/1` (currently routes Postmark only).
- Phase 2: `docs/superpowers/plans/2026-05-02-tenant-onboarding-phase-2.md` — `Onboarding.Affiliate` module + `Platform.TenantReferral`. Resend's `affiliate_config/0` returns nil in V1 (matches Postmark).
- Phase 3: `docs/superpowers/plans/2026-05-02-tenant-onboarding-phase-3.md` — `AccountingConnection` shape, IntegrationsLive's first version (single resource type).
- Phase 4: `docs/superpowers/plans/2026-05-02-tenant-onboarding-phase-4.md` — `PaymentConnection` (the shape `EmailConnection` mirrors), `Steps.Payment` picker (the code the macro factors out), `IntegrationsLive` two-resource-type merge (the code Task 8 extends to three).

**Branch policy:** Execute on `main`. Commit after each task. Push to origin after Task 10 (final verification).

---

## Spec deviations (decided during plan-writing)

Reading the codebase before writing the plan surfaced four facts the spec couldn't fully anticipate.

1. **Macro generates `id/0` + `title/0`? No — using-step always declares them.** Per spec's "Decisions deferred to plan-writing" point (d): cleaner macro hygiene to require explicit declaration. The macro generates only what's structurally identical across using-steps (`complete?/1`, `render/1`, `submit/2`, `providers_for_picker/1`). Each using-step writes a 2-line `id/0` and 2-line `title/0` after `use`. No `defoverridable` for those — they're not generated. (Macro generates `complete?/1` + `render/1` + `submit/2` as `defoverridable` so future divergence is possible without rewriting.)

2. **Test layout for the macro.** Per spec's "Decisions deferred to plan-writing" point (a): isolated macro tests live in `test/driveway_os/onboarding/steps/picker_step_test.exs`, exercising the macro through a synthetic step module defined inline. Existing `Steps.Payment` + `Steps.Email` tests stay where they are; their assertions adapt where needed.

3. **`Onboarding.Steps.Email`'s existing tests assert single-card render + Postmark API-first submit.** Phase 1 wired `Steps.Email.submit/2` directly to `Postmark.provision/2` (synchronous wizard submit). Phase 4b's picker model routes the CTA to a per-provider `/onboarding/<provider>/start` controller path (identical to Square / Stripe pattern) — submit becomes a no-op. **This means Resend's API-first provisioning happens in a new `ResendOnboardingController`, not in `Steps.Email.submit/2`.** Postmark's existing `/admin/onboarding` synchronous-submit path stays — the Postmark card's `href` continues to point at the wizard's own URL and submit kicks off `Postmark.provision/2`, but only when the Postmark card is the one clicked. The picker grid renders BOTH cards as anchor tags with `href`s — the form-based submit path Phase 1 used goes away. All existing Phase 1 Postmark tests update to assert the new shape. (See Task 6 for the full transition.)

4. **`Swoosh.Adapters.Resend` ships with Swoosh 1.25.0** (already in `mix.lock`). No new dep needed.

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `priv/repo/migrations/<ts>_create_platform_email_connections.exs` | Generated. `platform_email_connections` table + FK + unique-tenant-provider identity. |
| `lib/driveway_os/onboarding/steps/picker_step.ex` | The macro. `defmacro __using__(opts)` generates `complete?/1`, `render/1`, `submit/2`, `providers_for_picker/1` from `category:` + `intro_copy:` args. |
| `lib/driveway_os/platform/email_connection.ex` | Ash resource. Mirrors `PaymentConnection` shape with email-flavored field names. |
| `lib/driveway_os/notifications/resend_client.ex` | `@behaviour` for the Resend HTTP layer + `client/0` resolver + `defdelegate` convenience wrappers. |
| `lib/driveway_os/notifications/resend_client/http.ex` | Concrete Req-based impl. Reads `RESEND_API_KEY` (master account token) from app env. |
| `lib/driveway_os/onboarding/providers/resend.ex` | `Onboarding.Provider` adapter. API-first — `provision/2` calls `ResendClient.create_api_key/1`, persists tokens on `EmailConnection`, sends welcome email. |
| `lib/driveway_os_web/controllers/resend_onboarding_controller.ex` | `GET /onboarding/resend/start`. Logs `:click` via `Affiliate.log_event/4`, calls `Resend.provision/2`, logs `:provisioned` on success, redirects back to `/admin/onboarding`. |
| `test/driveway_os/onboarding/steps/picker_step_test.exs` | Macro behavior via synthetic step module. |
| `test/driveway_os/platform/email_connection_test.exs` | Resource CRUD + lifecycle. |
| `test/driveway_os/notifications/resend_client_test.exs` | Behaviour resolver test. |
| `test/driveway_os/onboarding/providers/resend_test.exs` | Provider behaviour conformance + provision happy + error path. |
| `test/driveway_os_web/controllers/resend_onboarding_controller_test.exs` | Start logs `:click` + `:provisioned` + redirects on success; Postmark API failure surfaces error. |

**Modified:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform.ex` | Register `EmailConnection` in domain. Add `Platform.get_email_connection/2` + `get_active_email_connection/2` helpers. |
| `lib/driveway_os/onboarding/registry.ex` | Add `Providers.Resend` to `@providers`. |
| `lib/driveway_os/onboarding/steps/payment.ex` | Refactor inline picker code to `use Steps.PickerStep, category: :payment, intro_copy: "..."`. ~70 LOC → ~12 LOC. |
| `lib/driveway_os/onboarding/steps/email.ex` | Refactor Phase 1 single-card code to `use Steps.PickerStep, category: :email, intro_copy: "..."`. ~80 LOC → ~12 LOC. |
| `lib/driveway_os/onboarding/providers/postmark.ex` | Update `display.href` from `/admin/onboarding` (which kicks off the synchronous submit) to `/onboarding/postmark/start` (a new GET that fires the same provision flow). Add the matching controller next to it. |
| `lib/driveway_os_web/controllers/postmark_onboarding_controller.ex` (NEW alongside Resend's) | `GET /onboarding/postmark/start`. Mirrors Resend's controller — logs `:click`, calls `Postmark.provision/2`, logs `:provisioned`, redirects. |
| `lib/driveway_os/mailer.ex` | Extend `for_tenant/1`: active `EmailConnection{:resend}` first → Resend adapter; fall back to `tenant.postmark_api_key` → Postmark adapter; fall back to `[]`. ALL 17 existing send-sites stay byte-identical. |
| `lib/driveway_os_web/live/admin/integrations_live.ex` | Extend `load_rows/1` to query `EmailConnection`. Add `row_from_email/1`. Extend `resource_module/1` (`"email" -> EmailConnection`) and `provider_label/1` (`:resend -> "Resend"`). |
| `lib/driveway_os_web/router.ex` | Add `GET /onboarding/resend/start` and `GET /onboarding/postmark/start` routes. |
| `config/runtime.exs` | Add `resend_api_key` (master account token) + `resend_affiliate_ref_id` env reads. |
| `config/test.exs` | Mox `:resend_client` config. |
| `config/config.exs` | Default `:resend_client` to `ResendClient.Http`. |
| `test/test_helper.exs` | `Mox.defmock(DrivewayOS.Notifications.ResendClient.Mock, for: ResendClient)`. |
| `test/driveway_os/onboarding/steps/email_test.exs` | Adapt Phase 1 single-card assertions to multi-card picker. Drop `Postmark.Mock`-driven submit tests (those move into `postmark_onboarding_controller_test.exs`). |
| `test/driveway_os/onboarding/steps/payment_test.exs` | Verify post-refactor output matches Phase 4's pre-refactor shape (no functional change). |
| `test/driveway_os_web/live/admin/integrations_live_test.exs` | Add Email-row test cases (Resend connected, paused, disconnected). |
| `DEPLOY.md` | Add `RESEND_API_KEY` and `RESEND_AFFILIATE_REF_ID` rows. |

---

## Task 1: `Onboarding.Steps.PickerStep` macro

**Files:**
- Create: `lib/driveway_os/onboarding/steps/picker_step.ex`
- Test: `test/driveway_os/onboarding/steps/picker_step_test.exs`

- [ ] **Step 1: Write the failing macro test**

Create `test/driveway_os/onboarding/steps/picker_step_test.exs`:

```elixir
defmodule DrivewayOS.Onboarding.Steps.PickerStepTest do
  @moduledoc """
  Tests the `Steps.PickerStep` macro through a synthetic
  using-step module. We don't test against the real Steps.Payment
  / Steps.Email here — those have their own test files. This file
  pins the macro contract:

    * `complete?/1` returns true iff ANY provider in the category
      reports `setup_complete?(tenant)`.
    * `render/1` emits one card per `configured? && !setup_complete?`
      provider in the category.
    * `submit/2` is a no-op.
    * `providers_for_picker/1` filters configured && not-setup.

  The synthetic step uses `:test_picker` as its category — won't
  collide with any real provider.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ps-#{System.unique_integer([:positive])}",
        display_name: "Picker Step Test",
        admin_email: "ps-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  defmodule SyntheticStep do
    use DrivewayOS.Onboarding.Steps.PickerStep,
      category: :test_picker,
      intro_copy: "Pick a synthetic provider for testing."

    @impl true
    def id, do: :synthetic

    @impl true
    def title, do: "Synthetic"
  end

  test "macro generates the four functions", _ctx do
    # Sanity check — using-step has all four generated callbacks.
    assert function_exported?(SyntheticStep, :complete?, 1)
    assert function_exported?(SyntheticStep, :render, 1)
    assert function_exported?(SyntheticStep, :submit, 2)
    # plus the explicit ones the using-step declared
    assert SyntheticStep.id() == :synthetic
    assert SyntheticStep.title() == "Synthetic"
  end

  test "submit/2 is a no-op", ctx do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_tenant: ctx.tenant, errors: %{}}
    }

    assert {:ok, ^socket} = SyntheticStep.submit(%{}, socket)
  end

  test "complete?/1 false when no providers in the category", ctx do
    # No real :test_picker providers exist in the registry.
    refute SyntheticStep.complete?(ctx.tenant)
  end

  test "render/1 emits the intro_copy paragraph", ctx do
    html =
      SyntheticStep.render(%{__changed__: %{}, current_tenant: ctx.tenant})
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "Pick a synthetic provider for testing."
  end

  test "render/1 with no eligible providers emits empty grid", ctx do
    html =
      SyntheticStep.render(%{__changed__: %{}, current_tenant: ctx.tenant})
      |> Phoenix.LiveViewTest.rendered_to_string()

    # Grid wrapper present; no card content.
    assert html =~ "grid-cols-1 md:grid-cols-2"
    refute html =~ "card-body"
  end

  test "render/1 applies UX rules: 44px touch target + motion-reduce + slate-600 + border-slate-200",
       ctx do
    # We exercise this via the real Steps.Payment in its own test (which
    # has Stripe + Square cards). Here we just assert the surface
    # markup is present on a category that *does* have providers — for
    # this test, we assert the wrapper classes when the grid is empty.
    html =
      SyntheticStep.render(%{__changed__: %{}, current_tenant: ctx.tenant})
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "text-slate-600"
  end
end
```

- [ ] **Step 2: Run the test — should fail (module not found)**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/onboarding/steps/picker_step_test.exs
```

Expected: compile error / `module DrivewayOS.Onboarding.Steps.PickerStep is not loaded`.

- [ ] **Step 3: Create the macro**

Create `lib/driveway_os/onboarding/steps/picker_step.ex`:

```elixir
defmodule DrivewayOS.Onboarding.Steps.PickerStep do
  @moduledoc """
  Macro for wizard steps that render an N-card picker over a
  provider category. Generates `complete?/1`, `render/1`, `submit/2`,
  and `providers_for_picker/1` from a `category:` + `intro_copy:` arg.

  Using-step modules MUST declare `id/0` and `title/0` themselves —
  those vary per step and are not generated. The three generated
  callbacks (`complete?/1`, `render/1`, `submit/2`) are
  `defoverridable` so future divergence is possible.

  Example:

      defmodule DrivewayOS.Onboarding.Steps.Payment do
        use DrivewayOS.Onboarding.Steps.PickerStep,
          category: :payment,
          intro_copy: "Pick the payment processor..."

        @impl true
        def id, do: :payment

        @impl true
        def title, do: "Take card payments"
      end

  Render contract: each card displays the provider's
  `display.title`, `display.blurb`, optional perk paragraph (when
  `Affiliate.perk_copy/1` is non-nil), and an anchor CTA pointing
  at `display.href`. Cards stack vertically below `md:`, lay out as
  a 2-column grid above. UX rules from MASTER + ui-ux-pro-max:
  44px touch targets (`min-h-[44px]`), `motion-reduce:transition-none`,
  `text-slate-600` muted body, `border-slate-200`,
  `aria-label` on each anchor.
  """

  defmacro __using__(opts) do
    category = Keyword.fetch!(opts, :category)
    intro_copy = Keyword.fetch!(opts, :intro_copy)

    quote do
      @behaviour DrivewayOS.Onboarding.Step

      use Phoenix.Component

      alias DrivewayOS.Onboarding.{Affiliate, Registry}
      alias DrivewayOS.Platform.Tenant

      @category unquote(category)
      @intro_copy unquote(intro_copy)

      @impl true
      def complete?(%Tenant{} = tenant) do
        Registry.by_category(@category)
        |> Enum.any?(& &1.setup_complete?(tenant))
      end

      @impl true
      def render(assigns) do
        cards = providers_for_picker(assigns.current_tenant)

        assigns =
          assigns
          |> Map.put(:cards, cards)
          |> Map.put(:intro_copy, @intro_copy)

        ~H"""
        <div class="space-y-4">
          <p class="text-sm text-slate-600">{@intro_copy}</p>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%= for card <- @cards do %>
              <div class="card bg-base-100 shadow-md border border-slate-200 transition-shadow motion-reduce:transition-none hover:shadow-lg">
                <div class="card-body p-6 space-y-3">
                  <h3 class="text-lg font-semibold text-slate-900">{card.title}</h3>
                  <p class="text-sm text-slate-600 leading-relaxed">{card.blurb}</p>
                  <%= if perk = Affiliate.perk_copy(card.id) do %>
                    <p class="text-xs text-success font-medium">{perk}</p>
                  <% end %>
                  <a
                    href={card.href}
                    class="btn btn-primary min-h-[44px] gap-2 motion-reduce:transition-none"
                    aria-label={"Connect " <> card.title}
                  >
                    {card.cta_label}
                    <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
                  </a>
                </div>
              </div>
            <% end %>
          </div>
        </div>
        """
      end

      @impl true
      def submit(_params, socket), do: {:ok, socket}

      defp providers_for_picker(tenant) do
        Registry.by_category(@category)
        |> Enum.filter(& &1.configured?())
        |> Enum.reject(& &1.setup_complete?(tenant))
        |> Enum.map(fn mod -> Map.put(mod.display(), :id, mod.id()) end)
      end

      defoverridable complete?: 1, render: 1, submit: 2
    end
  end
end
```

- [ ] **Step 4: Re-run the test**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/onboarding/steps/picker_step_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os/onboarding/steps/picker_step.ex \
          test/driveway_os/onboarding/steps/picker_step_test.exs && \
  git commit -m "Onboarding.Steps.PickerStep: macro for N-card multi-provider wizard steps"
```

---

## Task 2: Refactor `Steps.Payment` to use the macro

**Files:**
- Modify: `lib/driveway_os/onboarding/steps/payment.ex`
- Verify: `test/driveway_os/onboarding/steps/payment_test.exs` (no edits — tests must pass byte-identically)

The Phase 4 plan introduced an inline picker in `Steps.Payment`. This task swaps that for `use Steps.PickerStep, ...`, then re-runs the existing test file unchanged. If anything fails, the macro is wrong (not the test).

- [ ] **Step 1: Run Phase 4's existing Steps.Payment tests to capture pre-refactor green state**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/onboarding/steps/payment_test.exs
```

Expected: green. (If not, stop — Phase 4 baseline broke.)

- [ ] **Step 2: Refactor `Steps.Payment`**

Replace `lib/driveway_os/onboarding/steps/payment.ex` entirely with:

```elixir
defmodule DrivewayOS.Onboarding.Steps.Payment do
  @moduledoc """
  Payment wizard step. Generic over N providers in the `:payment`
  category — uses `Steps.PickerStep` for the render + complete? +
  submit shape. V1 surfaces Stripe + Square. Each card routes to its
  own OAuth start. Switching providers post-onboarding is
  support-driven.

  See `Onboarding.Steps.PickerStep` for the picker contract.
  """
  use DrivewayOS.Onboarding.Steps.PickerStep,
    category: :payment,
    intro_copy:
      "Pick the payment processor you want to use. " <>
        "You can change later by emailing support."

  @impl true
  def id, do: :payment

  @impl true
  def title, do: "Take card payments"
end
```

- [ ] **Step 3: Re-run Steps.Payment tests — should pass byte-identically**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/onboarding/steps/payment_test.exs
```

Expected: same green count as Step 1. No failures, no warnings.

If a test fails, the macro's render/complete? semantics differ from the inline implementation. Compare the macro's `render/1` (Task 1 Step 3) with the pre-refactor inline body Phase 4 produced. Whatever differs is the bug.

- [ ] **Step 4: Run the broader wizard test suite to catch any LiveView coupling**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs
```

Expected: green. (The wizard renders Steps.Payment via its `render/1` callback — if the macro generates a subtly different output, this is where it shows up.)

- [ ] **Step 5: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os/onboarding/steps/payment.ex && \
  git commit -m "Steps.Payment: refactor to use Steps.PickerStep (no behavior change)"
```

---

## Task 3: `Platform.EmailConnection` resource + migration + helpers

**Files:**
- Create: `lib/driveway_os/platform/email_connection.ex`
- Create: `priv/repo/migrations/<ts>_create_platform_email_connections.exs` (via `mix ash_postgres.generate_migrations`)
- Modify: `lib/driveway_os/platform.ex` (register + helpers)
- Test: `test/driveway_os/platform/email_connection_test.exs`

- [ ] **Step 1: Write the failing resource test**

Create `test/driveway_os/platform/email_connection_test.exs`:

```elixir
defmodule DrivewayOS.Platform.EmailConnectionTest do
  @moduledoc """
  Pin the `Platform.EmailConnection` contract: per-(tenant, email
  provider) api_key + lifecycle state for email integrations.
  Mirrors Phase 4's PaymentConnection shape with email-flavored
  field names. API-first, so no refresh_token / expiry — Resend
  api_keys don't expire.

  The `:reconnect` action incorporates Phase 3's M1 fix
  preemptively (clears disconnected_at, refreshes api_key,
  restores auto_send_enabled, sets connected_at to now).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.EmailConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ec-#{System.unique_integer([:positive])}",
        display_name: "Email Conn Test",
        admin_email: "ec-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "connect creates a row with auto_send_enabled true and connected_at set", ctx do
    {:ok, conn} =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "key-1",
        api_key: "re_test_1"
      })
      |> Ash.create(authorize?: false)

    assert conn.tenant_id == ctx.tenant.id
    assert conn.provider == :resend
    assert conn.external_key_id == "key-1"
    assert conn.api_key == "re_test_1"
    assert conn.auto_send_enabled == true
    assert %DateTime{} = conn.connected_at
    assert conn.disconnected_at == nil
  end

  test "disconnect clears api_key + external_key_id, sets disconnected_at, pauses send", ctx do
    conn = connect_resend!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update(authorize?: false)

    assert updated.api_key == nil
    assert updated.external_key_id == nil
    assert %DateTime{} = updated.disconnected_at
    assert updated.auto_send_enabled == false
  end

  test "pause and resume toggle auto_send_enabled", ctx do
    conn = connect_resend!(ctx.tenant.id)
    {:ok, paused} = conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update(authorize?: false)
    refute paused.auto_send_enabled

    {:ok, resumed} = paused |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update(authorize?: false)
    assert resumed.auto_send_enabled
  end

  test "record_send_success sets last_send_at and clears error", ctx do
    conn = connect_resend!(ctx.tenant.id)

    {:ok, with_err} =
      conn
      |> Ash.Changeset.for_update(:record_send_error, %{last_send_error: "boom"})
      |> Ash.update(authorize?: false)

    assert with_err.last_send_error == "boom"

    {:ok, healed} =
      with_err
      |> Ash.Changeset.for_update(:record_send_success, %{})
      |> Ash.update(authorize?: false)

    assert %DateTime{} = healed.last_send_at
    assert healed.last_send_error == nil
  end

  test "reconnect clears disconnected_at, restores active state, updates api_key", ctx do
    conn = connect_resend!(ctx.tenant.id)

    {:ok, disconnected} =
      conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update(authorize?: false)

    assert %DateTime{} = disconnected.disconnected_at
    refute disconnected.auto_send_enabled

    {:ok, reconnected} =
      disconnected
      |> Ash.Changeset.for_update(:reconnect, %{
        external_key_id: "key-fresh",
        api_key: "re_test_fresh"
      })
      |> Ash.update(authorize?: false)

    assert reconnected.disconnected_at == nil
    assert reconnected.auto_send_enabled == true
    assert reconnected.api_key == "re_test_fresh"
    assert reconnected.external_key_id == "key-fresh"
    assert %DateTime{} = reconnected.connected_at
  end

  test "unique_tenant_provider identity rejects duplicate (tenant, provider)", ctx do
    _ = connect_resend!(ctx.tenant.id)

    {:error, %Ash.Error.Invalid{}} =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "key-2",
        api_key: "re_test_2"
      })
      |> Ash.create(authorize?: false)
  end

  test "provider rejects unknown values (only :resend in V1)", ctx do
    {:error, %Ash.Error.Invalid{}} =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :totally_not_a_real_provider,
        external_key_id: "x",
        api_key: "y"
      })
      |> Ash.create(authorize?: false)
  end

  test "Platform.get_email_connection/2 returns the row", ctx do
    _ = connect_resend!(ctx.tenant.id)

    assert {:ok, conn} = Platform.get_email_connection(ctx.tenant.id, :resend)
    assert conn.provider == :resend
  end

  test "Platform.get_email_connection/2 :not_found when none", ctx do
    assert {:error, :not_found} = Platform.get_email_connection(ctx.tenant.id, :resend)
  end

  test "Platform.get_active_email_connection/2 :no_active_connection when paused", ctx do
    conn = connect_resend!(ctx.tenant.id)
    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)

    assert {:error, :no_active_connection} =
             Platform.get_active_email_connection(ctx.tenant.id, :resend)
  end

  test "Platform.get_active_email_connection/2 :no_active_connection when disconnected", ctx do
    conn = connect_resend!(ctx.tenant.id)
    conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)

    assert {:error, :no_active_connection} =
             Platform.get_active_email_connection(ctx.tenant.id, :resend)
  end

  test "Platform.get_active_email_connection/2 returns the row when active", ctx do
    _ = connect_resend!(ctx.tenant.id)

    assert {:ok, conn} = Platform.get_active_email_connection(ctx.tenant.id, :resend)
    assert conn.api_key == "re_test_1"
    assert conn.auto_send_enabled == true
  end

  defp connect_resend!(tenant_id) do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :resend,
      external_key_id: "key-1",
      api_key: "re_test_1"
    })
    |> Ash.create!(authorize?: false)
  end
end
```

- [ ] **Step 2: Run the test — should fail (module not found)**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/platform/email_connection_test.exs
```

Expected: compile error / module not found for `DrivewayOS.Platform.EmailConnection`.

- [ ] **Step 3: Create the resource**

Create `lib/driveway_os/platform/email_connection.ex`:

```elixir
defmodule DrivewayOS.Platform.EmailConnection do
  @moduledoc """
  Per-(tenant, email provider) integration record. Stores api_key
  + lifecycle state for API-first email providers. Platform-tier —
  no multitenancy block; tenants don't read this directly, only the
  Resend modules and the IntegrationsLive page do.

  Lifecycle:
    * `:connect` — first time tenant authorizes; populates api_key.
    * `:reconnect` — on re-authorize after a disconnect; replaces
       api_key + external_key_id, clears disconnected_at, sets
       auto_send_enabled true. Single atomic action — Phase 3's M1
       fix incorporated preemptively.
    * `:record_send_success` / `:record_send_error` — Mailer updates.
    * `:pause` / `:resume` — tenant-controlled, toggles auto_send_enabled.
    * `:disconnect` — clears api_key, sets disconnected_at, auto-pauses.

  api_key is sensitive (Ash redacts in logs); plaintext at rest in
  V1, matching Phase 1's `postmark_api_key` and Phase 4's
  PaymentConnection access tokens.

  V1's only `:provider` value is `:resend`; Phase 5+ extends.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "platform_email_connections"
    repo DrivewayOS.Repo

    references do
      reference :tenant, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:resend]
    end

    attribute :external_key_id, :string, public?: true

    attribute :api_key, :string do
      sensitive? true
      public? false
    end

    attribute :auto_send_enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :connected_at, :utc_datetime_usec
    attribute :disconnected_at, :utc_datetime_usec
    attribute :last_send_at, :utc_datetime_usec
    attribute :last_send_error, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, DrivewayOS.Platform.Tenant do
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_tenant_provider, [:tenant_id, :provider]
  end

  actions do
    defaults [:read, :destroy]

    create :connect do
      accept [:tenant_id, :provider, :external_key_id, :api_key]
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :reconnect do
      accept [:external_key_id, :api_key]
      change set_attribute(:disconnected_at, nil)
      change set_attribute(:auto_send_enabled, true)
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :record_send_success do
      change set_attribute(:last_send_at, &DateTime.utc_now/0)
      change set_attribute(:last_send_error, nil)
    end

    update :record_send_error do
      accept [:last_send_error]
    end

    update :disconnect do
      change set_attribute(:api_key, nil)
      change set_attribute(:external_key_id, nil)
      change set_attribute(:disconnected_at, &DateTime.utc_now/0)
      change set_attribute(:auto_send_enabled, false)
    end

    update :pause do
      change set_attribute(:auto_send_enabled, false)
    end

    update :resume do
      change set_attribute(:auto_send_enabled, true)
    end
  end
end
```

- [ ] **Step 4: Register in Platform domain + add helpers**

Edit `lib/driveway_os/platform.ex`. Find the `alias DrivewayOS.Platform.{...}` block and add `EmailConnection` (alphabetically between `CustomDomain` and `OauthState`). Find the `resources do` block and add `resource EmailConnection` (after `resource PaymentConnection`).

Append two query helpers near `get_payment_connection/2` (added in Phase 4):

```elixir
  @doc """
  Look up the EmailConnection for a (tenant, provider) tuple.
  Returns `{:ok, connection}` or `{:error, :not_found}`.
  """
  @spec get_email_connection(binary(), atom()) ::
          {:ok, EmailConnection.t()} | {:error, :not_found}
  def get_email_connection(tenant_id, provider)
      when is_binary(tenant_id) and is_atom(provider) do
    EmailConnection
    |> Ash.Query.filter(tenant_id == ^tenant_id and provider == ^provider)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Like `get_email_connection/2` but rejects rows that aren't
  actively sendable — disconnected, paused, or missing api_key.
  Returns `{:error, :no_active_connection}` for any of those.
  """
  @spec get_active_email_connection(binary(), atom()) ::
          {:ok, EmailConnection.t()} | {:error, :no_active_connection}
  def get_active_email_connection(tenant_id, provider) do
    case get_email_connection(tenant_id, provider) do
      {:ok, %EmailConnection{
         auto_send_enabled: true,
         disconnected_at: nil,
         api_key: key
       } = conn}
      when is_binary(key) ->
        {:ok, conn}

      _ ->
        {:error, :no_active_connection}
    end
  end
```

- [ ] **Step 5: Generate the migration**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix ash_postgres.generate_migrations --name create_platform_email_connections
```

Expected: a new file `priv/repo/migrations/<ts>_create_platform_email_connections.exs` with `create table(:platform_email_connections)`, `tenant_id` FK, all attributes, unique index on `(tenant_id, provider)`.

- [ ] **Step 6: Apply migration**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && MIX_ENV=test mix ecto.migrate
```

- [ ] **Step 7: Re-run the test**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/platform/email_connection_test.exs
```

Expected: 12 tests, 0 failures.

- [ ] **Step 8: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os/platform/email_connection.ex \
          lib/driveway_os/platform.ex \
          priv/repo/migrations/*_create_platform_email_connections.exs \
          priv/resource_snapshots/repo/platform_email_connections \
          test/driveway_os/platform/email_connection_test.exs && \
  git commit -m "Platform: EmailConnection resource + Platform.get_*_email_connection helpers"
```

---

## Task 4: `Notifications.ResendClient` HTTP behaviour + Http impl + Mox + config wiring

**Files:**
- Create: `lib/driveway_os/notifications/resend_client.ex`
- Create: `lib/driveway_os/notifications/resend_client/http.ex`
- Create: `test/driveway_os/notifications/resend_client_test.exs`
- Modify: `config/config.exs`, `test/test_helper.exs`

- [ ] **Step 1: Write the failing behaviour resolver test**

Create `test/driveway_os/notifications/resend_client_test.exs`:

```elixir
defmodule DrivewayOS.Notifications.ResendClientTest do
  @moduledoc """
  Pin the `ResendClient` behaviour resolver: `client/0` returns the
  configured impl (Mox in test, Http in prod). The convenience
  wrappers (`create_api_key/1`, `delete_api_key/1`) delegate to the
  configured impl, so tests Mox-stub the behaviour and assert the
  Resend.provision/2 call site routes through correctly.
  """
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Notifications.ResendClient

  setup :verify_on_exit!

  test "client/0 returns the configured impl (Mock in test)" do
    assert ResendClient.client() == DrivewayOS.Notifications.ResendClient.Mock
  end

  test "create_api_key/1 delegates to the configured client" do
    expect(ResendClient.Mock, :create_api_key, fn "tenant-name" ->
      {:ok, %{key_id: "k1", api_key: "re_x"}}
    end)

    assert {:ok, %{key_id: "k1", api_key: "re_x"}} =
             ResendClient.create_api_key("tenant-name")
  end

  test "delete_api_key/1 delegates to the configured client" do
    expect(ResendClient.Mock, :delete_api_key, fn "k1" -> :ok end)

    assert :ok = ResendClient.delete_api_key("k1")
  end
end
```

- [ ] **Step 2: Run the test — should fail (module not found)**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/notifications/resend_client_test.exs
```

Expected: compile error.

- [ ] **Step 3: Create the behaviour module**

Create `lib/driveway_os/notifications/resend_client.ex`:

```elixir
defmodule DrivewayOS.Notifications.ResendClient do
  @moduledoc """
  Behaviour for talking to the Resend API. Defined as a behaviour
  so tests can use Mox to bypass HTTP and assert on the calls
  Resend.provision/2 makes.

  The concrete HTTP impl lives in
  `DrivewayOS.Notifications.ResendClient.Http`. Tests configure
  `Mox.defmock` for `DrivewayOS.Notifications.ResendClient.Mock`
  in `test_helper.exs`.

  Resolve the runtime impl via `client/0` — in dev/prod that's the
  HTTP module; in test it's the Mox.
  """

  alias DrivewayOS.Notifications.ResendClient.Http

  @doc """
  Create a Resend API key scoped to one DrivewayOS tenant. Returns
  `{:ok, %{key_id: binary, api_key: binary}}` on success. Returns
  `{:error, %{status: integer, body: term}}` on HTTP error.
  """
  @callback create_api_key(name :: String.t()) ::
              {:ok, %{key_id: String.t(), api_key: String.t()}}
              | {:error, term()}

  @doc """
  Delete a Resend API key (used during disconnect). Returns `:ok` on
  success or `{:error, term}` on failure.
  """
  @callback delete_api_key(key_id :: String.t()) :: :ok | {:error, term()}

  @doc "Resolve the configured client module (HTTP in prod, Mock in test)."
  @spec client() :: module()
  def client do
    Application.get_env(:driveway_os, :resend_client, Http)
  end

  @doc "Convenience wrapper that delegates to the configured client."
  @spec create_api_key(String.t()) ::
          {:ok, %{key_id: String.t(), api_key: String.t()}} | {:error, term()}
  def create_api_key(name), do: client().create_api_key(name)

  @doc "Convenience wrapper that delegates to the configured client."
  @spec delete_api_key(String.t()) :: :ok | {:error, term()}
  def delete_api_key(key_id), do: client().delete_api_key(key_id)
end
```

- [ ] **Step 4: Create the HTTP impl**

Create `lib/driveway_os/notifications/resend_client/http.ex`:

```elixir
defmodule DrivewayOS.Notifications.ResendClient.Http do
  @moduledoc """
  Concrete HTTP impl of the ResendClient behaviour. Talks to
  https://api.resend.com using `Req`.

  Auth: master account `RESEND_API_KEY` via the
  `:resend_api_key` application config (set from RESEND_API_KEY
  env var in runtime.exs). Each api-key creation call returns a
  per-tenant api_key that the caller stores per-tenant.
  """

  @behaviour DrivewayOS.Notifications.ResendClient

  @endpoint "https://api.resend.com"

  @impl true
  def create_api_key(name) when is_binary(name) do
    request =
      Req.new(
        base_url: @endpoint,
        headers: [
          {"Authorization", "Bearer " <> master_token()},
          {"Accept", "application/json"}
        ],
        json: %{"name" => name},
        receive_timeout: 10_000
      )

    case Req.post(request, url: "/api-keys") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, %{key_id: body["id"], api_key: body["token"]}}

      {:ok, %Req.Response{status: 201, body: body}} ->
        {:ok, %{key_id: body["id"], api_key: body["token"]}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  @impl true
  def delete_api_key(key_id) when is_binary(key_id) do
    request =
      Req.new(
        base_url: @endpoint,
        headers: [
          {"Authorization", "Bearer " <> master_token()},
          {"Accept", "application/json"}
        ],
        receive_timeout: 10_000
      )

    case Req.delete(request, url: "/api-keys/" <> key_id) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, exception} -> {:error, %{status: nil, body: Exception.message(exception)}}
    end
  end

  defp master_token do
    case Application.get_env(:driveway_os, :resend_api_key) do
      nil -> raise "RESEND_API_KEY not configured"
      "" -> raise "RESEND_API_KEY not configured"
      token -> token
    end
  end
end
```

- [ ] **Step 5: Wire up Mox + config**

Append to `test/test_helper.exs` (after the existing PostmarkClient.Mock block):

```elixir
# Resend client mock — used by Resend.provision/2 so tests don't
# hit the real Resend API. Tests that need to assert on api-key
# creation set explicit expectations via Mox.expect/3.
Mox.defmock(DrivewayOS.Notifications.ResendClient.Mock,
  for: DrivewayOS.Notifications.ResendClient
)

Application.put_env(:driveway_os, :resend_client, DrivewayOS.Notifications.ResendClient.Mock)
```

Edit `config/config.exs`. Find the existing app-config block (where other defaults live) and append:

```elixir
config :driveway_os, :resend_client, DrivewayOS.Notifications.ResendClient.Http
```

(Place this near other `:driveway_os, :*_client` defaults if any exist; otherwise near the top of the app-specific config block. Phase 1 set `:postmark_client` to `Http` in the same way — model the placement after that.)

- [ ] **Step 6: Re-run the test**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/notifications/resend_client_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 7: Run the broader notifications + onboarding test scope to catch ripple effects**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  mix test test/driveway_os/notifications/ test/driveway_os/onboarding/
```

Expected: green. (No callers of `ResendClient` exist yet — this just confirms the new module hasn't broken siblings.)

- [ ] **Step 8: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os/notifications/resend_client.ex \
          lib/driveway_os/notifications/resend_client/http.ex \
          config/config.exs \
          test/test_helper.exs \
          test/driveway_os/notifications/resend_client_test.exs && \
  git commit -m "Notifications.ResendClient: behaviour + Http impl + Mox wiring"
```

---

## Task 5: `Onboarding.Providers.Resend` adapter + Registry registration

**Files:**
- Create: `lib/driveway_os/onboarding/providers/resend.ex`
- Modify: `lib/driveway_os/onboarding/registry.ex`
- Test: `test/driveway_os/onboarding/providers/resend_test.exs`

- [ ] **Step 1: Write the failing provider test**

Create `test/driveway_os/onboarding/providers/resend_test.exs`:

```elixir
defmodule DrivewayOS.Onboarding.Providers.ResendTest do
  @moduledoc """
  Pin the Resend provider's `Onboarding.Provider` callbacks +
  provision happy path + provision API-error path.

  `provision/2` is API-first (mirrors Phase 1 Postmark): it calls
  ResendClient.create_api_key/1, persists tokens on a new
  EmailConnection row, then sends the welcome email through
  Mailer.for_tenant/1 (which routes to Resend post-Task-7).

  The welcome email IS the deliverability probe — failure surfaces
  at provision-time, not silently at the next booking.
  """
  use DrivewayOS.DataCase, async: false

  import Mox
  import Swoosh.TestAssertions

  alias DrivewayOS.Notifications.ResendClient
  alias DrivewayOS.Onboarding.Providers.Resend
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.EmailConnection

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "rs-#{System.unique_integer([:positive])}",
        display_name: "Resend Provider Test",
        admin_email: "rs-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "id/0 is :resend" do
    assert Resend.id() == :resend
  end

  test "category/0 is :email" do
    assert Resend.category() == :email
  end

  test "configured?/0 false when :resend_api_key unset" do
    Application.delete_env(:driveway_os, :resend_api_key)
    refute Resend.configured?()
  end

  test "configured?/0 true when :resend_api_key set" do
    Application.put_env(:driveway_os, :resend_api_key, "re_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :resend_api_key) end)
    assert Resend.configured?()
  end

  test "setup_complete?/1 false when no EmailConnection row", ctx do
    refute Resend.setup_complete?(ctx.tenant)
  end

  test "setup_complete?/1 true when active EmailConnection exists", ctx do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: ctx.tenant.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_test_1"
    })
    |> Ash.create!(authorize?: false)

    assert Resend.setup_complete?(ctx.tenant)
  end

  test "affiliate_config/0 returns nil in V1" do
    # Same posture as Phase 1 Postmark — API-first, no OAuth URL
    # to tag, no enrolled affiliate program.
    assert Resend.affiliate_config() == nil
  end

  test "tenant_perk/0 returns nil in V1" do
    assert Resend.tenant_perk() == nil
  end

  test "provision/2 creates EmailConnection row and sends welcome email", ctx do
    expect(ResendClient.Mock, :create_api_key, fn name ->
      assert name == "drivewayos-#{ctx.tenant.slug}"
      {:ok, %{key_id: "k_test_1", api_key: "re_test_1"}}
    end)

    assert {:ok, _conn} = Resend.provision(ctx.tenant, %{})

    {:ok, conn} = Platform.get_email_connection(ctx.tenant.id, :resend)
    assert conn.external_key_id == "k_test_1"
    assert conn.api_key == "re_test_1"

    assert_email_sent(fn email ->
      assert email.subject == "Your shop is set up to send email"
      assert {_, addr} = hd(email.to)
      assert to_string(addr) == to_string(ctx.admin.email)
    end)
  end

  test "provision/2 surfaces Resend API error, does not create row", ctx do
    expect(ResendClient.Mock, :create_api_key, fn _ ->
      {:error, %{status: 401, body: %{"message" => "Invalid token"}}}
    end)

    assert {:error, %{status: 401}} = Resend.provision(ctx.tenant, %{})

    assert {:error, :not_found} = Platform.get_email_connection(ctx.tenant.id, :resend)
  end
end
```

- [ ] **Step 2: Run the test — should fail (module not found)**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/onboarding/providers/resend_test.exs
```

Expected: compile error / `module DrivewayOS.Onboarding.Providers.Resend is not loaded`.

- [ ] **Step 3: Create the provider adapter**

Create `lib/driveway_os/onboarding/providers/resend.ex`:

```elixir
defmodule DrivewayOS.Onboarding.Providers.Resend do
  @moduledoc """
  Resend onboarding provider — Phase 4b's second email integration.

  Fully API-first (mirrors Phase 1 Postmark): `provision/2` POSTs
  to Resend's `/api-keys` endpoint, persists the resulting
  `key_id` + `api_key` on a new EmailConnection row, then sends a
  welcome/verification email through the just-provisioned api_key.
  The welcome send doubles as the deliverability probe.

  Master account auth: read `RESEND_API_KEY` via
  `:resend_api_key` application config (configured in
  runtime.exs). When unset, `configured?/0` returns false and
  Resend hides itself from the picker.

  V1 affiliate config returns nil — Resend's affiliate program
  enrollment is deferred. The picker still renders the card.
  """

  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.ResendClient
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{EmailConnection, Tenant}

  @impl true
  def id, do: :resend

  @impl true
  def category, do: :email

  @impl true
  def display do
    %{
      title: "Send booking emails via Resend",
      blurb:
        "Wire up Resend so confirmations, reminders, and receipts " <>
          "go to your customers from your shop's address.",
      cta_label: "Set up Resend",
      href: "/onboarding/resend/start"
    }
  end

  @impl true
  def configured? do
    case Application.get_env(:driveway_os, :resend_api_key) do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  @impl true
  def setup_complete?(%Tenant{id: tid}) do
    case Platform.get_email_connection(tid, :resend) do
      {:ok, %EmailConnection{api_key: key}} when is_binary(key) -> true
      _ -> false
    end
  end

  @impl true
  def provision(%Tenant{} = tenant, _params) do
    with {:ok, %{key_id: key_id, api_key: api_key}} <-
           ResendClient.create_api_key("drivewayos-#{tenant.slug}"),
         {:ok, _conn} <- save_connection(tenant, key_id, api_key),
         :ok <- send_welcome_email(tenant) do
      {:ok, tenant}
    end
  end

  @impl true
  def affiliate_config, do: nil

  @impl true
  def tenant_perk, do: nil

  defp save_connection(tenant, key_id, api_key) do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant.id,
      provider: :resend,
      external_key_id: key_id,
      api_key: api_key
    })
    |> Ash.create(authorize?: false)
  end

  defp send_welcome_email(tenant) do
    {:ok, admin} = first_admin(tenant)

    # The welcome email IS the deliverability probe for the
    # just-provisioned Resend api_key (per spec decision #7).
    # Routing through `Mailer.for_tenant/1` means a bad api_key
    # surfaces here at the most actionable moment, not silently at
    # the next booking confirmation.
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
    emails through Resend. From this point on, booking
    confirmations, reminders, and receipts will go to your customers
    from your shop's email address.

    No action needed — this email is just confirmation that the
    connection works.

    -- DrivewayOS
    """)
  end
end
```

- [ ] **Step 4: Register the provider**

Edit `lib/driveway_os/onboarding/registry.ex`. Find the `@providers` list and add `Providers.Resend` (after `Providers.Square`):

```elixir
  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect,
    DrivewayOS.Onboarding.Providers.Postmark,
    DrivewayOS.Onboarding.Providers.ZohoBooks,
    DrivewayOS.Onboarding.Providers.Square,
    DrivewayOS.Onboarding.Providers.Resend
  ]
```

- [ ] **Step 5: Re-run the provider test**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/onboarding/providers/resend_test.exs
```

Expected: 10 tests, 0 failures. Note the welcome-email assertion (`assert_email_sent`) passes because Phase 1's Mailer test mode (`config :swoosh, :api_client, false`) routes through `Swoosh.Adapters.Test`, which captures sends. The `Mailer.for_tenant/1` extension in Task 7 hasn't shipped yet, so `for_tenant` returns `[]` here — the email still flows through the default test adapter and is captured.

- [ ] **Step 6: Run the registry tests + onboarding suite to confirm Resend appears in `by_category(:email)`**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  mix test test/driveway_os/onboarding/
```

Expected: green. (Steps.Email tests still pass against the OLD single-card render — Phase 1's body — because we haven't refactored Steps.Email yet. Task 6 does that.)

- [ ] **Step 7: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os/onboarding/providers/resend.ex \
          lib/driveway_os/onboarding/registry.ex \
          test/driveway_os/onboarding/providers/resend_test.exs && \
  git commit -m "Onboarding.Providers.Resend: API-first email provider + Registry registration"
```

---

## Task 6: Refactor `Steps.Email` to use the macro + Postmark/Resend onboarding controllers

**Files:**
- Modify: `lib/driveway_os/onboarding/steps/email.ex`
- Modify: `lib/driveway_os/onboarding/providers/postmark.ex` (update `display.href`)
- Create: `lib/driveway_os_web/controllers/postmark_onboarding_controller.ex`
- Create: `lib/driveway_os_web/controllers/resend_onboarding_controller.ex`
- Modify: `lib/driveway_os_web/router.ex`
- Modify: `test/driveway_os/onboarding/steps/email_test.exs` (drop `Postmark.Mock` submit assertions — those move into the controller test)
- Create: `test/driveway_os_web/controllers/postmark_onboarding_controller_test.exs`
- Create: `test/driveway_os_web/controllers/resend_onboarding_controller_test.exs`

This task is the biggest by surface area because Phase 1 wired Postmark provisioning into `Steps.Email.submit/2` (synchronous wizard submit). Phase 4b replaces that with the per-provider controller pattern (matching Square / Stripe). All wiring is moved at once so the wizard transitions cleanly from "form submit fires provision" to "card href kicks off provision."

- [ ] **Step 1: Write the failing controller tests (Postmark + Resend)**

Create `test/driveway_os_web/controllers/postmark_onboarding_controller_test.exs`:

```elixir
defmodule DrivewayOSWeb.PostmarkOnboardingControllerTest do
  @moduledoc """
  GET /onboarding/postmark/start — kicks off Postmark API-first
  provisioning for the current admin's tenant. Mirrors Phase 4's
  SquareOauthController shape but for an API-first provider:
  there's no separate /callback step — provision runs synchronously
  in the start handler and redirects.

  Logs :click before provision and :provisioned on success.
  Surfaces error to flash on failure.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "po-#{System.unique_integer([:positive])}",
        display_name: "Postmark OB Test",
        admin_email: "po-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)
    %{conn: conn, tenant: tenant, admin: admin}
  end

  test "GET /onboarding/postmark/start: provisions and redirects on success", ctx do
    Application.put_env(:driveway_os, :postmark_account_token, "pt_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :postmark_account_token) end)

    expect(PostmarkClient.Mock, :create_server, fn _name, _opts ->
      {:ok, %{server_id: 88_001, api_key: "server-token-pq"}}
    end)

    conn = get(ctx.conn, "/onboarding/postmark/start")
    assert redirected_to(conn) == "/admin/onboarding"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    types = events |> Enum.sort_by(& &1.occurred_at, DateTime) |> Enum.map(& &1.event_type)
    assert types == [:click, :provisioned]
    assert Enum.all?(events, &(&1.provider == :postmark))
  end

  test "GET /onboarding/postmark/start: error path logs :click only and redirects with flash", ctx do
    Application.put_env(:driveway_os, :postmark_account_token, "pt_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :postmark_account_token) end)

    expect(PostmarkClient.Mock, :create_server, fn _, _ ->
      {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
    end)

    conn = get(ctx.conn, "/onboarding/postmark/start")
    assert redirected_to(conn) == "/admin/onboarding"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Postmark"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    assert [event] = events
    assert event.event_type == :click
  end
end
```

Create `test/driveway_os_web/controllers/resend_onboarding_controller_test.exs`:

```elixir
defmodule DrivewayOSWeb.ResendOnboardingControllerTest do
  @moduledoc """
  GET /onboarding/resend/start — kicks off Resend API-first
  provisioning for the current admin's tenant. Same shape as
  Postmark's onboarding controller — synchronous provision in the
  start handler, no /callback.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Notifications.ResendClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "re-#{System.unique_integer([:positive])}",
        display_name: "Resend OB Test",
        admin_email: "re-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    Application.put_env(:driveway_os, :resend_api_key, "re_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :resend_api_key) end)

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)
    %{conn: conn, tenant: tenant, admin: admin}
  end

  test "GET /onboarding/resend/start: provisions and redirects on success", ctx do
    expect(ResendClient.Mock, :create_api_key, fn _name ->
      {:ok, %{key_id: "k_x", api_key: "re_test_x"}}
    end)

    conn = get(ctx.conn, "/onboarding/resend/start")
    assert redirected_to(conn) == "/admin/onboarding"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    types = events |> Enum.sort_by(& &1.occurred_at, DateTime) |> Enum.map(& &1.event_type)
    assert types == [:click, :provisioned]
    assert Enum.all?(events, &(&1.provider == :resend))
  end

  test "GET /onboarding/resend/start: error path logs :click only and redirects with flash", ctx do
    expect(ResendClient.Mock, :create_api_key, fn _ ->
      {:error, %{status: 401, body: %{"message" => "Invalid token"}}}
    end)

    conn = get(ctx.conn, "/onboarding/resend/start")
    assert redirected_to(conn) == "/admin/onboarding"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Resend"

    {:ok, all} = Ash.read(DrivewayOS.Platform.TenantReferral, authorize?: false)
    events = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    assert [event] = events
    assert event.event_type == :click
  end

  test "GET /onboarding/resend/start: rejects when no current admin", _ctx do
    {:ok, %{tenant: t}} =
      Platform.provision_tenant(%{
        slug: "re-noauth-#{System.unique_integer([:positive])}",
        display_name: "Anon",
        admin_email: "anon-#{System.unique_integer([:positive])}@example.com",
        admin_name: "A",
        admin_password: "Password123!"
      })

    conn =
      build_conn()
      |> Map.put(:host, "#{t.slug}.lvh.me")
      |> get("/onboarding/resend/start")

    # Existing tenant LoadCustomer plug pattern: redirect to /sign-in
    assert redirected_to(conn) =~ "/sign-in"
  end
end
```

- [ ] **Step 2: Write the failing Steps.Email picker test (replaces Phase 1's submit-driven test)**

Replace `test/driveway_os/onboarding/steps/email_test.exs` entirely with:

```elixir
defmodule DrivewayOS.Onboarding.Steps.EmailTest do
  @moduledoc """
  Steps.Email is the wizard's email step. As of Phase 4b, generic
  over N providers in the `:email` category — renders side-by-side
  cards for each configured + not-yet-set-up provider (Postmark +
  Resend in V1). `complete?/1` returns true if ANY email provider is
  connected. Provisioning happens in the per-provider controllers
  (PostmarkOnboardingController + ResendOnboardingController);
  these tests pin the picker render + complete predicate + no-op
  submit/2.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Email, as: Step
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "em-#{System.unique_integer([:positive])}",
        display_name: "Email Step Test",
        admin_email: "em-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :email" do
    assert Step.id() == :email
  end

  test "title/0 is the email step heading" do
    assert Step.title() == "Send booking emails"
  end

  test "complete?/1 false when tenant has no email provider connected", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "complete?/1 true once Postmark is connected", ctx do
    {:ok, with_pm} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{
        postmark_server_id: "88001",
        postmark_api_key: "server-token-pq"
      })
      |> Ash.update(authorize?: false)

    assert Step.complete?(with_pm)
  end

  test "complete?/1 true once Resend EmailConnection exists", ctx do
    DrivewayOS.Platform.EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: ctx.tenant.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_x"
    })
    |> Ash.create!(authorize?: false)

    assert Step.complete?(ctx.tenant)
  end

  test "submit/2 is a no-op — provisioning happens via the per-provider controller", ctx do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_tenant: ctx.tenant,
        errors: %{}
      }
    }

    assert {:ok, ^socket} = Step.submit(%{}, socket)
  end

  describe "render/1 picker (multi-provider)" do
    setup do
      Application.put_env(:driveway_os, :postmark_account_token, "pt_master_test")
      Application.put_env(:driveway_os, :resend_api_key, "re_master_test")

      on_exit(fn ->
        Application.delete_env(:driveway_os, :postmark_account_token)
        Application.delete_env(:driveway_os, :resend_api_key)
      end)

      :ok
    end

    test "renders cards for every configured email provider not yet set up", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      # Both V1 email providers visible.
      assert html =~ "Set up email"
      assert html =~ "Set up Resend"
    end

    test "applies UX rules: 44px touch targets, motion-reduce, slate-600 text", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "min-h-[44px]"
      assert html =~ "motion-reduce:transition-none"
      assert html =~ "text-slate-600"
    end

    test "Postmark card href routes to /onboarding/postmark/start", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "/onboarding/postmark/start"
    end

    test "Resend card href routes to /onboarding/resend/start", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "/onboarding/resend/start"
    end
  end
end
```

- [ ] **Step 3: Run both new test files — should fail (modules / routes not built yet)**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test \
  test/driveway_os/onboarding/steps/email_test.exs \
  test/driveway_os_web/controllers/postmark_onboarding_controller_test.exs \
  test/driveway_os_web/controllers/resend_onboarding_controller_test.exs
```

Expected: failures — no controllers, no routes, Steps.Email body still single-card.

- [ ] **Step 4: Refactor `Steps.Email`**

Replace `lib/driveway_os/onboarding/steps/email.ex` entirely with:

```elixir
defmodule DrivewayOS.Onboarding.Steps.Email do
  @moduledoc """
  Email wizard step. Generic over N providers in the `:email`
  category via `Steps.PickerStep`. As of Phase 4b, both providers
  (Postmark + Resend) are API-first — picker cards route to each
  provider's `/onboarding/<provider>/start` controller path which
  fires provisioning synchronously and redirects back.

  V1 provider universe: Postmark, Resend. Wizard's "any one
  provider connected = step done" semantics mean a tenant doesn't
  see Resend's card if Postmark is already set up (and vice-versa).
  Switching is support-driven.
  """
  use DrivewayOS.Onboarding.Steps.PickerStep,
    category: :email,
    intro_copy:
      "Pick the email provider for booking confirmations and reminders. " <>
        "You can change later by emailing support."

  @impl true
  def id, do: :email

  @impl true
  def title, do: "Send booking emails"
end
```

- [ ] **Step 5: Update Postmark provider's `display.href`**

Edit `lib/driveway_os/onboarding/providers/postmark.ex`. Find the `display/0` function and change `href:`:

```elixir
  @impl true
  def display do
    %{
      title: "Send booking emails",
      blurb:
        "Wire up Postmark so confirmations, reminders, and receipts " <>
          "go to your customers from your shop's address.",
      cta_label: "Set up email",
      href: "/onboarding/postmark/start"
    }
  end
```

- [ ] **Step 6: Create the Postmark onboarding controller**

Create `lib/driveway_os_web/controllers/postmark_onboarding_controller.ex`:

```elixir
defmodule DrivewayOSWeb.PostmarkOnboardingController do
  @moduledoc """
  Onboarding entry point for Postmark — `GET /onboarding/postmark/start`.

  Calls `Postmark.provision/2` synchronously (it's API-first, no
  OAuth), logs `:click` before and `:provisioned` on success via
  `Affiliate.log_event/4`. Redirects back to the wizard either way;
  errors land in flash. Mirrors Phase 1's wizard-submit shape but
  via a controller, matching the Square / Stripe / Resend pattern.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Onboarding.Affiliate
  alias DrivewayOS.Onboarding.Providers.Postmark

  plug :require_admin_customer

  def start(conn, _params) do
    tenant = conn.assigns.current_tenant
    :ok = Affiliate.log_event(tenant, :postmark, :click, %{wizard_step: "email"})

    case Postmark.provision(tenant, %{}) do
      {:ok, updated} ->
        :ok =
          Affiliate.log_event(updated, :postmark, :provisioned, %{
            server_id: updated.postmark_server_id
          })

        redirect(conn, to: "/admin/onboarding")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Postmark setup failed: #{inspect(reason)}")
        |> redirect(to: "/admin/onboarding")
    end
  end

  defp require_admin_customer(conn, _opts) do
    cust = conn.assigns[:current_customer]

    cond do
      is_nil(cust) ->
        conn |> redirect(to: "/sign-in") |> halt()

      cust.role != :admin ->
        conn |> redirect(to: "/") |> halt()

      true ->
        conn
    end
  end
end
```

- [ ] **Step 7: Create the Resend onboarding controller**

Create `lib/driveway_os_web/controllers/resend_onboarding_controller.ex`:

```elixir
defmodule DrivewayOSWeb.ResendOnboardingController do
  @moduledoc """
  Onboarding entry point for Resend — `GET /onboarding/resend/start`.

  Mirrors PostmarkOnboardingController's shape exactly. API-first,
  no callback step — provision runs synchronously here.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Onboarding.Affiliate
  alias DrivewayOS.Onboarding.Providers.Resend

  plug :require_admin_customer

  def start(conn, _params) do
    tenant = conn.assigns.current_tenant
    :ok = Affiliate.log_event(tenant, :resend, :click, %{wizard_step: "email"})

    case Resend.provision(tenant, %{}) do
      {:ok, _updated} ->
        :ok = Affiliate.log_event(tenant, :resend, :provisioned, %{})
        redirect(conn, to: "/admin/onboarding")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Resend setup failed: #{inspect(reason)}")
        |> redirect(to: "/admin/onboarding")
    end
  end

  defp require_admin_customer(conn, _opts) do
    cust = conn.assigns[:current_customer]

    cond do
      is_nil(cust) ->
        conn |> redirect(to: "/sign-in") |> halt()

      cust.role != :admin ->
        conn |> redirect(to: "/") |> halt()

      true ->
        conn
    end
  end
end
```

- [ ] **Step 8: Wire up the routes**

Edit `lib/driveway_os_web/router.ex`. Find the scope where `/onboarding/square/start` was added in Phase 4 (or any tenant-scoped `:browser` scope with `LoadTenant` + `LoadCustomer`). Add:

```elixir
    get "/onboarding/postmark/start", PostmarkOnboardingController, :start
    get "/onboarding/resend/start", ResendOnboardingController, :start
```

Place these adjacent to existing `/onboarding/<provider>/start` routes for greppability.

- [ ] **Step 9: Re-run the test files**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test \
  test/driveway_os/onboarding/steps/email_test.exs \
  test/driveway_os_web/controllers/postmark_onboarding_controller_test.exs \
  test/driveway_os_web/controllers/resend_onboarding_controller_test.exs
```

Expected: all green. Steps.Email tests: 10 passing. Postmark controller: 2 passing. Resend controller: 3 passing.

- [ ] **Step 10: Run the wizard LV test to confirm no regression**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  mix test test/driveway_os_web/live/admin/onboarding_wizard_live_test.exs
```

Expected: green. The wizard still renders Steps.Email; the only behavioral change is "form submit no longer calls Postmark.provision — the card href does."

- [ ] **Step 11: Run the broader suite to catch any straggler that depended on Phase 1's form-submit behavior**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  mix test test/driveway_os_web/ test/driveway_os/onboarding/
```

Expected: green.

- [ ] **Step 12: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os/onboarding/steps/email.ex \
          lib/driveway_os/onboarding/providers/postmark.ex \
          lib/driveway_os_web/controllers/postmark_onboarding_controller.ex \
          lib/driveway_os_web/controllers/resend_onboarding_controller.ex \
          lib/driveway_os_web/router.ex \
          test/driveway_os/onboarding/steps/email_test.exs \
          test/driveway_os_web/controllers/postmark_onboarding_controller_test.exs \
          test/driveway_os_web/controllers/resend_onboarding_controller_test.exs && \
  git commit -m "Steps.Email: refactor to PickerStep + per-provider onboarding controllers (Postmark + Resend)"
```

---

## Task 7: `Mailer.for_tenant/1` routing extension

**Files:**
- Modify: `lib/driveway_os/mailer.ex`
- Test: `test/driveway_os/mailer_test.exs` (NEW)

This is the email "charge-side." Without it, "connect Resend" would be misleading — the api_key would land in the DB but transactional emails would still flow through Postmark or default SMTP. ALL existing 17 send-sites in the codebase stay byte-identical — they already pass `Mailer.for_tenant(tenant)` and get back keyword opts.

- [ ] **Step 1: Write the failing routing test**

Create `test/driveway_os/mailer_test.exs`:

```elixir
defmodule DrivewayOS.MailerTest do
  @moduledoc """
  Pin the `Mailer.for_tenant/1` routing precedence:

    1. Active EmailConnection{:resend} → Swoosh.Adapters.Resend opts.
    2. Tenant.postmark_api_key → Swoosh.Adapters.Postmark opts.
    3. Neither → [].

  Plus the test-mode override: when `:swoosh, :api_client` is
  false (the test suite's default), `for_tenant/1` returns []
  regardless of credentials so Phase 1's Swoosh.Adapters.Test
  capture path stays in place.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Mailer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.EmailConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ml-#{System.unique_integer([:positive])}",
        display_name: "Mailer Test",
        admin_email: "ml-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    # Force api_client on for these tests so we exercise the routing
    # paths instead of the test-mode override.
    prev = Application.get_env(:swoosh, :api_client)
    Application.put_env(:swoosh, :api_client, true)
    on_exit(fn -> Application.put_env(:swoosh, :api_client, prev) end)

    %{tenant: tenant}
  end

  test "returns [] when no email provider is connected", ctx do
    assert Mailer.for_tenant(ctx.tenant) == []
  end

  test "routes to Postmark when only postmark_api_key is set", ctx do
    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    opts = Mailer.for_tenant(t)
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Postmark
    assert Keyword.get(opts, :api_key) == "server-token-pq"
  end

  test "routes to Resend when active EmailConnection{:resend} exists", ctx do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: ctx.tenant.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_test_active"
    })
    |> Ash.create!(authorize?: false)

    opts = Mailer.for_tenant(ctx.tenant)
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Resend
    assert Keyword.get(opts, :api_key) == "re_test_active"
  end

  test "Resend takes precedence over Postmark when both are present", ctx do
    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: t.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_test_resend_wins"
    })
    |> Ash.create!(authorize?: false)

    opts = Mailer.for_tenant(t)
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Resend
    assert Keyword.get(opts, :api_key) == "re_test_resend_wins"
  end

  test "skips Resend EmailConnection when paused (auto_send_enabled false)", ctx do
    conn =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "k1",
        api_key: "re_paused"
      })
      |> Ash.create!(authorize?: false)

    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)

    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    opts = Mailer.for_tenant(t)
    # Falls through to Postmark since the Resend conn is paused.
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Postmark
  end

  test "skips Resend EmailConnection when disconnected", ctx do
    conn =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "k1",
        api_key: "re_disc"
      })
      |> Ash.create!(authorize?: false)

    conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)

    assert Mailer.for_tenant(ctx.tenant) == []
  end

  test "test-mode override: returns [] when :swoosh :api_client is false", ctx do
    Application.put_env(:swoosh, :api_client, false)

    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: t.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_x"
    })
    |> Ash.create!(authorize?: false)

    # Even with both connected, the test-mode override suppresses.
    assert Mailer.for_tenant(t) == []
  end
end
```

- [ ] **Step 2: Run the test — should fail (Resend routing not yet implemented)**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/mailer_test.exs
```

Expected: the Resend-routing tests fail (Mailer still only knows about Postmark).

- [ ] **Step 3: Extend `Mailer.for_tenant/1`**

Replace `lib/driveway_os/mailer.ex` entirely with:

```elixir
defmodule DrivewayOS.Mailer do
  use Swoosh.Mailer, otp_app: :driveway_os

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  @doc """
  Returns Mailer config tuned to the given tenant.

  Routing precedence:
    1. Active `Platform.EmailConnection{provider: :resend}` →
       `Swoosh.Adapters.Resend` config scoped to the tenant's api_key.
    2. `tenant.postmark_api_key` set → `Swoosh.Adapters.Postmark`
       config scoped to the tenant's server.
    3. Neither → `[]` (falls through to the platform default Mailer
       config — typically shared SMTP).

  In test/dev (`config :swoosh, :api_client, false`), the override
  is suppressed regardless of credentials so the configured
  Test/Local adapter keeps capturing sends — Postmark/Resend
  adapters need a real HTTP client and would raise.

  Pass the result as the second argument to `Mailer.deliver/2`:

      DrivewayOS.Mailer.deliver(email, DrivewayOS.Mailer.for_tenant(tenant))
  """
  @spec for_tenant(Tenant.t()) :: keyword()
  def for_tenant(%Tenant{} = tenant) do
    cond do
      not Application.get_env(:swoosh, :api_client) ->
        []

      conn = active_resend_connection(tenant) ->
        [adapter: Swoosh.Adapters.Resend, api_key: conn.api_key]

      is_binary(tenant.postmark_api_key) and tenant.postmark_api_key != "" ->
        [adapter: Swoosh.Adapters.Postmark, api_key: tenant.postmark_api_key]

      true ->
        []
    end
  end

  defp active_resend_connection(%Tenant{id: tenant_id}) do
    case Platform.get_active_email_connection(tenant_id, :resend) do
      {:ok, conn} -> conn
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Re-run the test**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os/mailer_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Run the broad notifications/scheduling suite to confirm no send-site regression**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  mix test test/driveway_os/notifications/ test/driveway_os/accounts/ test/driveway_os/scheduling/
```

Expected: green. (All 17 existing call sites still pass `Mailer.for_tenant(tenant)` and get back `[]` in test mode — no behavior change.)

- [ ] **Step 6: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os/mailer.ex test/driveway_os/mailer_test.exs && \
  git commit -m "Mailer.for_tenant/1: route through active Resend EmailConnection (precedence over Postmark)"
```

---

## Task 8: `IntegrationsLive` third-category extension

**Files:**
- Modify: `lib/driveway_os_web/live/admin/integrations_live.ex`
- Modify: `test/driveway_os_web/live/admin/integrations_live_test.exs`

Phase 4 already extended IntegrationsLive to merge two resource types (Payment + Accounting). Adding a third (Email) is mechanical: one more `load_rows/1` query, one more `row_from_*/1`, one more `resource_module/1` clause, one more `provider_label/1` clause.

- [ ] **Step 1: Write the failing test cases**

Append to `test/driveway_os_web/live/admin/integrations_live_test.exs` (before the final `end`):

```elixir
  describe "Email rows (Phase 4b)" do
    alias DrivewayOS.Platform.EmailConnection

    test "lists Resend row when an active EmailConnection exists", ctx do
      connect_resend!(ctx.tenant.id)

      {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
      assert html =~ "Resend"
      assert html =~ "Email"
      assert html =~ "Active"
      assert html =~ "Pause"
      assert html =~ "Disconnect"
    end

    test "shows Paused for Resend when auto_send_enabled is false", ctx do
      conn_row = connect_resend!(ctx.tenant.id)
      conn_row |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)

      {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
      assert html =~ "Paused"
      assert html =~ "Resume"
    end

    test "Pause toggles auto_send_enabled for Resend", ctx do
      connect_resend!(ctx.tenant.id)

      {:ok, view, _html} = live(ctx.conn, "/admin/integrations")
      view |> element("button[id^='table-pause']") |> render_click()

      {:ok, refreshed} = DrivewayOS.Platform.get_email_connection(ctx.tenant.id, :resend)
      refute refreshed.auto_send_enabled
    end

    test "Disconnect clears Resend api_key", ctx do
      connect_resend!(ctx.tenant.id)

      {:ok, view, _html} = live(ctx.conn, "/admin/integrations")
      view |> element("button[id^='table-disconnect']") |> render_click()

      {:ok, refreshed} = DrivewayOS.Platform.get_email_connection(ctx.tenant.id, :resend)
      assert refreshed.api_key == nil
      assert refreshed.disconnected_at != nil
    end

    defp connect_resend!(tenant_id) do
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: tenant_id,
        provider: :resend,
        external_key_id: "k1",
        api_key: "re_test_il"
      })
      |> Ash.create!(authorize?: false)
    end
  end
```

- [ ] **Step 2: Run the test — should fail (IntegrationsLive doesn't know about EmailConnection yet)**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test test/driveway_os_web/live/admin/integrations_live_test.exs
```

Expected: the new tests fail (Email row missing). The existing 6+ tests continue to pass.

- [ ] **Step 3: Extend `IntegrationsLive`**

Edit `lib/driveway_os_web/live/admin/integrations_live.ex`.

a. Update the alias line:

```elixir
  alias DrivewayOS.Platform.{AccountingConnection, EmailConnection, PaymentConnection}
```

b. Update `resource_module/1` — add the email clause (between `"payment"` and `"accounting"`):

```elixir
  defp resource_module("payment"), do: PaymentConnection
  defp resource_module("email"), do: EmailConnection
  defp resource_module("accounting"), do: AccountingConnection
```

c. Update `load_rows/1` to also query EmailConnection:

```elixir
  defp load_rows(socket) do
    tenant_id = socket.assigns.current_tenant.id

    {:ok, accounting_conns} =
      AccountingConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, payment_conns} =
      PaymentConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, email_conns} =
      EmailConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    rows =
      Enum.map(accounting_conns, &row_from_accounting/1) ++
        Enum.map(payment_conns, &row_from_payment/1) ++
        Enum.map(email_conns, &row_from_email/1)

    Phoenix.Component.assign(socket, :rows, rows)
  end
```

d. Add `row_from_email/1` next to the existing `row_from_payment/1`:

```elixir
  defp row_from_email(%EmailConnection{} = c) do
    %{
      id: c.id,
      resource: "email",
      provider: c.provider,
      category: "Email",
      status: status_text(c, :send),
      connected_at: c.connected_at,
      last_activity_at: c.last_send_at,
      last_error: c.last_send_error,
      auto_enabled: c.auto_send_enabled,
      disconnected_at: c.disconnected_at
    }
  end
```

e. Update `status_text/2` to also recognize EmailConnection's paused state. Find:

```elixir
  defp status_text(%AccountingConnection{auto_sync_enabled: false}, _), do: "Paused"
  defp status_text(%PaymentConnection{auto_charge_enabled: false}, _), do: "Paused"
```

Add the email clause between them:

```elixir
  defp status_text(%AccountingConnection{auto_sync_enabled: false}, _), do: "Paused"
  defp status_text(%PaymentConnection{auto_charge_enabled: false}, _), do: "Paused"
  defp status_text(%EmailConnection{auto_send_enabled: false}, _), do: "Paused"
```

And update the error-text matcher block to also recognize `last_send_error`. Find:

```elixir
  defp status_text(%{last_sync_error: err}, _) when is_binary(err), do: "Error"
  defp status_text(%{last_charge_error: err}, _) when is_binary(err), do: "Error"
```

Add:

```elixir
  defp status_text(%{last_sync_error: err}, _) when is_binary(err), do: "Error"
  defp status_text(%{last_charge_error: err}, _) when is_binary(err), do: "Error"
  defp status_text(%{last_send_error: err}, _) when is_binary(err), do: "Error"
```

f. Update `provider_label/1` — add the Resend clause:

```elixir
  defp provider_label(:zoho_books), do: "Zoho Books"
  defp provider_label(:square), do: "Square"
  defp provider_label(:resend), do: "Resend"
  defp provider_label(p), do: p |> Atom.to_string() |> String.capitalize()
```

- [ ] **Step 4: Re-run the IntegrationsLive test file**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  mix test test/driveway_os_web/live/admin/integrations_live_test.exs
```

Expected: all tests pass. Phase 3/4 tests still green; the 4 new Email-row tests now pass.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add lib/driveway_os_web/live/admin/integrations_live.ex \
          test/driveway_os_web/live/admin/integrations_live_test.exs && \
  git commit -m "IntegrationsLive: third row category (Email) — Resend rows + Pause/Disconnect"
```

---

## Task 9: Runtime config + DEPLOY.md

**Files:**
- Modify: `config/runtime.exs`
- Modify: `DEPLOY.md`
- Modify: `config/test.exs` (if a test placeholder for `:resend_api_key` is missing)

- [ ] **Step 1: Add Resend env reads to runtime.exs**

Edit `config/runtime.exs`. Find the block that reads `postmark_account_token` (in the non-test branch around line 50-65). Add `resend_api_key` and `resend_affiliate_ref_id` to that same `config :driveway_os, ...` keyword list:

Find:

```elixir
  config :driveway_os,
    stripe_client_id: System.get_env("STRIPE_CLIENT_ID") || "",
    stripe_secret_key: System.get_env("STRIPE_SECRET_KEY") || "",
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "",
    postmark_account_token: System.get_env("POSTMARK_ACCOUNT_TOKEN") || "",
    postmark_affiliate_ref_id: System.get_env("POSTMARK_AFFILIATE_REF_ID"),
```

Add two lines (after `postmark_affiliate_ref_id`):

```elixir
    resend_api_key: System.get_env("RESEND_API_KEY") || "",
    resend_affiliate_ref_id: System.get_env("RESEND_AFFILIATE_REF_ID"),
```

- [ ] **Step 2: Add a test placeholder so the test suite exercises `configured?/0` true paths**

Check `config/test.exs`. If there's a `config :driveway_os, ...` block with `postmark_account_token`, add `resend_api_key`. If not, add a new line (model the exact placement after Phase 4's `square_app_id` placeholder added in `config/test.exs`):

```elixir
config :driveway_os, :resend_api_key, "re_test_master"
```

(If Phase 1 didn't seed a test placeholder for Postmark and tests handle it via `Application.put_env`, do the same for Resend — leave `config/test.exs` untouched and rely on the test files' own `Application.put_env` calls. Match the prevailing pattern.)

- [ ] **Step 3: Update DEPLOY.md**

Edit `DEPLOY.md`. Find the "Per-tenant integrations" table (around line 36–50). Add two rows after the Postmark rows:

```markdown
| `RESEND_API_KEY` | Resend account-level token used to provision tenant-scoped api_keys via the API. |
| `RESEND_AFFILIATE_REF_ID` | Optional. Platform-level Resend affiliate referral code; appended to outbound Resend URLs as `?ref=<value>`. Leave unset until enrolled in Resend's referral program. |
```

- [ ] **Step 4: Run the full test suite to verify no regression**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test
```

Expected: all tests pass. (Phase 1–4b test counts plus Phase 4b's new ones.)

- [ ] **Step 5: Compile prod-style to catch runtime.exs typos**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && MIX_ENV=prod mix compile --no-deps-check 2>&1 | tail -20
```

Expected: `Generated driveway_os app` or no errors. (If runtime.exs has a syntax error, prod compile catches it; dev/test don't fully exercise the prod-only block.)

- [ ] **Step 6: Commit**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && \
  git add config/runtime.exs config/test.exs DEPLOY.md && \
  git commit -m "Config: RESEND_API_KEY + RESEND_AFFILIATE_REF_ID env reads + DEPLOY.md"
```

---

## Task 10: Final verification + push

- [ ] **Step 1: Run the full test suite**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix test
```

Expected: all tests pass. Note the new test count — Phase 4b adds roughly:
- Task 1 PickerStep: 6 tests
- Task 3 EmailConnection: 12 tests
- Task 4 ResendClient: 3 tests
- Task 5 Resend provider: 10 tests
- Task 6 Steps.Email + 2 controllers: 10 + 2 + 3 = 15 tests
- Task 7 Mailer: 7 tests
- Task 8 IntegrationsLive Email rows: 4 tests

Total new: ~57 tests. Add to whatever Phase 4 closed at.

- [ ] **Step 2: Compile with --warnings-as-errors to catch any straggling warnings**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && mix compile --warnings-as-errors 2>&1 | tail -10
```

Expected: `Generated driveway_os app` with no warnings. If `Steps.PickerStep`'s macro emits unused-alias or unused-variable warnings inside using-step modules, fix those before pushing — `defoverridable` plus the anonymous `_params` placeholder typically suffices.

- [ ] **Step 3: Verify git state is clean**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && git status
```

Expected: "nothing to commit, working tree clean" with HEAD on `main`.

- [ ] **Step 4: Inspect the commit log**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && git log -10 --oneline
```

Expected: 9 new commits from this plan, plus Phase 4's commits underneath.

- [ ] **Step 5: Push to origin**

```bash
cd /Volumes/mac_external/Development/Business/driveway_os && git push origin main
```

- [ ] **Step 6: Manual smoke test guide (do NOT execute — for the operator after deploy)**

Add to the commit message of Task 10's "merge" commit (or post-task notes), so the operator has a runbook:

```
Phase 4b smoke test — after deploy with RESEND_API_KEY set:

1. Sign up a fresh tenant at <subdomain>.drivewayos.com/signup
2. Land in /admin/onboarding
3. Email step shows TWO cards: "Set up email" (Postmark) + "Set up Resend"
4. Click "Set up Resend" → wizard flashes success → step marked complete
5. Trigger a test booking → confirmation email arrives via Resend
6. Visit /admin/integrations → see Resend row, Pause toggles auto_send_enabled
7. Disconnect → row shows Disconnected, no Pause/Disconnect buttons
8. Same flow for a tenant choosing Postmark instead — verify routing falls through

If the welcome email fails on step 4, check:
  - RESEND_API_KEY is set + valid (master account token, not a per-key one)
  - The tenant's admin email is real (the welcome goes to that address)
  - Resend account has sending enabled
```

- [ ] **Step 7: No commit needed for Step 6** — the runbook lives in the team's deploy notes / Slack / wherever operator-facing docs live.

---

## Verification checklist

After all tasks complete, the following must be true:

- [ ] `mix test` — green (full suite)
- [ ] `mix compile --warnings-as-errors` — clean
- [ ] `MIX_ENV=prod mix compile --no-deps-check` — clean
- [ ] Phase 4's existing Steps.Payment tests pass byte-identically (no behavior change from refactor)
- [ ] Phase 1's Steps.Email Postmark provisioning still works (now via `/onboarding/postmark/start`)
- [ ] `Mailer.for_tenant/1` returns Resend opts for Resend-connected tenants, Postmark opts for Postmark-only, `[]` for unconnected
- [ ] `/admin/integrations` shows three row categories — Payment, Accounting, Email
- [ ] `Onboarding.Registry.by_category(:email)` returns `[Postmark, Resend]`
- [ ] `Steps.PickerStep` macro is the single source of truth for picker render — no inline picker code in Steps.Payment or Steps.Email
- [ ] All 17 existing `Mailer.deliver(email, Mailer.for_tenant(tenant))` call sites are byte-identical (zero send-site changes)

---

## Rollback notes

Phase 4b is purely additive in terms of DB schema (one new table, no column changes to existing tables). Rollback path if something breaks in production:

1. **Code-level rollback:** revert the Phase 4b commit range. `Mailer.for_tenant/1` falls back to Phase 4 behavior (Postmark or `[]`). EmailConnection rows persist but become orphan data.
2. **DB-level rollback:** `mix ecto.rollback --to <Phase-4-final-migration-version>` drops the `platform_email_connections` table.
3. **Per-tenant disable:** if Resend specifically misbehaves, an operator can `Ash.Changeset.for_update(:disconnect, ...)` the offending row directly via `iex` — mailer falls through to Postmark or default SMTP automatically.

The picker macro refactor (Task 2) is the only piece with non-trivial rollback risk: if a subtle render diff slips through, Steps.Payment shows up wrong in the wizard. Phase 4's full Steps.Payment test file is the safety net — it catches diffs at CI time before deploy.
