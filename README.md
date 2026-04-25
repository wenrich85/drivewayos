# DrivewayOS

Multi-tenant SaaS platform for mobile detailing operators. Each tenant
runs a branded shop on shared infrastructure: their own booking flow,
customers, schedule, payments (via Stripe Connect), and admin dashboard.

> Green-field rewrite of the patterns proven in
> [`MobileCarWash`](../MobileCarWash/), which is currently running in
> production for one operator (Driveway Detail Co). DrivewayOS is
> multi-tenant from day one.

## Stack

Elixir 1.18 · Phoenix 1.8 · LiveView · Ash 3 · AshPostgres ·
AshAuthentication · PostgreSQL 16 · Tailwind v4 + DaisyUI · Oban ·
Stripe Connect · Bandit

## Setup

```bash
# Install Elixir/Erlang via asdf if you don't have them
asdf install

# Fetch deps + create DB + run migrations + seed
mix setup

# Start the dev server
mix phx.server
```

Local subdomain routing uses `lvh.me` (resolves to 127.0.0.1):

- `lvh.me:4000` — marketing site
- `admin.lvh.me:4000` — platform admin
- `{slug}.lvh.me:4000` — tenant subdomain

## Working discipline

- **TDD/BDD first.** Failing test → green. See `CLAUDE.md`.
- **Multi-tenancy is the default.** Every Ash resource is tenant-scoped
  unless it lives in `DrivewayOS.Platform`.
- **No hardcoded brand strings.** Customer-visible copy reads from the
  `Tenant` record.

## Docs

- `CLAUDE.md` — project instructions for AI assistants (and a quick
  human reference for conventions)
- `docs/V1_SCOPE.md` — what ships in V1 vs. deferred to V2

## License

Proprietary — all rights reserved.
