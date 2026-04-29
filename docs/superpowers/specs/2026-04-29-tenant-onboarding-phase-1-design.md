# Tenant Onboarding Phase 1 — Mandatory Wizard + Postmark

**Status:** Approved design. Ready for implementation plan.
**Date:** 2026-04-29
**Owner:** Wendell Richards
**Roadmap:** `docs/superpowers/specs/2026-04-28-tenant-onboarding-roadmap.md` (Phase 1 row)
**Phase 0:** `docs/superpowers/specs/2026-04-28-tenant-onboarding-roadmap.md` + plan at `docs/superpowers/plans/2026-04-28-tenant-onboarding-phase-0.md` (shipped)

## Why this exists

Phase 0 landed the bones of the onboarding system: a `Provider` behaviour, a `Registry`, a stub LV at `/admin/onboarding`, and Stripe Connect refactored into the new shape. Behaviour was unchanged versus pre-Phase-0.

Phase 1 makes the wizard actually do something. A new tenant signs up and is walked through the five mandatory steps required to launch a working detailing shop: brand the page, set up services, set hours, take payment, send email. The roadmap committed to this list and to "linear-required with skip-for-later" interaction; this spec decides the architecture, the per-step UX, and the Postmark-as-V1 email integration that lands here as the first API-first provider.

## Constraints + decisions (locked in brainstorm)

| # | Decision | Rationale |
|---|---|---|
| 1 | **FSM-as-pure-functions, not a library.** `DrivewayOS.Onboarding.Wizard` module with `current_step/1`, `complete?/1`, `skip/2`, `unskip/2` — no `:gen_statem`, no Ash state machine extension, no `machinery` dep. | Five linear steps with no branching logic. A library FSM is ceremony for a 30-line module. |
| 2 | **Persistence: jsonb `wizard_progress :map` on Tenant.** Map only stores `:skipped` flags. | Tiniest schema change that solves both "remember where I was" and "honor a skip." |
| 3 | **`:done` is computed, never persisted.** Each step's `complete?(tenant)` predicate derives done-ness from real state (logo present, Stripe connected, etc.). | Single source of truth — no version of "the map says done but you have no logo." Matches Phase 0's `Provider.setup_complete?/1` shape. |
| 4 | **Signup → `/admin/onboarding` directly.** Was `/admin`. | Cleanest URL semantics — no implicit "redirect when pending steps exist" logic in `DashboardLive.mount`. |
| 5 | **V1 email provider: Postmark.** Not Resend (long tail). | Postmark's 10% lifetime MRR affiliate aligns platform incentives. Resend can land in Phase 5 as the free-tier alternative. |
| 6 | **Branding "done" = `support_email` set.** Logo, color, phone are optional polish. | Support email is the only field that breaks things if missing (no reply-to in confirmations). Logo is photoshop friction we don't want to gate progress on. |
| 7 | **Postmark provisioning verified by test-send.** Provision API call → store credentials → send a welcome email through the new server → only then mark step done. | Two birds: catches credential failures at the most surfaceable moment, plus a friendly onboarding touchpoint. |
| 8 | **Wizard does NOT lock the tenant in.** Direct navigation to `/admin` mid-wizard works; the dashboard checklist surfaces leftover steps the same as today. The wizard is the guided path, not the only path. | Skip-for-later already establishes that mandatory steps can be deferred. The lock-in pattern adds nothing. |

## Architecture

### Module layout

**New modules:**

