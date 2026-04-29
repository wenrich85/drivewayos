# Tenant onboarding roadmap

**Status:** Approved roadmap. Phase 0 + Phase 1 to be brainstormed and planned next.
**Date:** 2026-04-28
**Owner:** Wendell Richards
**Scope:** High-level sequencing only. Each phase becomes its own brainstorm + implementation plan.

## Why this exists

Tenant onboarding is the moment a new shop decides whether DrivewayOS is something they'll actually use. The current `/signup` form creates a tenant + admin row and dumps them on the admin dashboard with a five-item checklist. That works but it's a checklist, not a flow — there's no guided path through "configure payment, configure email, set hours, brand the page" and no recovery if the tenant bails halfway.

This roadmap covers the deliberate transformation of that experience into a guided wizard backed by a pluggable provider abstraction, so adding new integrations (Square, Zoho, Postmark, etc.) is a small repeatable slice instead of a bespoke project each time.

## Constraints + decisions (locked)

These were settled in the brainstorming session that produced this doc:

| # | Decision | Rationale |
|---|---|---|
| 1 | **Wizard runs after signup**, at `/admin/onboarding`. Signup itself stays short. | If a tenant abandons mid-wizard, we still have a row to email recovery prompts to. |
| 2 | **Mandatory-first sequencing.** Payment + email are required for V1; everything else is iterative. | The product literally doesn't function without these two; everything else is enhancement. |
| 3 | **Conservative V1 provider list:** Stripe Connect (payment) + Postmark (email) only. Accounting deferred. | Every provider is permanent maintenance + UX surface; ship the abstraction first, multiply later. |
| 4 | **Affiliate model:** invisible backend revshare floor + visible tenant-side perk where the provider offers one. | Never leave money on the table; conversion-lift the wizard step where there's a real perk to surface. |
| 5 | **API-first when feasible, hosted-redirect when KYC-required.** Postmark = API. Stripe Connect = hosted (legal requirement). | Minimize friction without bypassing compliance. |
| 6 | **Hybrid wizard interaction:** linear-required for mandatory steps with skip-for-later, free-pick board for optional steps. | Force completion of load-bearing steps; let optional ones land at the tenant's pace. |

## Architecture

### The three layers

**1. Wizard framework** (new — `/admin/onboarding`)

A multi-step LiveView owned by the tenant subdomain. Responsibilities:

- Step ordering (linear-required for mandatory steps, picker board for optional)
- "Skip for now" tracking — skipped steps surface on the existing `/admin` dashboard checklist instead of disappearing
- Progress persistence on the `Tenant` row so a tenant who closes the tab and comes back resumes where they left off
- Resume URL emailed to the admin if they bail mid-wizard

Each step is a small LV component implementing a uniform interface:
```
@callback render(assigns :: map()) :: rendered()
@callback submit(params :: map(), socket :: Socket.t()) :: {:ok, Socket.t()} | {:error, reason}
@callback complete?(tenant :: Tenant.t()) :: boolean()
```

**2. Provider abstraction** (new — `DrivewayOS.Onboarding.Provider` behaviour)

Any concrete integration implements:

```
@callback category() :: :payment | :email | :accounting | atom()
@callback display() :: %{label: String.t(), logo: String.t(), description: String.t(),
                         tenant_perk: String.t() | nil}
@callback provision(tenant :: Tenant.t(), params :: map()) ::
            {:ok, credentials :: map()} | {:error, :hosted_required | term()}
@callback hosted_url(tenant :: Tenant.t(), opts :: keyword()) :: String.t()
```

The wizard step for category X (e.g. `:email`) renders all providers for that category as picker cards. On submit it calls the chosen provider's `provision/2` first; if it returns `{:error, :hosted_required}`, the wizard transitions to a "we'll redirect you to {{provider}} to finish setup" state and uses `hosted_url/2`.

**3. Cross-cutting concerns** (new helper modules — not their own roadmap phases)

- `DrivewayOS.Onboarding.Affiliate.tag_url/2` — appends our referral ID to any URL
- `DrivewayOS.Onboarding.Affiliate.tenant_perk/1` — returns visible-to-tenant copy when one exists
- `DrivewayOS.Onboarding.ApiHelpers` — common HTTP / retry / error-mapping primitives that API-first providers share

These are dependencies of every Provider implementation, not roadmap items themselves.

### Why this shape matters

**Adding a new provider is one new module + tests, not a new wizard slice.**

Once Phase 0 ships, "support Square" or "support QuickBooks" or "support Mailgun" each become focused work items that conform to a known shape, instead of bespoke designs that drift in style and quality.

## Phased delivery sequence

