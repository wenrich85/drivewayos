# Phase 2 design: Affiliate tracking baseline

**Status:** Approved design. Plan next.
**Date:** 2026-05-02
**Owner:** Wendell Richards
**Scope:** Phase 2 of the tenant-onboarding roadmap — affiliate-tracking
abstraction (events table, provider callbacks, helper module) and
visible perk copy on wizard cards. V1 providers (Stripe Connect +
Postmark) ship as no-op clients on the abstraction; the real payoff
arrives in Phase 4 when Square + SendGrid land with genuine
referral-link relationships.

## Why this exists

Phase 1 shipped the wizard + Postmark integration. The roadmap's
Phase 2 line item is *"backend revshare ID appended to every provider
link / API call. Visible perk copy on Postmark + Stripe Connect cards
where the program offers one."*

Two awkward facts about our V1 providers:

1. **Stripe Connect's revenue model isn't a referral link** — we take
   `application_fee_amount` per charge, which Phase 1 already wires up.
   There's nothing to tag.
2. **Postmark is API-first** — tenants never visit Postmark's signup
   page, they consume Servers under our account. Postmark's *"% of
   MRR"* program rewards new-customer referrals, which our flow doesn't
   produce.

So for V1, "affiliate tagging" is a no-op. But the work is still
worth doing now: the abstraction we ship in Phase 2 is what Phase 4
(Square + SendGrid) and Phase 3 (Zoho or QuickBooks) plug into. Doing
it now also gives us a working `tenant_referrals` events table from
day one, so `:click` and `:provisioned` events on Stripe + Postmark
start collecting funnel signal even though no revenue is attributed
yet — useful when we go to optimize wizard conversion in V2.

## Constraints + decisions (locked)

These were settled in the brainstorming session that produced this
doc.

| # | Decision | Rationale |
|---|---|---|
| 1 | **Build the full infrastructure now**, V1 providers as no-op clients on the abstraction. | Phase 2's value is the abstraction; Phase 4 needs it ready. Building speculatively is acceptable when the surface is small (~ 1 module + 1 resource + 2 callbacks). |
| 2 | **Storage = `Platform.TenantReferral` events table.** Not Tenant-row stamps, not UTM-only logging. | Schema stable as providers grow (rows, not columns). Captures funnel history (click without provisioning) for free. Cost over Tenant-row is one table + one migration. |
| 3 | **Config home = Mix config + behaviour shim.** Affiliate IDs read from env-vars via `Application.get_env`; provider modules expose them through new `affiliate_config/0` callback. Perk copy stays hardcoded on the provider module via `tenant_perk/0` callback. | Affiliate IDs are credentials in disguise — per-env, rotatable, must not leak between staging and prod. Perk copy is static marketing text and doesn't need env indirection. |
| 4 | **Click tracking = log at existing server touchpoints, no redirect proxy.** | Both V1 providers already have a server-side step (Stripe controller, Postmark form submit) where logging is trivial. A `/o/<provider>` proxy controller would have zero V1 callers; Phase 4's first hosted-signup provider builds it then with full context. |
| 5 | **`TenantReferral` is platform-tier**, not tenant-scoped (no `multitenancy` block). `tenant_id` is a plain FK column. | This is *our* business data about the tenant, not the tenant's own data. Tenant admins shouldn't see our affiliate IDs in metadata. Same shape as `Platform.Tenant` itself — anchor of the platform tier. |
| 6 | **Three event types**: `:click`, `:provisioned`, `:revenue_attributed`. Schema-ready for `:revenue_attributed`; no code path writes it in Phase 2. `:perk_displayed` and `:abandoned` are not modeled. | Three is enough for a complete funnel ("clicked the card → finished setup → paid out"). `:perk_displayed` is too high-volume for marginal value; `:abandoned` is derivable from `:click` without `:provisioned` follow-up. |
| 7 | **`log_event/4` swallows errors and always returns `:ok`.** | Revenue attribution is our metric, not the tenant's flow. Missing one event is acceptable; breaking a tenant booking flow on a logger error is not. |
| 8 | **`tag_url/2` is a passthrough when `ref_id` is nil.** Both V1 providers have nil ref_id; their wizard cards render unchanged. | Quiet failure mode for V1 — surfacing "no affiliate configured" warnings would be noise during normal operation. |