| Path | Responsibility |
|---|---|
| `lib/driveway_os/onboarding/wizard.ex` | Pure-function FSM. `steps/0`, `current_step/1`, `complete?/1`, `skip/2`, `unskip/2`. No state, no GenServer. |
| `lib/driveway_os/onboarding/step.ex` | Behaviour. `id/0`, `title/0`, `complete?/1`, `render/1`, `submit/2`. |
| `lib/driveway_os/onboarding/steps/branding.ex` | Branding step impl. |
| `lib/driveway_os/onboarding/steps/services.ex` | Services step impl. |
| `lib/driveway_os/onboarding/steps/schedule.ex` | Schedule step impl. |
| `lib/driveway_os/onboarding/steps/payment.ex` | Payment step impl — delegates to `Providers.StripeConnect`. |
| `lib/driveway_os/onboarding/steps/email.ex` | Email step impl — delegates to `Providers.Postmark`. |
| `lib/driveway_os/onboarding/providers/postmark.ex` | Postmark provider implementing `Onboarding.Provider`. Adds `provision/2` callback (extension to the Phase 0 behaviour). |
| `lib/driveway_os/notifications/postmark_client.ex` | HTTP wrapper over `api.postmarkapp.com`. Encapsulates token + endpoint URLs. Mockable via behaviour for tests. |
| `priv/repo/migrations/<ts>_add_wizard_progress_and_postmark_to_tenants.exs` | One migration: adds `wizard_progress :map`, `postmark_server_id :string`, `postmark_api_key :string` to `tenants`. |

**Modified modules:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform/tenant.ex` | New attributes (above) + `:set_wizard_progress` action. |
| `lib/driveway_os/onboarding/provider.ex` | Add `provision/2` callback (was deferred from Phase 0). Stripe-Connect impl returns `{:error, :hosted_required}` since Stripe is hosted-redirect-only. |
| `lib/driveway_os/onboarding/providers/stripe_connect.ex` | Implement new `provision/2` callback returning `{:error, :hosted_required}`. |
| `lib/driveway_os_web/live/admin/onboarding_wizard_live.ex` | Replace Phase 0 stub body with the actual wizard. |
| `lib/driveway_os_web/live/signup_live.ex` | Change post-signup redirect target to `/admin/onboarding`. |
| `lib/driveway_os_web/live/admin/dashboard_live.ex` | Replace `missing_branding?/1` and `using_default_services?/1` with calls to the corresponding `Step.complete?/1` so wizard + dashboard share one source of truth. |
| `lib/driveway_os/mailer.ex` (or wherever the booking confirmation Mailer config lives) | Read tenant-specific Postmark credentials when sending in a tenant context. Falls back to existing shared SMTP config for tenants without Postmark provisioned. |

### Data model

```elixir
# Tenant additions:
attribute :wizard_progress, :map, default: %{}

# Postmark integration:
attribute :postmark_server_id, :string         # external id, safe to expose
attribute :postmark_api_key, :string           # secret — encrypted at rest TBD
```

`wizard_progress` shape on disk (jsonb):
```json
{ "branding": "skipped", "services": "skipped" }
```
Only `"skipped"` is ever written. Steps not in the map are `:pending`. `:done` is never stored.

A new `:set_wizard_progress` action on `Tenant`:
```elixir
update :set_wizard_progress do
  argument :step, :atom, allow_nil?: false
  argument :status, :atom, allow_nil?: false   # :skipped | :pending only

  validate {Onboarding.Validators.WizardStatus, []}
  change {Onboarding.Changes.MergeWizardProgress, []}
end
```

### `Step` behaviour

```elixir
defmodule DrivewayOS.Onboarding.Step do
  @callback id() :: atom()
  @callback title() :: String.t()
  @callback complete?(Tenant.t()) :: boolean()
  @callback render(assigns :: map()) :: rendered()
  @callback submit(params :: map(), socket :: Socket.t())
              :: {:ok, Socket.t()} | {:error, term()}
end
```

Each `Steps.*` module is one file, ~50–150 lines depending on form complexity. They embed inline forms tuned for the wizard's "one focused thing per page" feel — they do NOT navigate the tenant out to the existing per-resource admin pages mid-wizard.

### `Wizard` FSM helpers

```elixir
defmodule DrivewayOS.Onboarding.Wizard do
  @steps [Steps.Branding, Steps.Services, Steps.Schedule, Steps.Payment, Steps.Email]

  def steps, do: @steps

  # First step that's not complete? AND not skipped. Returns nil if all done.
  def current_step(tenant), do: …

  def complete?(tenant), do: Enum.all?(@steps, &(&1.complete?(tenant) or skipped?(tenant, &1.id())))

  def skip(tenant, step), do: …  # writes :skipped to wizard_progress
  def unskip(tenant, step), do: …  # removes the step key from wizard_progress

  defp skipped?(tenant, step_id), do: Map.get(tenant.wizard_progress, to_string(step_id)) == "skipped"
