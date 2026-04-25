# DrivewayOS — Project Instructions for Claude

## What this is

Multi-tenant SaaS platform for mobile detailing operators. Each
tenant runs a branded "shop" on shared infrastructure: their own
booking flow, customers, schedule, payments (via their own Stripe
Connect account), and admin dashboard.

The first reference customer is **Driveway Detail Co** (currently
running on the standalone `MobileCarWash` repo at
`drivewaydetailcosa.com`). DrivewayOS is the green-field rewrite
that will eventually onboard them as "tenant zero" once it hits
feature parity.

Sibling repo with reference patterns: `../MobileCarWash/`. The
codebase there (945+ tests, working in production) is the source
of truth for *what* a single shop needs. Use it for guidance, but
don't copy without thinking — DrivewayOS is multi-tenant from day
one, which changes most things.

## Stack

- Elixir 1.18 / Erlang 27 / Phoenix 1.8 / LiveView 1.1
- Ash 3 + AshPostgres + AshAuthentication + AshAuthenticationPhoenix
- PostgreSQL 16
- Tailwind v4 (no `tailwind.config.js`) + DaisyUI
- Oban for background jobs
- Stripe Connect Standard for payments
- Bandit + Swoosh + Req

## Working discipline

### TDD/BDD first — non-negotiable
Every feature, every bugfix: failing test first, then implementation.
- Unit tests in `test/driveway_os/` (Ash resources, contexts, pure logic)
- Web tests in `test/driveway_os_web/` (controllers, plugs, LV)
- Browser-level tests via Wallaby once we have routes worth driving
- Show the red → green cycle clearly in commit history

### Multi-tenancy is the default
Every Ash resource is tenant-scoped (`multitenancy do strategy
:attribute; attribute :tenant_id end`) unless it lives in
`DrivewayOS.Platform` — that domain is the few resources that anchor
tenancy itself. There is **no single-tenant codepath**. Every test
sets a tenant; every Ash query passes `tenant:`.

### No hardcoded brand strings
The reference repo had ~60 hits of "Driveway Detail Co" hardcoded.
DrivewayOS never does this. Every customer-visible string that
mentions the operator's name comes from the `Tenant` record
(`tenant.display_name`, `tenant.support_email`, etc.). A
`grep -r "DrivewayOS"` in `lib/` should only return the platform-
level pages (the marketing site at `drivewayos.com` and the
`admin.drivewayos.com` dashboard) — never tenant-facing surfaces.

### No hardcoded test dates
Tests using future-validated date fields (`scheduled_at`,
`current_period_end`, etc.) compute them dynamically from
`DateTime.utc_now()` offsets. Hardcoded `~U[2026-...-01]` literals
are time bombs that explode silently weeks later.

### Lean iterative
Solo-operator velocity. Ship the smallest thing that proves the
slice works, then iterate. No speculative abstractions, no
"frameworks" before there are two real callers, no defensive code
for problems that haven't happened.

## Structure

- `lib/driveway_os/platform/` — `Tenant`, `PlatformUser`,
  `PlatformToken`, `TenantSubscription`. Never tenant-scoped.
- `lib/driveway_os/accounts/` — `Customer`, `CustomerNote`, `Token`.
  Tenant-scoped.
- `lib/driveway_os/scheduling/` — `Appointment`, `AppointmentBlock`,
  `BlockTemplate`, `ServiceType`. Tenant-scoped.
- `lib/driveway_os/billing/` — `Payment`, `Subscription`,
  `SubscriptionPlan`. Tenant-scoped. Stripe Connect ID lives on
  `Tenant`.
- `lib/driveway_os/fleet/` — `Vehicle`, `Address`. Tenant-scoped.
- `lib/driveway_os_web/plugs/load_tenant.ex` — subdomain →
  `current_tenant`. The keystone of the whole system.

## V1 scope
See `docs/V1_SCOPE.md` for the cut. Anything not in that doc is V2+
and shouldn't ship until V1 is shipping for ≥1 paying tenant.

## Subdomain dev setup

- Local: `*.lvh.me` resolves to 127.0.0.1 in public DNS, no
  `/etc/hosts` edits needed.
- `acme.lvh.me:4000` → tenant "acme"
- `lvh.me:4000` → marketing site
- `admin.lvh.me:4000` → platform admin

## Useful commands

- `mix precommit` — compile (warnings as errors), unused-deps prune,
  format, full test suite
- `mix test test/path/to/file.exs:LINE` — single test
- `mix test --failed` — re-run last failures
- `mix ecto.reset` — drop+recreate+seed dev DB
- `mix ash_postgres.generate_migrations --name <slug>` — diff
  resources against DB and emit a migration
- `mix run priv/repo/seeds.exs` — seed canonical data

## Reference

- `../MobileCarWash/AGENTS.md` — Phoenix 1.8 + Elixir/Ash usage
  rules. Same rules apply here.
- `../MobileCarWash/lib/mobile_car_wash/` — production-tested patterns
  (Ash resources, policies, plugs, LV). Use as a reference, not a
  copy source.
- `~/.claude/plans/no-but-let-s-go-mighty-shamir.md` — the original
  multi-tenancy migration plan (we pivoted to green-field; the plan's
  architecture decisions still apply).
