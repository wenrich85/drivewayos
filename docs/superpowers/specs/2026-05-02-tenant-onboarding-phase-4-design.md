# Phase 4 design: Square (payment, second-of-category) + multi-card picker UI

**Status:** Approved design. Plan next.
**Date:** 2026-05-02
**Owner:** Wendell Richards
**Scope:** Phase 4 of the tenant-onboarding roadmap — second provider per
category. V1 ships Square end-to-end (payment connection + Square Checkout
charge-side + webhook + dual-routing in the booking flow), alongside
existing Stripe Connect. Plus the generic multi-card picker UI machinery
in `Steps.Payment`. SendGrid (email, alongside Postmark) follows as Phase
4b. Wizard's Payment step becomes a real choice — tenants who pick Square
can actually take payment through Square, not just connect their account.
Existing-Stripe tenants keep their existing connection without disruption.

## Why this exists

Phase 3 closed the abstraction loop: a brand-new provider category
(`:accounting`) plugged into the existing `Onboarding.Provider`
behaviour without modifying it. Phase 4 closes the *second* loop —
adding a second provider in an *existing* category. After Phase 4, the
abstraction is proven across both axes: new categories AND second
providers per category. Phase 5+ providers (Mailgun, Authorize.net,
Xero, etc.) become mechanical.

The product win: tenants who already use Square POS for their existing
shop can connect that account directly instead of being forced into a
fresh Stripe Connect signup. This removes a meaningful onboarding
friction for the cohort of mobile detailers who are migrating to
DrivewayOS from a paper-and-Square-Reader workflow.

## Constraints + decisions (locked)