| # | Phase | What ships | Tenant-visible outcome |
|---|---|---|---|
| 0 | Wizard framework + provider abstraction | The skeleton: framework, `Provider` behaviour, helpers, Stripe Connect refactored into the new shape with no behavior change. | Identical to today, but the bones are correct for everything below. |
| 1 | Mandatory wizard + Postmark provider | Wizard at `/admin/onboarding`. Linear-required: **Branding → Services → Schedule → Payment (Stripe) → Email (Postmark)**. The Postmark provider is implemented in this phase as the first API-first integration (full API-driven Server creation; no key paste). Each step has a "skip for now" link that surfaces it on the dashboard checklist. | New tenant gets walked through a coherent setup; can't accidentally launch with no payment or no email. Postmark "just works" — tenant pastes nothing. |
| 2 | Affiliate tracking baseline | Backend revshare ID appended to every provider link / API call. Visible perk copy on Postmark + Stripe Connect cards where the program offers one. | Invisible to tenant; we start logging referrals. |
| 3 | Accounting (V2 — first new category) | Zoho Books **or** QuickBooks Online (decided at the Phase 3 brainstorm). Hosted-redirect OAuth either way. Optional — lives on the post-wizard checklist board, not the linear flow. | Tenant who wants tax-time exports can wire one up in a click. |
| 4 | Second provider per category (V2) | Square (payment) + SendGrid (email). Wizard's picker step now has a real choice. | Tenant can pick the processor they already use. |
| 5 | Long tail (V3+) | Mailgun, SES, Wave, Xero, PayPal — each added as customer demand justifies. | Backlog item; no committed timeline. |

**Phases 0 and 1 together are the load-bearing slice.** Everything after them is a focused addition rather than a refactor.

## Provider capability matrix (target end-state of Phase 5)

| Provider | Category | Auto-provision via API? | Affiliate program? | Tenant-side perk? |
|---|---|---|---|---|
| Stripe Connect | Payment | No (KYC required) — hosted | Platform fee per charge | None directly |
| Square | Payment | Partial — hosted for KYC | Flat referral | Possible coupon |
| Postmark | Email | **Yes (full API)** | % of MRR | Free tier extended |
| SendGrid | Email | Partial | Flat referral | Free tier |
| Zoho Books | Accounting | No — hosted OAuth | % of MRR | Discount code |
| QuickBooks Online | Accounting | No — hosted OAuth | Flat referral | Sometimes |

## Explicitly out of scope

- **Multiple providers per category, same tenant** (e.g. Stripe + Square simultaneously). Possible later but adds material complexity; one-of for now.
- **In-app KYC.** Not legally feasible for Stripe / Square — we always redirect for compliance. Don't pretend otherwise.
- **Custom tenant-supplied provider plug-ins.** Closed list of providers; new ones land via DrivewayOS code change.
- **Subscription billing on the platform itself** (how DrivewayOS bills its tenants). Separate concern, separate spec.

## Decisions deferred to per-phase brainstorms

These need their own focused brainstorm when their phase is up — committing to them in this roadmap would be premature:

- Exact wizard step order in Phase 1 — locked at Branding → Services → Schedule → Payment → Email at the roadmap level, but the per-step UX/copy is its own design.
- Postmark vs Resend in Phase 1. Roadmap assumes Postmark; revisit at Phase 1 brainstorm. Resend's API is arguably simpler and the affiliate program may be richer; either fits the abstraction so the choice can move late.
- Zoho vs QuickBooks first in Phase 3. One of them, not both at the same time.
- Affiliate-tracking storage schema in Phase 2 — `tenant_referrals` table? Stamped on the Tenant row? UTM-style query-param logging only? Decided in Phase 2 brainstorm.
- Wizard resume mechanics (URL token? Session-only? Email-link?) — Phase 0 brainstorm.

## What "done" looks like

After Phase 1 ships:

1. A new tenant signs up at `/signup`.
2. They land on `/admin/onboarding` automatically.
3. The wizard walks them through Branding → Services → Schedule → Payment (Stripe redirect) → Email (Postmark API).
4. Each step has a "skip for now" escape hatch that surfaces it on the dashboard checklist.
5. On completion, they land on `/admin` with everything wired up — branded, with a service menu, hours published, payment processor connected, transactional email working.
6. From the operator's perspective, **they did not paste a single API key or copy a single credential.** Postmark provisioned via API; Stripe Connect via hosted KYC.

After Phase 4 ships, the same flow but the Payment + Email steps offer a real picker between two providers each.

## Next step

Brainstorm + plan **Phase 0** (wizard framework + provider abstraction). That brainstorm decides things like:
- Do steps live as separate LiveView routes (`/admin/onboarding/payment`) or as `wizard_step` assign in a single LV?
- How does progress persist on the Tenant row?
- What does "skip for now" mean concretely — a `skipped_steps :map` attribute? Per-step `:done | :skipped | :pending` enum?
- How does the existing Stripe Connect refactor into the new behaviour without breaking the working OAuth flow we just shipped?

Phase 0 is small (1–2 weeks of focused work) and unblocks everything below.
