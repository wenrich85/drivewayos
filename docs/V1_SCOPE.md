# DrivewayOS V1 — Scope

The point of V1 is to **prove the SaaS thesis**: a brand-new mobile
detailing operator can sign up at `drivewayos.com`, complete Stripe
Connect onboarding, and accept their first booking on a branded
subdomain — all in a single demo.

That's the cut line. Everything else is V2.

## In scope

### Multi-tenancy foundation
- `Platform.Tenant` resource (anchor) with status, branding fields,
  Stripe Connect account id, legacy_host
- `Platform.PlatformUser` resource — separate auth for DrivewayOS
  operators (us)
- `Platform.TenantSubscription` — SaaS billing of tenants
- Subdomain routing: `{slug}.drivewayos.com` resolves to the right
  tenant; `admin.drivewayos.com` is platform admin; `drivewayos.com`
  is marketing
- `LoadTenant` plug + LiveView on_mount hook
- Every business resource has Ash `:attribute` multitenancy from
  day one — no "single-tenant first, migrate later" dance

### Customer-facing booking loop
- Per-tenant landing page with branding hooks (display name,
  primary color, logo)
- **Customer auth via AshAuthentication strategies:**
  - **Sign in with Google** (OAuth2 / OpenID Connect)
  - **Sign in with Apple** (Sign in with Apple)
  - **Sign in with Facebook** (OAuth2)
  - Password (email + password) as fallback
  - Magic link (email-only) — optional, low priority
  - Customer is tenant-scoped via JWT `tenant_id` claim — same
    Google account on two different DrivewayOS tenants creates two
    independent Customer rows (each with `tenant_id` of that tenant)
- Service catalog (per tenant; Stripe products live on the tenant's
  Connect account)
- Booking flow: pick service → pick a block from
  tenant-defined templates → pay via Stripe Connect → confirmation
  email
- Customer's "My Appointments" view with status updates
- Email notifications (template uses tenant branding via
  `DrivewayOS.Branding` helper)

### Tenant admin shell
- Sign-in as tenant admin → admin dashboard at
  `{slug}.drivewayos.com/admin`
- Schedule template CRUD (no route optimizer in V1 — just block
  templates)
- Customer list (basic CRUD; no tags, no personas, no notes panel
  in V1)
- Appointment list (table view; no kanban in V1)
- Service + plan CRUD (creates Stripe products on the tenant's
  Connect account)

### Tenant signup flow
- Public signup form at `drivewayos.com/signup` with live slug
  availability check
- `Platform.provision_tenant/1` atomic transaction: creates Tenant
  + first Customer (the tenant admin) + seeds service types,
  block templates
- Stripe Connect OAuth kickoff after sign-up; tenant returns →
  status flips to `:active`
- Welcome email with link to `{slug}.drivewayos.com/admin`

### Platform admin
- `admin.drivewayos.com` — sign in as `PlatformUser`
- Tenant list, tenant detail, suspend/reactivate
- Impersonate-into-tenant (read-only audit-logged session) for
  support
- SaaS billing health: who's paying, who's past due

### Infrastructure
- Wallaby-based smoke test that exercises the full demo loop
  end-to-end against `lvh.me` subdomains
- One canonical `mix precommit` (compile-warnings-as-errors,
  format, unused deps, full test suite)
- Deploy target: DigitalOcean App Platform, same patterns as
  MobileCarWash

## Deliberately deferred to V2

These are valuable, but not for the SaaS thesis demo. Each one waits
until V1 is shipping for at least one paying tenant.

- Dispatch kanban + route optimizer
- Tech mobile flow + checklists + photo uploads + step timers
- E-Myth org chart, SOPs, formation tracker
- Cash flow 5-bucket system
- Marketing CAC dashboard, persona rule engine, social-post composer,
  referral tracking
- Loyalty cards
- Inventory + supply tracking
- Audit log (basic logging is enough for V1; full immutable audit
  resource is V2)
- Custom domains (CNAME + ACME cert provisioning per tenant)
- Per-tenant Twilio / SMTP / Zoho Books — V1 uses one shared
  Twilio + one shared SMTP, with tenant-specific From-name overrides
- AI photo auto-tagging
- iOS push notifications
- Native iOS/Android apps

## Out of scope, period

These don't fit the model:
- Cross-tenant analytics dashboards for tenant admins (only
  platform admins see across tenants)
- Self-serve tenant data export / GDPR delete UI (manual support
  process for V1; automate in V2 if it becomes load-bearing)
- White-label SSO / SAML
- Region pinning / data residency (everything in one DO region)

## Suggested timeline (solo, ~6–8 weeks)

| Week | Slice |
|---|---|
| 1 | Project skeleton, `Platform.Tenant` + `PlatformUser`, subdomain plug, "hello tenant" landing |
| 2 | Customer auth (tenant-scoped) + JWT tenant claim + tenant signup form |
| 3 | Service catalog + Stripe Connect onboarding + tenant admin shell |
| 4 | Booking flow + Stripe payment via Connect account → **two-tenant demo works** |
| 5 | Customer dashboard, appointment status, email notifications |
| 6 | Platform admin dashboard, SaaS billing |
| 7 | Polish, Wallaby smoke test, deploy to staging |
| 8 | Recruit second tenant, gather feedback, ship to production |

## Done criteria for V1

- [ ] `mix precommit` passes
- [ ] Wallaby smoke test: provision two tenants, book a wash on
  each, verify payments route to correct Stripe Connect accounts
- [ ] Cross-tenant isolation test suite: every tenant-scoped
  resource refuses cross-tenant reads
- [ ] At least one real tenant other than the demo accounts has
  signed up via the public flow + completed Stripe Connect +
  taken at least one booking
- [ ] Deployed to `drivewayos.com` (or chosen platform name) on DO

When all of that is true, V1 is done. Move on to V2.