| # | Decision | Rationale |
|---|---|---|
| 1 | **Phase 4 ships Square only.** SendGrid follows as Phase 4b. | Two providers + picker UI in one phase doubles the surface area. Splitting validates the picker UI with one real second-provider before doubling. Lower-risk PR per phase. |
| 2 | **Storage = new `Platform.PaymentConnection` resource.** Mirrors Phase 3's `AccountingConnection` shape. Stripe stays on `Tenant` (Phase 1's pattern) — no data migration. | Don't fight Phase 1's existing Stripe data; migrating it is risk for no payoff. New providers from Phase 4 onward use the better connection-resource pattern. The asymmetry is documented and self-explaining. |
| 3 | **Picker UI = side-by-side cards**, each with its own "Connect X" CTA routing directly to that provider's OAuth start. Generalizes via `Registry.by_category(:payment)`. | One-click flow vs. radio+submit's two-click. Stacks vertically on mobile. Generic over N providers — Phase 5+ slots in without UI changes. |
| 4 | **No alternate entry point for Stripe-already-connected tenants.** Wizard's `Steps.Payment.complete?/1` returns true if ANY payment provider is connected. Tenants who already chose Stripe never see Square in the wizard. Switching = email support. | Phase 4's job is "add Square," not "retrofit Stripe lifecycle." Switching has unproven demand and real design depth (Stripe disconnect, multi-active routing). Both deserve a focused phase later if demand emerges. |
| 5 | **Multi-active per category is NOT supported.** A tenant with Stripe connected cannot also connect Square in V1. | Multi-active introduces payment-routing complexity (which provider charges the next booking?) without a clear demand signal. Phase 5+ if it materializes. |
| 6 | **`auto_charge_enabled` flag reserved on `PaymentConnection`** but unused in V1 routing logic. Mirrors Phase 3's `auto_sync_enabled`. | Cheap consistency with Phase 3's resource shape. Phase 5+ may add per-provider charge routing or fallback-on-misbehavior logic. |
| 7 | **Square sandbox/prod toggle via env override**, not per-tenant. `SQUARE_OAUTH_BASE` + `SQUARE_API_BASE` if set, else hardcoded prod. | V1 target is real US mobile detailers — prod by default. Sandbox is a per-developer testing concern. |
| 8 | **`/admin/integrations` extends to merge PaymentConnection rows alongside AccountingConnection rows.** Single table on desktop, card-per-row stack on mobile. Stripe stays absent — managed via existing dashboard surface. | Phase 3's IntegrationsLive already iterates a connection-resource list. Adding payment rows is "free" with the same code path. Stripe asymmetry is documented. |
| 9 | **UI must follow `design-system/MASTER.md`** (locked Phase 1) and the ui-ux-pro-max rule set. Touch targets ≥ 44×44px, color contrast 4.5:1, focus rings, `motion-reduce:transition-none`, `aria-label` on action buttons, `aria-live="polite"` on the table for async announcements, semantic `<table>` markup. | Phase 1 persisted MASTER.md; Phase 4 inherits it. The picker UI surfaces use a card grid (not radio) per ui-ux-pro-max card-selection guidance. |
| 10 | **Phase 4 ships Square end-to-end**, including charge-side wiring + webhook handler. NOT credentials-only. | The wizard's "picker has a real choice" headline only holds if both choices actually take payment. Shipping connect-only would mislead tenants who pick Square — the wizard would say "all set" but their `/book` page couldn't take payment. |
| 11 | **Square charging via Square Checkout API** (hosted payment page, parallel to Stripe Checkout's pattern). NOT Square's Web Payments SDK (embedded card form). | One-to-one parity with Phase 1's Stripe Checkout integration — tenant clicks "Pay" → redirect to Square's hosted page → pay → Square redirects back. Less code than embedding Web Payments SDK; Phase 1's existing redirect-to-checkout pattern carries over. |
| 12 | **Dual-routing in the booking flow.** Booking checkout reads tenant's payment provider state and routes accordingly: `tenant.stripe_account_id` → Stripe Checkout (existing); `PaymentConnection{:square}` exists → Square Checkout (new). At most one is set per tenant (per Decision #5 multi-active rule). | One narrow conditional in the existing checkout call site. Doesn't refactor Stripe's path; just adds an alternate branch. |
| 13 | **`SquareWebhookController` parallel to `StripeWebhookController`.** Both controllers' success path calls `Appointment.mark_paid` (the Phase 3 hook that enqueues `Accounting.SyncWorker`). | Existing webhook → mark_paid → SyncWorker chain is unchanged. Square webhook is a new entry point into the same chain. |
| 14 | **No per-charge platform fee on Square in V1.** Stripe Connect uses `application_fee_amount` (we take a per-charge cut). Square doesn't have an equivalent built-in fee model for OAuth-connected merchants. Square tenants pay us only via SaaS subscription (TenantSubscription). | Square's revenue model for ISVs is referral-based ("flat referral" per roadmap), not per-charge. Building a fee-extraction layer on top of Square would require enrollment in Square's developer program with revenue-share contracts. V1 accepts the asymmetry: Stripe tenants → per-charge fee; Square tenants → SaaS subscription only. Phase 5+ revisits if/when Square offers an equivalent. |

## Architecture

### Module layout

**New modules:**

| Path | Responsibility |
|---|---|
| `lib/driveway_os/platform/payment_connection.ex` | Ash resource. Platform-tier (no multitenancy). Per-(tenant, payment provider) OAuth tokens + lifecycle state. Mirrors `AccountingConnection`'s shape with payment-flavored field names (`auto_charge_enabled`, `last_charge_at`, `external_merchant_id`). |
| `lib/driveway_os/onboarding/providers/square.ex` | `Onboarding.Provider` behaviour adapter. Hosted-redirect OAuth. `provision/2` returns `{:error, :hosted_required}`. |
| `lib/driveway_os/square.ex` | Thin facade module aliasing the OAuth, Client, and Charge submodules. Phase 4 expanded scope means this isn't a no-op anymore — it's the public namespace for Square integration just like `Accounting` is for Zoho. |
| `lib/driveway_os/square/charge.ex` | Square Checkout session creation (parallel to Phase 1's Stripe Checkout layer). `create_checkout_session/3` takes `%PaymentConnection{}`, an Appointment, and a redirect URL; returns `{:ok, %{checkout_url: ..., payment_link_id: ...}}` or `{:error, term}`. Tenant redirects customer to the returned URL. |
| `lib/driveway_os_web/controllers/square_webhook_controller.ex` | `POST /webhooks/square`. Verifies signature via `SQUARE_WEBHOOK_SIGNATURE_KEY`. On `payment.updated` with status `COMPLETED`, looks up the matching Appointment by Square's `order_id` (which we stored as `square_order_id` on the Appointment when creating the checkout session) and calls `Appointment.mark_paid`. Mirrors `StripeWebhookController`'s shape. |
| `lib/driveway_os/square/oauth.ex` | Mirrors `Accounting.OAuth`. `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`, `configured?/0`. |
| `lib/driveway_os/square/client.ex` | `@behaviour` for HTTP layer + concrete `Square.Client.Http` impl. Mox-mockable in tests. |
| `lib/driveway_os/square/client/http.ex` | Concrete Req-based impl. |
| `lib/driveway_os_web/controllers/square_oauth_controller.ex` | `GET /onboarding/square/start` + `GET /onboarding/square/callback`. Mirrors `ZohoOauthController`. Logs `:click` + `:provisioned` via `Affiliate.log_event/4`. |
| `priv/repo/migrations/<ts>_create_platform_payment_connections.exs` | Generated via `mix ash_postgres.generate_migrations`. |

**Modified modules:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform.ex` | Register `PaymentConnection` in domain. Add `Platform.get_payment_connection/2` and `get_active_payment_connection/2` helpers. |
| `lib/driveway_os/platform/oauth_state.ex` | Extend `:purpose` constraint to `[:stripe_connect, :zoho_books, :square]`. |
| `lib/driveway_os/onboarding/registry.ex` | Add `Providers.Square` to `@providers`. |
| `lib/driveway_os/onboarding/steps/payment.ex` | Generalize `render/1` to iterate `Registry.by_category(:payment)` filtered by `configured?` + not-yet-set-up. Generalize `complete?/1` to "any provider in `:payment` category complete for this tenant." |
| `lib/driveway_os_web/live/admin/integrations_live.ex` | Merge `PaymentConnection` rows alongside `AccountingConnection`. Add Category column. Mobile card-per-row layout below `md:` breakpoint. `aria-live="polite"` wrapper. `aria-label` on every action button. Touch-target floor of 44px on action buttons. |
| `lib/driveway_os_web/router.ex` | Add `/onboarding/square/start` + `/onboarding/square/callback` routes. Add `POST /webhooks/square` route. |
| `lib/driveway_os/scheduling/appointment.ex` | Add `:square_order_id` attribute (parallel to existing `stripe_payment_intent_id`). Extend the `:mark_paid` action's `accept` list to take it. |
| Existing booking checkout call site (likely `lib/driveway_os_web/live/booking_live.ex` or wherever Stripe Checkout sessions are created today) | Add a routing branch: if tenant has `stripe_account_id` → existing Stripe Checkout path; if active `PaymentConnection{:square}` → call `Square.Charge.create_checkout_session/3` and redirect to the Square hosted page. The plan reads the existing call site to find the cleanest insertion point. |
| `config/runtime.exs` | Add `square_app_id`, `square_app_secret`, `square_webhook_signature_key`, `square_affiliate_ref_id` env reads. |
| `config/test.exs` | Test placeholders + Mox `:square_client` config. |
| `config/config.exs` | Default `:square_client` to `Square.Client.Http`. |
| `test/test_helper.exs` | `Mox.defmock(DrivewayOS.Square.Client.Mock, for: DrivewayOS.Square.Client)`. |
| `DEPLOY.md` | Add `SQUARE_APP_ID`, `SQUARE_APP_SECRET`, `SQUARE_WEBHOOK_SIGNATURE_KEY`, `SQUARE_AFFILIATE_REF_ID` rows. |

### Data model

```elixir
defmodule DrivewayOS.Platform.PaymentConnection do
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "platform_payment_connections"
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
      constraints one_of: [:square]   # extends Phase 5+
    end

    attribute :external_merchant_id, :string, public?: true   # Square's merchant_id

    attribute :access_token, :string do
      sensitive? true
      public? false
    end

    attribute :refresh_token, :string do
      sensitive? true
      public? false
    end

    attribute :access_token_expires_at, :utc_datetime_usec

    attribute :auto_charge_enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :connected_at, :utc_datetime_usec
    attribute :disconnected_at, :utc_datetime_usec
    attribute :last_charge_at, :utc_datetime_usec
    attribute :last_charge_error, :string

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
      accept [:tenant_id, :provider, :external_merchant_id, :access_token,
              :refresh_token, :access_token_expires_at]
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :reconnect do
      accept [:access_token, :refresh_token, :access_token_expires_at, :external_merchant_id]
      change set_attribute(:disconnected_at, nil)
      change set_attribute(:auto_charge_enabled, true)
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :refresh_tokens do
      accept [:access_token, :refresh_token, :access_token_expires_at]
    end

    update :record_charge_success do
      change set_attribute(:last_charge_at, &DateTime.utc_now/0)
      change set_attribute(:last_charge_error, nil)
    end

    update :record_charge_error do
      accept [:last_charge_error]
    end

    update :disconnect do
      change set_attribute(:access_token, nil)
      change set_attribute(:refresh_token, nil)
      change set_attribute(:access_token_expires_at, nil)
      change set_attribute(:disconnected_at, &DateTime.utc_now/0)
      change set_attribute(:auto_charge_enabled, false)
    end

    update :pause do
      change set_attribute(:auto_charge_enabled, false)
    end

    update :resume do
      change set_attribute(:auto_charge_enabled, true)
    end
  end
end
```

The `:reconnect` action incorporates Phase 3's M1 fix preemptively
(clears `disconnected_at`, refreshes tokens, updates `external_merchant_id`,
restores `auto_charge_enabled: true` in one atomic update).

### `Onboarding.Providers.Square` adapter

Mirrors `Onboarding.Providers.ZohoBooks` exactly. Hosted-redirect, so
`provision/2` returns `{:error, :hosted_required}`. `affiliate_config/0`
reads `:square_affiliate_ref_id` from app env (nil in V1). `tenant_perk/0`
returns `nil`.

```elixir
@impl true
def display do
  %{
    title: "Take card payments via Square",
    blurb:
      "Connect your existing Square account. Customers pay at booking; " <>
        "funds land in your Square balance. We add a small platform fee per charge.",
    cta_label: "Connect Square",
    href: "/onboarding/square/start"
  }
end
```

### `Square.OAuth` helper

Mirrors `Accounting.OAuth` exactly:

- `oauth_url_for/1` — mints `Platform.OauthState` with `purpose: :square`, builds Square's auth URL with state token + scope `PAYMENTS_WRITE PAYMENTS_READ MERCHANT_PROFILE_READ` + redirect_uri.
- `verify_state/1` — pins `purpose: :square` (defense-in-depth, matching Phase 3's pattern after Phase 3 polish).
- `complete_onboarding/2` — exchanges code via `Square.Client.impl().exchange_oauth_code/2` (returns `merchant_id` directly in token response — no separate org-probe call needed, unlike Zoho). Upserts `PaymentConnection` via `:connect` (first time) or `:reconnect` (existing row).
- `configured?/0` — true when `:square_app_id` env is non-empty binary.

OAuth URLs (V1 hardcoded prod; env override available):
- Authorize: `https://connect.squareup.com/oauth2/authorize`
- Token: `https://connect.squareup.com/oauth2/token`

Square OAuth Permissions: `PAYMENTS_WRITE PAYMENTS_READ MERCHANT_PROFILE_READ` lets us charge cards on the tenant's behalf and read their merchant profile.

### `Square.Client` HTTP behaviour

```elixir
defmodule DrivewayOS.Square.Client do
  @callback exchange_oauth_code(code :: String.t(), redirect_uri :: String.t()) ::
              {:ok, %{
                 access_token: String.t(),
                 refresh_token: String.t(),
                 expires_in: integer(),
                 merchant_id: String.t()
               }}
              | {:error, term()}

  @callback refresh_access_token(refresh_token :: String.t()) ::
              {:ok, %{access_token: String.t(), expires_in: integer()}}
              | {:error, term()}

  @callback api_get(access_token, path, params) :: {:ok, map()} | {:error, term()}
  @callback api_post(access_token, path, body) :: {:ok, map()} | {:error, term()}

  @callback create_payment_link(
              access_token :: String.t(),
              body :: %{
                required(:idempotency_key) => String.t(),
                required(:checkout_options) => map(),
                required(:order) => map()  # line items, location_id
              }
            ) ::
              {:ok, %{checkout_url: String.t(), payment_link_id: String.t(),
                      order_id: String.t()}}
              | {:error, term()}

  def impl, do: Application.get_env(:driveway_os, :square_client, __MODULE__.Http)
  defdelegate exchange_oauth_code(code, redirect_uri), to: __MODULE__.Http
  defdelegate refresh_access_token(refresh_token), to: __MODULE__.Http
  defdelegate api_get(access_token, path, params), to: __MODULE__.Http
  defdelegate api_post(access_token, path, body), to: __MODULE__.Http
  defdelegate create_payment_link(access_token, body), to: __MODULE__.Http
end
```

`create_payment_link/2` POSTs to Square's `/v2/online-checkout/payment-links` endpoint and unwraps the response into the three fields the caller needs. Implemented in `Square.Client.Http`.

`Square.Client.Http` impl uses Req. Maps 401 → `{:error, :auth_failed}` on
refresh + api_get + api_post. `exchange_oauth_code` returns the full
`{status, body}` map on non-200 (matching Phase 3's deliberate
divergence — preserves Square's `error_description`).

No `organization_id` arg (Square doesn't have a Zoho-style multi-org concept;
the `merchant_id` is implicit in the access token's scope and returned in the
token-exchange response).

### `Steps.Payment` generalization (the picker)

Current shape: one card (Stripe). Phase 4 generalizes to N cards via
`Registry.by_category(:payment)`.

```elixir
@impl true
def complete?(%Tenant{} = tenant) do
  Registry.by_category(:payment)
  |> Enum.any?(& &1.setup_complete?(tenant))
end

@impl true
def render(assigns) do
  tenant = assigns.current_tenant
  cards = providers_for_picker(tenant)
  assigns = Map.put(assigns, :cards, cards)

  ~H"""
  <div class="space-y-4">
    <p class="text-sm text-slate-600">
      Pick the payment processor you want to use. You can change later by emailing support.
    </p>
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

defp providers_for_picker(tenant) do
  Registry.by_category(:payment)
  |> Enum.filter(& &1.configured?())
  |> Enum.reject(& &1.setup_complete?(tenant))
  |> Enum.map(fn mod -> Map.put(mod.display(), :id, mod.id()) end)
end
```

The same exact shape applies to `Steps.Email` when SendGrid lands (Phase
4b) — generic over `category`. Could optionally extract the picker logic
into a shared `Steps.PickerStep` macro, but for V1 with two would-be
callers (Payment + Email) duplication is fine. Phase 4b makes the
extract-vs-keep call.

### `IntegrationsLive` extension

The merged-table approach extends Phase 3's `IntegrationsLive` to iterate
`PaymentConnection` rows alongside `AccountingConnection` rows. Single
unified row shape:

```elixir
%{
  id: connection.id,
  resource: "payment" | "accounting",   # which Ash resource module to dispatch to
  provider: connection.provider,         # :square | :zoho_books
  category: "Payment" | "Accounting",
  status: status(connection),
  connected_at: ...,
  last_activity_at: ...,                 # last_charge_at OR last_sync_at
  last_error: ...,
  auto_enabled: ...,                     # auto_charge_enabled OR auto_sync_enabled
  disconnected_at: ...
}
```

`load_rows/1` queries both resources, maps each into the unified row
shape, and concatenates.

The pause/resume/disconnect handlers receive
`%{"resource" => "payment", "id" => id}` and dispatch to the right Ash
resource module. The `with_owned_connection/3` cross-tenant defense
helper from Phase 3 is parameterized over the resource module (same
`tenant_id: ^tenant_id` pinned match — defense-in-depth survives the
generalization).

**Two layouts for responsive accessibility:**

1. **Desktop (≥md)** — semantic `<table>` with `<thead>` / `<th scope="col">`.
   Wrapped in `aria-live="polite"` so screen readers announce status
   changes after pause/resume/disconnect.

2. **Mobile (<md)** — card-per-row stack. Same data, vertical layout.
   Action buttons stay 44×44 minimum touch targets. Same
   `aria-live="polite"` wrapper.

Action buttons on both layouts:
- `<button aria-label="Pause Square integration" ...>Pause</button>` — explicit aria-label since visible "Pause" text is identical across rows; aria-label disambiguates which integration.
- Status badges use both color (`badge-success` / `badge-warning` / `badge-ghost` / `badge-error`) AND text label — color isn't the only indicator.
- `min-h-[44px]` on every action button (touch target floor on mobile; harmless on desktop).

Two layouts roughly double the template surface but the action-button cluster lifts cleanly into a Phoenix Component for DRY.

### Affiliate ties (Phase 2 reuse)

- `Square.affiliate_config/0` reads `:square_affiliate_ref_id` from app env. When set, `Affiliate.tag_url(:square)` appends `?ref=<value>` to outbound Square OAuth URLs. **Second V1 production caller of `Affiliate.tag_url/2`** (Phase 3's Zoho was the first).
- `Affiliate.log_event(tenant, :square, :click, %{wizard_step: "payment"})` fires in `start/2` before redirect.
- `Affiliate.log_event(tenant, :square, :provisioned, %{external_merchant_id: ...})` fires in `callback/2` success path.
- `tenant_perk/0` returns `nil` for V1 (no perk advertised yet; flip on later when we enroll in Square's referral program).

### UI/UX rules (from `design-system/MASTER.md` + ui-ux-pro-max)

This section pins the rules every Phase 4 UI surface follows. Inherited from
Phase 1's MASTER + ui-ux-pro-max searches done at brainstorm time.

**Touch & interaction:**
- Touch targets ≥ 44×44px on the picker CTA + table action buttons (mobile).
- `gap-2` minimum between adjacent touch targets.
- `cursor-pointer` on every clickable element (DaisyUI `btn` ships this).

**Accessibility:**
- Color contrast 4.5:1 minimum for text. Use `text-slate-600` (MASTER's muted-text floor) — not lighter.
- Focus rings preserved on every interactive element (DaisyUI `btn` ships them; verify no `focus:outline-none` override).
- `aria-label` on action buttons that share visible text patterns (Pause/Resume/Disconnect across rows).
- `aria-live="polite"` wrapping the table for async status announcements.
- Semantic HTML: `<table>` with `<thead>`, `<tbody>`, `<th scope="col">`. Mobile fallback uses semantic `<article>` or `<section>` elements.
- Status conveyed via text label AND color (color-not-only-indicator).

**Performance / motion:**
- `motion-reduce:transition-none` on hover transitions.
- Hover transitions ≤ 300ms (MASTER says 200ms).

**Style / layout:**
- Card shape: `card bg-base-100 shadow-md border border-slate-200`. Inherits MASTER's `box-shadow: var(--shadow-md)`, `border-radius: 12px` (DaisyUI's `card` default).
- Heading text: `text-slate-900` (MASTER `--color-text`).
- Body text: `text-slate-600` (MASTER muted-text floor).
- Primary CTA: DaisyUI `btn btn-primary` (DaisyUI theme maps to MASTER's `#0369A1` CTA color when the theme is configured to point at it).
- No emojis as icons — Heroicons only (`hero-arrow-right`, `hero-pause`, etc.).
- No layout-shifting hovers — use shadow change, not transform.

## What "done" looks like

After Phase 4 ships:

1. A platform with `SQUARE_APP_ID` + `SQUARE_APP_SECRET` configured (and `STRIPE_CLIENT_ID` from Phase 1) surfaces TWO cards on the wizard's Payment step for tenants who haven't connected any payment provider yet: "Connect Stripe" + "Connect Square via Square."
2. New tenant clicks "Connect Square" → redirected to Square OAuth (with `?ref=<id>` if `SQUARE_AFFILIATE_REF_ID` is set). Authorizes. Lands back on `/admin/integrations` with success flash.
3. `PaymentConnection` row exists with `provider: :square`, tokens populated, `external_merchant_id` from the Square OAuth response, `connected_at` set.
4. `Steps.Payment.complete?(tenant)` returns true → wizard advances past the Payment step.
5. Tenant who already connected Stripe (Phase 1) does NOT see Square in the wizard (Steps.Payment is already complete).
6. `/admin/integrations` shows: AccountingConnection rows (Phase 3) + PaymentConnection rows (Phase 4) merged in one table on desktop, card-per-row stack on mobile. Pause / Resume / Disconnect work for each row.
7. Two `tenant_referrals` rows land per Square onboarding: `:click` (start) + `:provisioned` (callback).
8. Mobile (375px viewport): picker step's two cards stack vertically; integrations page renders cards-per-row instead of a horizontal-scroll table; all action buttons hit ≥44×44px touch targets.
9. Screen-reader on `/admin/integrations`: pause/resume/disconnect announces status change via `aria-live="polite"`.
10. Disconnect → reconnect Square works correctly (no `disconnected_at` stickiness — the Phase 3 M1 bug doesn't recur because `:reconnect` action is in the resource definition from day one).
11. **End-to-end charge:** Tenant who connected Square (only Square, no Stripe) takes a customer booking → booking checkout creates a Square Payment Link via `Square.Charge.create_checkout_session/3` → customer redirected to Square's hosted page → completes payment → Square fires webhook to `/webhooks/square` → `SquareWebhookController` looks up Appointment by `square_order_id`, calls `Appointment.mark_paid` → Phase 3's existing after_action enqueues `Accounting.SyncWorker` → if Zoho is also connected, contact + invoice + payment land in Zoho. Full booking-to-books loop closed.
12. **Stripe-tenant unchanged:** Tenant who connected Stripe (Phase 1) sees no behavioral change. Booking checkout still uses Stripe Checkout via the existing path. The dual-routing branch in the booking flow falls through to Stripe when `tenant.stripe_account_id` is set.
13. **No-payment-provider tenant:** Booking checkout returns an error / redirects to `/admin` with a flash. Same UX as before Phase 4 — no regression.

## Out of scope

- **SendGrid** — Phase 4b. Same shape as Phase 4's Square; the picker UI ships in Phase 4 so SendGrid just adds a card to `Steps.Email`.
- **Stripe disconnect / switching UX** — known limitation; tenants who already chose Stripe stay there until support intervention. Phase 5+ if demand justifies.
- **Multi-active payment providers** per tenant. V1 is one-of-per-category. Phase 5+.
- **Stripe in `/admin/integrations`** — Stripe is on `Tenant`, not in a connection resource. The integrations page stays focused on connection-resource-backed providers (Square + Zoho + future).
- **Square sandbox/prod toggle in UI** — sandbox is a per-developer concern; toggled via env override at deploy time, not per-tenant.
- **Square Subscriptions / recurring** — V1 is one-time charges only (matching Stripe Connect's V1 wiring). Phase 5+.
- **Migrating existing Stripe data into PaymentConnection** — costly and risk-laden. Stripe stays on `Tenant` indefinitely. New providers use the connection-resource pattern.
- **Encrypting tokens at rest** — same posture as Phase 1's `postmark_api_key` and Phase 3's `access_token`. Plaintext in V1; encryption is a cross-cutting hardening pass scheduled separately.
- **Per-charge platform fee on Square** — Stripe Connect's `application_fee_amount` doesn't have a Square-OAuth equivalent (per Decision #14). Square tenants pay us only via SaaS subscription in V1. Phase 5+ revisits if Square offers an equivalent or we enroll in their developer revenue-share program.
- **Square Subscriptions / recurring** — V1 is one-time charges only (matching Stripe Connect's V1 wiring). Phase 5+.
- **Reconciliation worker for Square** — Phase 3 has `Accounting.SyncWorker` for Zoho. Square is direct charges (no parallel sync target), so no reconciliation worker. If Phase 5+ adds a "verify Square payments match our DB nightly" sweeper, it lands then.
- **Picker-logic extract** to a shared `Steps.PickerStep` macro. V1 keeps the duplication between `Steps.Payment` (Phase 4) and `Steps.Email` (Phase 4b). Extract decision lands in Phase 4b once two real callers exist.

## Decisions deferred to plan-writing

- **Migration vs no-migration for OauthState `:purpose` constraint extension.** Phase 3 Task 2 discovered `mix ash_postgres.generate_migrations` reports "No changes detected" because Ash enforces `one_of` at the changeset layer (not via DB CHECK). Phase 4 likely reproduces this; plan reads + acknowledges.
- **Whether `Square.Client.Http` reads OAuth + API base URLs from env (`SQUARE_OAUTH_BASE` + `SQUARE_API_BASE`) at runtime or compile time.** Plan picks based on existing Phase 3 ZohoClient pattern (which uses module attributes — compile-time). For Phase 4, runtime env override may be preferable (sandbox-vs-prod toggling without recompile). Plan resolves.
- **Test layout for the merged IntegrationsLive table.** Phase 3's existing tests cover AccountingConnection rows. Phase 4 adds Square rows; does the test file split into `accounting_test.exs` + `payment_test.exs`, or stay merged with describe blocks per category? Plan picks based on file-size growth.
- **Whether to extract the action-button cluster into a Phoenix Component** to DRY between desktop table + mobile card-stack. Plan resolves based on whether the cluster grows beyond ~15 LOC.
- **Phase 1 `border-base-300` → MASTER `border-slate-200` swap consistency**: should Phase 4 also touch Phase 3's already-shipped `IntegrationsLive` to align borders? Plan picks: probably yes (one-line change), folded into Task 11 (LiveView extension).

## Next step

Implementation plan for Phase 4 — task-by-task breakdown of:

1. `Platform.PaymentConnection` resource + migration + helpers
2. Extend `Platform.OauthState` `:purpose` for `:square`
3. `Square.Client` HTTP behaviour + Http impl + Mox + config wiring (includes `create_payment_link/2`)
4. `Square.OAuth` helper module
5. `Onboarding.Providers.Square` adapter + Registry registration
6. `SquareOauthController` + routes
7. `Steps.Payment` generalization (picker render + complete? predicate)
8. `Square.Charge` module — Square Checkout session creation
9. `Appointment.square_order_id` attribute + migration + extend `:mark_paid` accept
10. `SquareWebhookController` + signature verification + route + tests
11. Booking flow dual-routing — at the existing Stripe Checkout call site, branch on tenant's payment provider state
12. `IntegrationsLive` extension (merged table + mobile card-stack + cross-tenant defense parameterized over resource)
13. Runtime config (`SQUARE_*` env vars + webhook signature) + DEPLOY.md
14. Final verification + push

Each task has its own tests and lands behind `mix test` green. The plan
follows the same TDD shape Phases 1-3 used.