end
```

All functions are pure-data — they read or transform the `Tenant` struct + `wizard_progress` map. No side effects, no GenServer, easy to test.

### LV flow at `/admin/onboarding`

1. `mount/3`: standard admin auth gate (no tenant → /, no customer → /sign-in, non-admin → /). If `Wizard.complete?(tenant)` → redirect to `/admin`. Else assign `:current_step` = `Wizard.current_step(tenant)`.
2. Render: header + step indicator (1/5, 2/5, …) + the current step's `render/1` output + Skip / Next buttons.
3. On Next submit: call current step's `submit/2`. On `{:ok, socket}` advance via `current_step/1` again. On `{:error, _}` stay on step + show error.
4. On Skip: call `Wizard.skip(tenant, step)` → advance.
5. When `Wizard.complete?/1` flips true → `push_navigate(socket, to: ~p"/admin")` with a flash welcome.

### Per-step decisions

| Step | `complete?(tenant)` | Form fields |
|---|---|---|
| **Branding** | `not is_nil(tenant.support_email)` | `support_email` (required), `logo` upload (optional), `primary_color_hex` (optional, default `#3b82f6`), `support_phone` (optional) |
| **Services** | `not Platform.using_default_services?(services)` | Inline list of the 2 seeded services (Basic Wash, Deep Clean) with rename / reprice / archive controls + "Add new service" inline form. |
| **Schedule** | `not Enum.empty?(blocks)` | Pick weekday (multi-select), start time, end time → creates one BlockTemplate per selected weekday. "Add another time block" inline button. |
| **Payment** | `Providers.StripeConnect.setup_complete?(tenant)` | Card with the Stripe Connect blurb + "Connect Stripe" button → `/onboarding/stripe/start` (existing OAuth flow). On callback success Stripe redirects back to `/admin/onboarding` (existing controller already redirects to `/admin`; updated to redirect to `/admin/onboarding` if the wizard is incomplete). |
| **Email** | `Providers.Postmark.setup_complete?(tenant)` | Card with Postmark blurb + "Set up email" button. On click: synchronously hit Postmark's `/servers` API, store credentials, send welcome email, advance. Surface API errors verbatim if any step fails. |

### Postmark provider

```elixir
defmodule DrivewayOS.Onboarding.Providers.Postmark do
  @behaviour DrivewayOS.Onboarding.Provider

  def id, do: :postmark
  def category, do: :email
  def display, do: %{
    title: "Send booking emails",
    blurb: "Wire up Postmark so confirmations, reminders, and receipts go to your customers.",
    cta_label: "Set up email",
    # Surfaces on the dashboard checklist when this step is skipped.
    # Routes back into the wizard, which is where the actual API
    # provisioning happens via the Email step's submit handler.
    href: "/admin/onboarding"
  }
  def configured?, do: not is_nil(System.get_env("POSTMARK_ACCOUNT_TOKEN"))
  def setup_complete?(%Tenant{postmark_server_id: id}), do: not is_nil(id)

  # New in Phase 1 — extension to the Phase 0 behaviour:
  def provision(tenant, _params) do
    with {:ok, server} <- PostmarkClient.create_server(name: "drivewayos-#{tenant.slug}"),
         {:ok, updated} <- save_credentials(tenant, server),
         :ok <- send_welcome_email(updated) do
      {:ok, updated}
    end
  end
end
```

The PostmarkClient wraps three endpoints we need: `POST /servers` (create), `DELETE /servers/{id}` (cleanup on rollback), and a thin send helper. It's mockable via a `@behaviour` so tests can avoid network IO.

