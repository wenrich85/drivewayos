# OAuth provider setup

The customer sign-in page (`/sign-in` on any tenant subdomain) shows
Google / Facebook / Apple buttons — but each is hidden until you
provide the credentials below. Until then the password + magic-link
paths are the only sign-in methods, the buttons don't render, and
the app boots cleanly.

This is by design: missing creds disable the strategy gracefully
rather than crashing the boot or rendering dead links.

## What you need

For all three providers:

```bash
# REQUIRED for any OAuth provider — the public base URL where
# providers redirect users back to after they authorize.
# In dev:
export OAUTH_REDIRECT_BASE="http://lvh.me:4000"
# In prod:
export OAUTH_REDIRECT_BASE="https://drivewayos.com"
```

Then per-provider:

### Google

1. https://console.cloud.google.com/apis/credentials → "Create OAuth client ID" → Web application
2. Add to "Authorized redirect URIs":
   - `http://lvh.me:4000/auth/customer/google/callback`  *(dev)*
   - `https://drivewayos.com/auth/customer/google/callback`  *(prod)*
   - Plus any tenant subdomains you'll test against in dev (e.g. `http://acme-wash.lvh.me:4000/auth/customer/google/callback`)
3. Set:
   ```bash
   export GOOGLE_CLIENT_ID="…apps.googleusercontent.com"
   export GOOGLE_CLIENT_SECRET="…"
   ```

### Facebook

1. https://developers.facebook.com/apps/ → Create App → Consumer
2. Settings → Basic → copy App ID + App Secret
3. Products → Facebook Login → Settings → Valid OAuth Redirect URIs:
   - `http://lvh.me:4000/auth/customer/facebook/callback`
   - `https://drivewayos.com/auth/customer/facebook/callback`
4. Set:
   ```bash
   export FACEBOOK_CLIENT_ID="…"
   export FACEBOOK_CLIENT_SECRET="…"
   ```

### Apple

Apple's flow is more involved — you need a Services ID + a private
key (.p8 file) instead of a flat secret.

1. https://developer.apple.com/account → Certificates, Identifiers & Profiles
2. Create an "App ID" if you don't already have one (Bundle ID like `com.drivewayos`)
3. Create a "Services ID" (this becomes your `APPLE_CLIENT_ID`)
4. Configure the Services ID:
   - "Sign In with Apple" enabled
   - Domain: `drivewayos.com` (and `lvh.me` for dev — Apple actually allows this for testing)
   - Return URL: `https://drivewayos.com/auth/customer/apple/callback`
5. Create a "Key" with "Sign In with Apple" enabled. Download the `.p8` file (one-time download — keep it safe). Note the Key ID.
6. From your Apple Developer account, copy your Team ID.
7. Set:
   ```bash
   export APPLE_CLIENT_ID="com.drivewayos.signin"      # the Services ID
   export APPLE_TEAM_ID="ABCDE12345"
   export APPLE_PRIVATE_KEY_ID="ABCDE12345"            # the Key ID
   export APPLE_PRIVATE_KEY_PATH="/etc/secrets/apple_signin_key.p8"
   ```
   The path must be readable by the running BEAM. In Docker, mount the file as a secret; locally for dev, point at a `.p8` you keep outside git.

## Verifying setup

Restart the dev server and visit any tenant `/sign-in` page. The
provider buttons (Google / Facebook / Apple) appear only for
providers whose env vars all resolve. Click → you should be
redirected to the provider's own consent screen.

After successful sign-in:
- AshAuthentication finds-or-creates the `Customer` row in the
  current tenant (matched by email)
- `Auth.AuthController.success/4` mints a customer JWT, persists
  it as `:customer_token` in the session, redirects to `/`

## Multi-tenancy notes

- Customer rows are tenant-scoped, so the same Google email signing
  in on tenant A and tenant B creates two independent Customer rows
  (one per tenant). Intentional: Acme Wash and Bravo Detail are
  different shops, even if you're the same human.
- The `tenant` JWT claim baked into AshAuth ensures a token minted
  on tenant A can never be presented on tenant B's subdomain.
- Provider redirect URIs hit `/auth/customer/{provider}/callback`
  on whichever subdomain the user started from — `LoadTenant`
  classifies `current_tenant` before the AshAuth callback handler
  runs.

## Where the code lives

| Concern | File |
|---|---|
| Strategy declarations (Google/Facebook/Apple) | [lib/driveway_os/accounts/customer.ex](../lib/driveway_os/accounts/customer.ex) |
| Env-var → strategy resolver | [lib/driveway_os/secrets.ex](../lib/driveway_os/secrets.ex) |
| Configured-providers helper | `DrivewayOS.Accounts.configured_oauth_providers/0` in [accounts.ex](../lib/driveway_os/accounts.ex) |
| Callback success/failure handler | [lib/driveway_os_web/controllers/auth/auth_controller.ex](../lib/driveway_os_web/controllers/auth/auth_controller.ex) |
| Route mounting (`auth_routes`) | [lib/driveway_os_web/router.ex](../lib/driveway_os_web/router.ex) |
| Conditional buttons on sign-in page | [lib/driveway_os_web/live/auth/sign_in_live.ex](../lib/driveway_os_web/live/auth/sign_in_live.ex) |
