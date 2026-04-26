# Deploying DrivewayOS to DigitalOcean

This walks through a first-time deploy to DO App Platform. Aim:
demo-able SaaS at `https://drivewayos.com` with at least one
tenant subdomain serving traffic. About 2 hours start-to-finish
once you have the credentials lined up.

## Prerequisites

You'll need accounts + credentials for:

- [DigitalOcean](https://cloud.digitalocean.com) — App Platform
  + managed Postgres
- [Stripe](https://dashboard.stripe.com) — a Connect platform
  account (Standard, NOT Express/Custom)
- A domain you own (`drivewayos.com` in this guide; substitute
  yours)
- An SMTP provider (Zoho, SES, Postmark, …)

You'll also want `doctl` installed and authenticated:

```sh
brew install doctl
doctl auth init
```

## 1. Generate secrets

```sh
# 64-byte phoenix secret
mix phx.gen.secret

# Two more for the token signing secrets (one for tenant
# customers, one for platform operators — different populations,
# different keys).
mix phx.gen.secret
mix phx.gen.secret
```

Save these somewhere safe. You'll paste them into App Platform's
secrets UI in step 4.

## 2. Set up Stripe Connect

1. In the Stripe dashboard, switch to live mode.
2. Settings → Connect settings → enable "Standard accounts" and
   complete the platform profile.
3. Settings → Connect settings → "Integration" tab. Copy your
   **Client ID** (`ca_…`). That's the `STRIPE_CLIENT_ID`.
4. Add an OAuth redirect URI: `https://drivewayos.com/onboarding/stripe/callback`.
5. Get your **Secret Key** (`sk_live_…`) from API Keys.
6. Webhooks → Add endpoint:
   - URL: `https://drivewayos.com/webhooks/stripe`
   - Events: `checkout.session.completed`,
     `account.updated`, `payment_intent.succeeded`
   - Listen to events on Connected accounts: ✅
   - Copy the signing secret (`whsec_…`). That's the
     `STRIPE_WEBHOOK_SECRET`.

## 3. Create the App Platform app

```sh
# Edit the spec to point at YOUR fork of the repo
# (.do/app.yaml -> services.web.github.repo)
doctl apps create --spec .do/app.yaml
```

DO will prompt for each `SECRET`-marked env var. Paste the values
from step 1 + the Stripe values from step 2. SMTP creds too.

The first deploy takes ~10 min (Docker build + DB provision +
migrations).

## 4. Wire up DNS

Once the app is live and you have its `<app-id>.ondigitalocean.app`
hostname:

1. In your domain registrar's DNS settings, add an `ALIAS` (or
   `CNAME` flattening) on the apex `drivewayos.com` pointing at
   that hostname.
2. Add a wildcard `CNAME` `*.drivewayos.com` pointing at the same.
3. In DO → Apps → drivewayos → Settings → Domains: add both
   `drivewayos.com` and `*.drivewayos.com` as managed domains. DO
   will provision Let's Encrypt certs (for the apex; the wildcard
   needs DNS-01 verification — see DO docs).

## 5. Provision the platform-admin user

The seed script doesn't run in production by default (and shouldn't
— never seed prod data with known passwords). Instead, exec into
the app container and create your operator user manually:

```sh
doctl apps console <APP_ID>

# inside the container:
/app/bin/driveway_os remote
```

In the Elixir shell:

```elixir
{:ok, _} = DrivewayOS.Platform.PlatformUser
|> Ash.Changeset.for_create(:register_with_password, %{
  email: "you@yourcompany.com",
  password: "STRONG-PASSWORD-HERE",
  password_confirmation: "STRONG-PASSWORD-HERE",
  name: "Your Name"
})
|> Ash.create(authorize?: false)
```

Then log in at `https://admin.drivewayos.com`.

## 6. Smoke test the deploy

| URL | Expected |
|---|---|
| `https://drivewayos.com` | Marketing landing page |
| `https://drivewayos.com/signup` | Signup form |
| `https://admin.drivewayos.com/platform-sign-in` | Platform admin sign-in |
| `https://drivewayos.com/webhooks/stripe` | 400 with body "invalid signature" (correct — proves the route is live) |

## 7. First real tenant

Sign up via `https://drivewayos.com/signup`. If you used slug
`acme-wash`, you should land on `https://acme-wash.drivewayos.com`.
Then click "Connect Stripe" in the admin dashboard to walk
through the OAuth onboarding.

If everything works end-to-end, the SaaS thesis is shipped. 🎉

## Troubleshooting

- **App fails to boot, logs say `secret_key_base is missing`** —
  you forgot to set the `SECRET_KEY_BASE` env var in App Platform.
- **404 on every request** — check that `PLATFORM_HOST` matches
  your actual domain. The `LoadTenant` plug 404s any host that
  doesn't match.
- **Subdomains 404 but apex works** — your wildcard DNS isn't
  set up yet, or the wildcard cert hasn't been issued.
- **Stripe webhook always 400s** — make sure
  `STRIPE_WEBHOOK_SECRET` matches exactly what's in the Stripe
  dashboard. Each webhook endpoint has its own secret.
- **Emails don't arrive** — check the SMTP creds. Many providers
  also require you to verify the From domain (DKIM / SPF) before
  they'll deliver mail with that From address.

## Updating

`deploy_on_push: true` is set in `.do/app.yaml`, so any push to
`main` automatically triggers a build + zero-downtime deploy.
Migrations run on every container start (`bin/migrate && bin/server`).