`POSTMARK_ACCOUNT_TOKEN` is the platform-level Postmark account token (one for all of DrivewayOS). Lives in `runtime.exs` like the Stripe envvars; documented in `DEPLOY.md` as part of this spec's deliverable.

### Mailer integration

`DrivewayOS.Mailer` currently uses a shared SMTP config. After Phase 1, when sending a transactional email in a tenant context (booking confirmation, cancellation, reminder), the mailer reads the tenant's `postmark_api_key` and switches to Swoosh's Postmark adapter for that send. Tenants without Postmark provisioned (skipped the Email step) fall back to the shared SMTP config. This is a Phase 1 deliverable, gated on the Email step being complete for the tenant.

## What "done" looks like

After Phase 1 ships:

1. New tenant submits `/signup`.
2. Lands on `/admin/onboarding` (not `/admin`).
3. Walks through Branding (sets support email + optional logo) → Services (renames/repriciets the 2 seeded services) → Schedule (creates ≥1 block template) → Payment (Stripe Connect OAuth, redirects back) → Email (Postmark API provisioning + welcome email).
4. On the Email step, a real welcome email arrives in their inbox via the just-provisioned Postmark server.
5. Wizard redirects to `/admin` with a flash: "You're all set."
6. Booking confirmation emails for this tenant now route through their Postmark server.
7. Anyone who skipped a step still sees it on the dashboard checklist (existing behavior — the dashboard `missing_branding?` etc. now use the same predicates the wizard's `Step.complete?/1` uses).

## Out of scope

- **Affiliate-tagging on the Postmark provider link.** Phase 2.
- **Custom Postmark sending domain per tenant.** V1 uses our shared `mail.drivewayos.com`.
- **Resend or any second email provider.** Phase 5 long-tail.
- **Postmark API key encryption at rest.** Phase 1 lands plaintext on `Tenant.postmark_api_key`; encryption is a Phase 2 hardening task.
- **Modal-blocking enforcement.** Tenant CAN navigate to `/admin` mid-wizard; just won't be force-redirected back.
- **Wizard step un-skip via dashboard UI.** Skipped items show on the dashboard checklist; clicking the CTA takes the operator through the standard per-resource path. There's no explicit "un-skip" button.
- **Postmark domain DKIM/SPF setup.** We provision Servers under a centralized DrivewayOS sending domain that's pre-verified at the registrar level — tenants never see DNS records.
- **Onboarding emails to admins** (welcome to DrivewayOS itself, mid-wizard nudges, "you abandoned the wizard 3 days ago" reminders). Phase 1.5.

## Decisions deferred to plan-writing

- **Logo storage backend.** Existing `/admin/branding` LV's pattern if there is one; otherwise stub `priv/static` storage with a follow-up task to move to DigitalOcean Spaces. The plan reads the existing branding LV first and chooses based on what's there.
- **Postmark API key encryption.** Match existing tenant-secret patterns if `stripe_secret` etc. is encrypted; otherwise plaintext + Phase 2 follow-up.
- **Welcome-email subject + body copy.** Plan-level detail.
- **Stripe callback return-to logic.** Currently redirects to `/admin`. Phase 1 plan needs to make it redirect to `/admin/onboarding` when the wizard is incomplete.

## Next step

Implementation plan for Phase 1 — task-by-task breakdown of:
1. Migration + Tenant attribute additions
2. `Step` behaviour + `Wizard` FSM module
3. Five `Steps.*` modules (one task each)
4. `Postmark` provider + `PostmarkClient` + welcome email
5. `OnboardingWizardLive` rewrite (replaces Phase 0 stub)
6. `SignupLive` redirect change + Stripe callback redirect change
7. Dashboard checklist refactor to call `Step.complete?/1`
8. Mailer tenant-Postmark routing
9. Final verification + push

Each task is small, has its own tests, and lands behind `mix test`. The plan will follow the same TDD shape Phase 0 used.
