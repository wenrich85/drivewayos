# Deploying DrivewayOS

Single-page reference for what the runtime needs in production.
The Dockerfile builds a self-contained release; this doc covers
the env vars + infra glue around it.

## Required env vars

These are checked at boot. The release **will not start** if any
of them are missing.

| Var | Why | Example |
|---|---|---|
| `DATABASE_URL` | Postgres connection string. | `ecto://user:pass@host/dbname` |
| `SECRET_KEY_BASE` | Cookie + token signing. Generate with `mix phx.gen.secret`. | 64-char hex |
| `PHX_HOST` | Public hostname. Every email link / `~p` URL resolves through this. | `drivewayos.com` |
| `PLATFORM_TOKEN_SIGNING_SECRET` | Platform-admin auth. Generate with `mix phx.gen.secret`. | 64-char hex |
| `TOKEN_SIGNING_SECRET` | Customer auth. Generate with `mix phx.gen.secret`. | 64-char hex |

## Recommended env vars

Optional but you almost certainly want them on for prod.

| Var | Why | Default |
|---|---|---|
| `PHX_SERVER=true` | Boot the HTTP listener (already set in Dockerfile). | unset |
| `FORCE_SSL=true` | Redirect http→https + HSTS. Required when traffic isn't already TLS-terminated upstream. | off |
| `DB_SSL=true` | TLS to the database. DigitalOcean / RDS / most managed Postgres tiers require it. | off |
| `PORT` | HTTP listener port. | `4000` |
| `POOL_SIZE` | Ecto pool size. Bump for higher concurrency. | `10` |
| `ECTO_IPV6=true` | Bind the DB connection over IPv6. | off |
| `OAUTH_REDIRECT_BASE` | Public URL prefix providers redirect users back to. | unset |

## Per-tenant integrations (set when you wire each one up)

| Var | Why |
|---|---|
| `STRIPE_CLIENT_ID` | Stripe Connect OAuth client id. |
| `STRIPE_SECRET_KEY` | Stripe platform secret key. |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook signing secret. |
| `POSTMARK_ACCOUNT_TOKEN` | Postmark account-level token used to provision tenant-scoped Servers via the API. |
| `POSTMARK_AFFILIATE_REF_ID` | Optional. Platform-level Postmark affiliate referral code; appended to outbound Postmark URLs as `?ref=<value>`. Leave unset until enrolled in Postmark's referral program. |
| `ZOHO_CLIENT_ID` | Zoho Books OAuth client id (one per platform — every tenant uses the same one). Get from Zoho's API console at https://api-console.zoho.com. |
| `ZOHO_CLIENT_SECRET` | Paired with `ZOHO_CLIENT_ID`. |
| `ZOHO_AFFILIATE_REF_ID` | Optional. Platform-level Zoho affiliate referral code; appended to outbound Zoho OAuth URLs as `?ref=<value>`. Leave unset until enrolled in Zoho's referral program. |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` | Outbound mail (Zoho, Postmark, SES, etc.). |

Each is optional at boot — the release will start without them —
but the corresponding feature (Stripe Connect onboarding, booking
emails) silently no-ops until they're filled in.

## What the container does on boot

```
/app/bin/migrate    # runs Ecto.Migrator — idempotent
/app/bin/server     # boots the BEAM
```

`HEALTHCHECK` polls `GET /health` every 30s. The endpoint returns
200 once the Repo is up.

## DNS

For a single-tenant launch (e.g. legacy `drivewaydetailcosa.com`):

```
A     drivewaydetailcosa.com    -> <load balancer IP>
```

For platform mode with subdomain tenants:

```
A     drivewayos.com            -> <load balancer IP>
A     *.drivewayos.com          -> <load balancer IP>
A     admin.drivewayos.com      -> <load balancer IP>
```

The wildcard A record is what makes new tenant signups instantly
addressable at `<slug>.drivewayos.com` without per-tenant DNS.

## SMTP (deliverability)

Whichever SMTP provider you pick, set up at the registrar:

- **SPF**: `v=spf1 include:<provider's spf domain> ~all`
- **DKIM**: provider gives you a CNAME record to add
- **DMARC**: `v=DMARC1; p=quarantine; rua=mailto:postmaster@<your-domain>`

Without these, customer confirmation emails will land in spam for
most major providers (Gmail, Outlook).

## Smoke test once deployed

```
curl https://<host>/health                    # → 200
curl -I https://<host>/                       # → 200 + branded landing
curl https://<host>/some-bogus-path           # → 404 + branded error page
```

## Common boot failures

| Symptom | Likely cause |
|---|---|
| `environment variable PHX_HOST is missing` | Forgot to set `PHX_HOST`. |
| `(DBConnection.ConnectionError) ssl_not_started` | DB requires SSL. Set `DB_SSL=true`. |
| Healthcheck always failing | Port mismatch. Container exposes `$PORT` (default 4000); load balancer must point at the same port. |
| Email links go to `example.com` | You're on a build that predates this doc — re-deploy with PHX_HOST set. |
| Stripe webhook 400s with "missing signature" | `STRIPE_WEBHOOK_SECRET` not set or doesn't match the endpoint config in your Stripe dashboard. |