## Architecture

### Module layout

**New modules:**

| Path | Responsibility |
|---|---|
| `lib/driveway_os/platform/tenant_referral.ex` | Ash resource. Platform-tier (no multitenancy). Records `:click`, `:provisioned`, `:revenue_attributed` events with `tenant_id` FK and provider-specific `metadata` map. |
| `lib/driveway_os/onboarding/affiliate.ex` | Three public functions: `tag_url/2`, `perk_copy/1`, `log_event/4`. Reads provider configs via the new behaviour callbacks; writes events via the resource. |
| `priv/repo/migrations/<ts>_create_tenant_referrals.exs` | Creates the `tenant_referrals` table + indexes. |

**Modified modules:**

| Path | Change |
|---|---|
| `lib/driveway_os/onboarding/provider.ex` | Add two `@optional_callbacks`: `affiliate_config/0`, `tenant_perk/0`. |
| `lib/driveway_os/onboarding/providers/postmark.ex` | Implement both new callbacks. `affiliate_config/0` reads `:postmark_affiliate_ref_id` from app env (nil in V1, set when we enroll). `tenant_perk/0` returns `nil` until we have a perk to advertise. |
| `lib/driveway_os/onboarding/providers/stripe_connect.ex` | Implement both new callbacks returning `nil` for both — Stripe's revenue model is platform fee, not referral link. |
| `lib/driveway_os/onboarding/steps/email.ex` | Inside `submit/2`, call `Affiliate.log_event(tenant, :postmark, :click, ...)` before `Postmark.provision/2`. On success result, `Affiliate.log_event(tenant, :postmark, :provisioned, ...)`. |
| `lib/driveway_os/onboarding/steps/payment.ex` | `render/1` renders `Affiliate.perk_copy(:stripe_connect)` below the blurb if non-nil. **Does not** call `Affiliate.tag_url/2` on `display.href` — that URL (`/onboarding/stripe/start`) is internal; tagging is only meaningful for outbound provider URLs (Phase 4). |
| `lib/driveway_os/onboarding/steps/email.ex` (render side) | `render/1` renders `Affiliate.perk_copy(:postmark)` below the blurb if non-nil. Same reasoning as Payment — `display.href` is internal. |
| `lib/driveway_os_web/controllers/stripe_onboarding_controller.ex` | In `start/2`, call `Affiliate.log_event(tenant, :stripe_connect, :click, %{...})` before redirecting to Stripe's OAuth URL. In the callback success path, call `Affiliate.log_event(..., :provisioned, ...)`. |
| `lib/driveway_os/platform.ex` | Register `TenantReferral` in the domain. |
| `config/runtime.exs` | Read `POSTMARK_AFFILIATE_REF_ID` env var into `:driveway_os, :postmark_affiliate_ref_id`. (No env var for Stripe — there's no referral ID to set.) |
| `config/test.exs` | Placeholder `config :driveway_os, :postmark_affiliate_ref_id, nil` so tests run with passthrough behavior. |
| `DEPLOY.md` | Add `POSTMARK_AFFILIATE_REF_ID` row to per-tenant integrations table (label as platform-level, since it's our affiliate ID, not the tenant's). |

### Data model

```elixir
defmodule DrivewayOS.Platform.TenantReferral do
  use Ash.Resource, otp_app: :driveway_os, domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tenant_referrals"
    repo DrivewayOS.Repo
    references do
      reference :tenant_id, on_delete: :delete
    end
    custom_indexes do
      index [:tenant_id, :provider]
      index [:provider, :event_type, :occurred_at]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :provider, :atom, allow_nil?: false, public?: true
    attribute :event_type, :atom, allow_nil?: false, public?: true,
      constraints: [one_of: [:click, :provisioned, :revenue_attributed]]
    attribute :metadata, :map, default: %{}, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
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

No identities (multiple `:click` events per tenant+provider are valid).
No `belongs_to :tenant` association declared in V1 — the platform side
doesn't need it for read paths and adding it pulls Ash relationship
machinery we don't use yet. Plain FK column suffices.

### Provider behaviour additions

```elixir
defmodule DrivewayOS.Onboarding.Provider do
  # ... existing six callbacks ...

  @doc """
  Returns the provider's affiliate config or nil if none.

  Shape: `%{ref_param: <query-param-name>, ref_id: <ref-value>}`.
  When `ref_id` is nil (env var unset) or this callback returns nil,
  `Affiliate.tag_url/2` is a passthrough.
  """
  @callback affiliate_config() ::
              %{ref_param: String.t(), ref_id: String.t() | nil} | nil

  @doc """
  Visible-to-tenant perk copy, or nil if no perk is offered. Rendered
  below the wizard card's blurb when non-nil.
  """
  @callback tenant_perk() :: String.t() | nil

  @optional_callbacks affiliate_config: 0, tenant_perk: 0
end
```

Provider impls return `nil` for either callback when not applicable.
Stripe Connect returns `nil` for both. Postmark returns
`%{ref_param: "ref", ref_id: Application.get_env(:driveway_os, :postmark_affiliate_ref_id)}`
for `affiliate_config/0` and `nil` for `tenant_perk/0` until we have
a perk.

### `Affiliate` module API

```elixir
defmodule DrivewayOS.Onboarding.Affiliate do
  alias DrivewayOS.Onboarding.Registry
  alias DrivewayOS.Platform.TenantReferral

  @spec tag_url(String.t(), atom()) :: String.t()
  def tag_url(url, provider_id) do
    case Registry.fetch(provider_id) do
      {:ok, mod} ->
        if function_exported?(mod, :affiliate_config, 0) do
          case mod.affiliate_config() do
            %{ref_param: param, ref_id: id} when is_binary(id) and id != "" ->
              append_query_param(url, param, id)
            _ ->
              url
          end
        else
          url
        end
      :error ->
        url
    end
  end

  @spec perk_copy(atom()) :: String.t() | nil
  def perk_copy(provider_id) do
    case Registry.fetch(provider_id) do
      {:ok, mod} ->
        if function_exported?(mod, :tenant_perk, 0), do: mod.tenant_perk(), else: nil
      :error ->
        nil
    end
  end

  @spec log_event(Tenant.t(), atom(), atom(), map()) :: :ok
  def log_event(%Tenant{id: tid}, provider_id, event_type, metadata \\ %{}) do
    TenantReferral
    |> Ash.Changeset.for_create(:log, %{
      tenant_id: tid,
      provider: provider_id,
      event_type: event_type,
      metadata: metadata
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Affiliate.log_event failed: #{inspect(reason)}")
        :ok
    end
  end
end
```

`Registry.fetch/1` is a small addition to the existing
`Onboarding.Registry` module — given a provider id atom, returns the
module or `:error`. (Phase 1 has the list; this just exposes a lookup.)

### Mix config layout

`config/runtime.exs` (next to existing Stripe/Postmark blocks):
```elixir
if config_env() != :test do
  config :driveway_os,
    postmark_affiliate_ref_id: System.get_env("POSTMARK_AFFILIATE_REF_ID")
end
```

`config/test.exs`:
```elixir
config :driveway_os, :postmark_affiliate_ref_id, nil
```

`DEPLOY.md` per-tenant integrations table gets one new row:
```markdown
| `POSTMARK_AFFILIATE_REF_ID` | Optional. Platform-level Postmark affiliate referral code; appended to outbound Postmark URLs as `?ref=<value>`. Leave unset until enrolled in Postmark's referral program. |
```

### Wizard rendering changes

Concrete UI delta in Phase 2 — minimal:

- **Steps.Payment**: blurb section gains a perk paragraph
  ```heex
  <p class="text-sm text-base-content/70">{@display.blurb}</p>
  <%= if perk = Affiliate.perk_copy(:stripe_connect) do %>
    <p class="text-xs text-success font-medium">{perk}</p>
  <% end %>
  <a href={@display.href} ...>
  ```
  `display.href` stays raw — it's an internal route. V1 result:
  identical render to today (perk nil).

- **Steps.Email**: same pattern. V1 result: identical render to today.

`tag_url/2` has no V1 call sites; it lives in the abstraction and is
unit-tested directly. First production caller will be Phase 4's
SendGrid step when its `display.href` points at an external signup
URL on sendgrid.com.

The visual change ships when perk copy lands — Phase 2's infra is in
place to flip it on without touching templates again.

## What "done" looks like

After Phase 2 ships:

1. `tenant_referrals` table exists. `Platform.TenantReferral` resource
   reads/creates against it.
2. `Affiliate.tag_url/2`, `Affiliate.perk_copy/1`, `Affiliate.log_event/4`
   are public, documented, tested.
3. Stripe Connect's `start` controller logs `:click`; its callback
   logs `:provisioned`.
4. Postmark's `Steps.Email.submit/2` logs `:click` before provisioning,
   `:provisioned` after success.
5. Setting `POSTMARK_AFFILIATE_REF_ID=foo` in the env makes
   `Postmark.affiliate_config/0` return a populated map; verifiable
   directly by unit test against `Affiliate.tag_url/2`. No V1
   wizard-card URL is outbound, so no visual change — but the
   plumbing is exercised end-to-end.
6. Updating `Postmark.tenant_perk/0` to return a non-nil string
   causes the wizard's Email card to render the perk paragraph.
   Reverting it to `nil` restores the current render.
7. From a platform-admin SQL session: `SELECT provider, event_type,
   COUNT(*) FROM tenant_referrals GROUP BY 1, 2;` returns funnel data
   across all tenants.

After Phase 4 (Square + SendGrid land), the same code paths attribute
real revenue without touching `Affiliate` or `TenantReferral` again —
the new providers just implement `affiliate_config/0` returning their
ref_id and the rest works.

## Out of scope

- **Redirect proxy controller** (`/o/<provider>?dest=...`). Decision #4.
  Built when Phase 4's first hosted-signup provider needs it.
- **Platform-admin dashboard for referrals.** Phase 2 ships the data,
  not the dashboard. Querying via `mix repl` is sufficient until volume
  justifies the UI work.
- **Webhook handlers for `:revenue_attributed` events.** Schema is
  ready; no code path writes these in Phase 2. Lands when we enroll in
  a program that pays out — likely Phase 4.
- **Affiliate-tag URL signing / tamper-proofing.** A tenant or
  attacker can in principle hit our `/onboarding/stripe/start` route
  multiple times to inflate `:click` counts. Acceptable: the metric is
  internal funnel signal, not a payout-driving counter. Real payout
  events come from provider webhooks (Phase 4) which are signed.
- **Per-tenant ref_id overrides.** Affiliate IDs are platform-level
  for V1 — every tenant's clicks attribute to the same
  DrivewayOS-level code. Per-tenant attribution (e.g. white-labeling
  for a partner who resells DrivewayOS) is a Phase 5+ concern.
- **`:perk_displayed` and `:abandoned` event types.** Decision #6. Add
  later if we need them for analytics.
- **Encryption of `metadata` JSON.** Same posture as Phase 1's
  `postmark_api_key` plaintext storage — encryption is a Phase 2
  hardening pass we'll do across all sensitive columns at once.

## Decisions deferred to plan-writing

- **Test layout for `Affiliate` module.** Probably `test/driveway_os/onboarding/affiliate_test.exs` with separate describe blocks per public function — match the per-Step file pattern from Phase 1. Plan confirms.
- **Whether `Onboarding.Registry.fetch/1` is a brand new function or whether the existing `@providers` list already exposes a lookup.** Plan reads the current Registry first.
- **Exact wording of the platform-admin warning** when `Affiliate.log_event/4` fails. `Logger.warning/1` shape, but the message string is plan-level detail.
- **Whether `metadata` map is freeform or has a typed schema per event_type.** V1 ships freeform with an example contract documented in moduledoc. If we discover query patterns that need indexed metadata fields, that's a Phase 2.5 follow-up.

## Next step

Implementation plan for Phase 2 — task-by-task breakdown of:
1. Migration + `Platform.TenantReferral` resource
2. `Onboarding.Registry.fetch/1` (small addition)
3. `Provider` behaviour adds `affiliate_config/0` + `tenant_perk/0`
4. `Onboarding.Affiliate` module + tests
5. `Postmark` + `StripeConnect` providers implement the new callbacks
6. Steps.Email + Steps.Payment wire up `tag_url` + `perk_copy` + `log_event`
7. `StripeOnboardingController` wires up `log_event`
8. Runtime config + DEPLOY.md
9. Final verification + push

Each task has its own tests and lands behind `mix test` green. The
plan follows the same TDD shape Phase 1 used.
