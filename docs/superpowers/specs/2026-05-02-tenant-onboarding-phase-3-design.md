# Phase 3 design: Accounting (Zoho Books) integration

**Status:** Approved design. Plan next.
**Date:** 2026-05-02
**Owner:** Wendell Richards
**Scope:** Phase 3 of the tenant-onboarding roadmap — introduces a brand-new
provider category (`:accounting`) with one V1 provider (Zoho Books). Lives on
the post-wizard dashboard checklist, not the linear wizard flow. Pushes paid
appointments to the tenant's Zoho Books org as contact + invoice + payment
records via Oban. QuickBooks Online ports across in Phase 4 as the
second-provider-per-category.

## Why this exists

Tenants who reconcile their books at tax time currently re-enter every
DrivewayOS payment by hand into their accounting system. Phase 3 makes that
data flow happen automatically: a tenant connects Zoho Books once via OAuth,
and from that moment forward every successful payment fires an Oban job that
creates the corresponding contact + invoice + payment in their Zoho org.

Phase 3 is also the first proof that the Phase 0/1/2 abstractions
generalize: a brand-new provider category (`:accounting`) plugs into the
existing `Onboarding.Provider` behaviour + Phase 2's `Affiliate.log_event/4`
without modifying either. If the abstraction holds for accounting, it holds
for whatever Phase 5+ category we want next.

## Constraints + decisions (locked)

These were settled in the brainstorming session that produced this doc.

| # | Decision | Rationale |
|---|---|---|
| 1 | **V1 provider is Zoho Books, not QuickBooks Online.** QBO ports across in Phase 4. | Dogfood: Wendell's own books are on Zoho, so the integration validates against real data before any tenant signs up. Zoho's % of MRR affiliate program (vs QBO's flat referral) compounds better long-term too. |
| 2 | **Port + multi-tenantify** the parent-repo `MobileCarWash/lib/mobile_car_wash/accounting/` code (~575 LOC, working single-tenant Zoho integration). Don't rewrite. | Existing code is mature, well-tested, and handles OAuth + token refresh + the Zoho REST API correctly. Rewriting greenfield would re-introduce bugs we already squashed. The single-tenant assumptions live in three surgical edit points. |
| 3 | **Storage = `Platform.AccountingConnection` resource** (platform-tier, no multitenancy). One row per `(tenant, provider)` with OAuth tokens, sync settings, last-sync metadata. | Same call as Phase 2's `TenantReferral`: per-(tenant,provider) state belongs in a dedicated resource, not column sprawl on Tenant. Schema-stable as Phase 4 adds QBO. Token refresh writes don't touch the Tenant hot path. |
| 4 | **Sync trigger: payment-completed only.** When `Payment.status` flips to `:succeeded`, an Oban job fires. | Matches the existing parent-repo SyncWorker pattern. Mobile detailing is overwhelmingly pay-at-booking, so payment-completed is virtually always close to appointment-completed. Phase 4+ can add appointment-completed for post-pay invoicing models. |
| 5 | **`auto_sync_enabled :boolean` toggle** on `AccountingConnection`, default `true`. | One field + one branch in the SyncWorker; pays back the moment a tenant has a real reason to pause sync (month-end reconciliation, accountant request). Without it, the only escape valve is disconnecting and reconnecting, which loses connection state. |
| 6 | **Disconnect = clear tokens, keep row for audit.** Reconnect upserts via the `:unique_tenant_provider` identity. | Audit history (`connected_at`, `disconnected_at`, `last_sync_error`) survives. No row sprawl from repeated connect/disconnect cycles. |
| 7 | **Token-revoke = auto-pause + alert email.** When SyncWorker hits a 401 from Zoho, it sets `auto_sync_enabled = false`, records the error, and emails the tenant admin (via `Mailer.for_tenant/1`). No retry storm. | Same posture as Phase 1's "fire-and-forget with rescue" — never block tenant flows on integration failures. |
| 8 | **Region: hardcode `.com` (US) for V1.** Reserve `region` column on `AccountingConnection` so Phase 4+ can add multi-region without a migration. | US-mobile-detailer target market. International tenants are a hypothetical we don't have evidence for. The column reservation is free; the picker UI isn't. |
| 9 | **Sync direction: one-way only** (DrivewayOS → Zoho). | Two-way (Zoho → DrivewayOS reading) opens reconciliation conflict handling, idempotency on both sides, and a far larger surface area. V1 ships the 90% case; two-way is Phase 5+ if there's demand. |
| 10 | **No QuickBooks in V1.** Parent-repo `quickbooks.ex` stays where it is, ports across in Phase 4. | One provider per category in V1 per the roadmap. Adding both at once doubles the auth + UI + testing work for marginal benefit. |

## Architecture

### Module layout

**New modules:**

| Path | Responsibility |
|---|---|
| `lib/driveway_os/platform/accounting_connection.ex` | Ash resource. Platform-tier (no multitenancy). One row per `(tenant, provider)` storing OAuth tokens, region, sync settings, last-sync metadata. |
| `lib/driveway_os/onboarding/providers/zoho_books.ex` | `Onboarding.Provider` behaviour adapter. Mirrors `Providers.StripeConnect`'s shape. `provision/2` returns `{:error, :hosted_required}`. |
| `lib/driveway_os_web/controllers/zoho_oauth_controller.ex` | `GET /onboarding/zoho/start` + `GET /onboarding/zoho/callback`. Mirrors `StripeOnboardingController`'s shape. Logs `:click`/`:provisioned` via Phase 2's `Affiliate.log_event/4`. |
| `lib/driveway_os_web/live/admin/integrations_live.ex` | `/admin/integrations` LiveView. Lists connected integrations with pause/resume/disconnect buttons per row. First in a series — Phase 4+ will add more rows here as new providers land. |
| `priv/repo/migrations/<ts>_create_platform_accounting_connections.exs` | Generated via `mix ash_postgres.generate_migrations`. |

**Ported modules** (from `MobileCarWash/lib/mobile_car_wash/accounting/`):

| Path | Change |
|---|---|
| `lib/driveway_os/accounting/provider.ex` | Verbatim port. Behaviour declares `create_contact/2`, `find_contact_by_email/2`, `create_invoice/2`, `record_payment/3`, `get_invoice/2` — each takes `connection :: AccountingConnection.t()` as its first arg (was implicit single-tenant before). |
| `lib/driveway_os/accounting/zoho_books.ex` | Port; replace `Application.get_env` token reads with reads off the passed-in `connection`. Replace hardcoded "Driveway Detail Co — Thank you for your business!" with `"#{tenant.display_name} — Thank you for your business!"`. |
| `lib/driveway_os/accounting/accounting.ex` | Facade. Every public function takes `tenant_id` (or `tenant`) as first arg; loads the connection from `AccountingConnection` internally. |
| `lib/driveway_os/accounting/sync_worker.ex` | Oban worker. `perform/1` takes `%{"payment_id" => id, "tenant_id" => tid}` in args. Pre-flight checks: `auto_sync_enabled` true, not disconnected, token unexpired (refresh if needed). Records `:record_sync_success` or `:record_sync_error`. On 401, auto-pauses + emails. |

**Modified modules:**

| Path | Change |
|---|---|
| `lib/driveway_os/onboarding/registry.ex` | Add `Providers.ZohoBooks` to `@providers`. |
| `lib/driveway_os/scheduling/payment.ex` (or wherever `Payment.status` flips) | After successful payment, enqueue `SyncWorker` via `Oban.insert/1` with `tenant_id` in args. Wrap in `try/rescue` — payment flow must not fail on Oban issues. |
| `lib/driveway_os_web/router.ex` | Add `/onboarding/zoho/start` + `/onboarding/zoho/callback` routes. Add `/admin/integrations` LiveView route. |
| `config/runtime.exs` | Read `ZOHO_CLIENT_ID`, `ZOHO_CLIENT_SECRET`, `ZOHO_AFFILIATE_REF_ID` env vars into app config. |
| `config/test.exs` | Test placeholders for the three Zoho env vars. |
| `DEPLOY.md` | Add the three Zoho env vars to the per-tenant integrations table. |

### Data model

```elixir
defmodule DrivewayOS.Platform.AccountingConnection do
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "platform_accounting_connections"
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
      constraints one_of: [:zoho_books]   # extends as Phase 4 adds quickbooks
    end

    attribute :external_org_id, :string, public?: true
    attribute :region, :string, default: "com", public?: true

    attribute :access_token, :string do
      sensitive? true
      public? false
    end

    attribute :refresh_token, :string do
      sensitive? true
      public? false
    end

    attribute :access_token_expires_at, :utc_datetime_usec
    attribute :auto_sync_enabled, :boolean, default: true, public?: true

    attribute :connected_at, :utc_datetime_usec
    attribute :disconnected_at, :utc_datetime_usec
    attribute :last_sync_at, :utc_datetime_usec
    attribute :last_sync_error, :string

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
      accept [:tenant_id, :provider, :external_org_id, :access_token,
              :refresh_token, :access_token_expires_at, :region]
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :refresh_tokens do
      accept [:access_token, :refresh_token, :access_token_expires_at]
    end

    update :record_sync_success do
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
      change set_attribute(:last_sync_error, nil)
    end

    update :record_sync_error do
      accept [:last_sync_error]
    end

    update :disconnect do
      change set_attribute(:access_token, nil)
      change set_attribute(:refresh_token, nil)
      change set_attribute(:access_token_expires_at, nil)
      change set_attribute(:disconnected_at, &DateTime.utc_now/0)
      change set_attribute(:auto_sync_enabled, false)
    end

    update :pause do
      change set_attribute(:auto_sync_enabled, false)
    end

    update :resume do
      change set_attribute(:auto_sync_enabled, true)
    end
  end
end
```

The `:unique_tenant_provider` identity makes connect idempotent — reconnecting `update`s the existing row instead of creating a duplicate.

### `Onboarding.Providers.ZohoBooks` adapter

```elixir
defmodule DrivewayOS.Onboarding.Providers.ZohoBooks do
  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{AccountingConnection, Tenant}
  require Ash.Query

  @impl true
  def id, do: :zoho_books

  @impl true
  def category, do: :accounting

  @impl true
  def display do
    %{
      title: "Sync to Zoho Books",
      blurb: "Auto-create invoices in Zoho Books when customers pay. " <>
             "Tax-time exports without manual entry.",
      cta_label: "Connect Zoho",
      href: "/onboarding/zoho/start"
    }
  end

  @impl true
  def configured? do
    case Application.get_env(:driveway_os, :zoho_client_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  @impl true
  def setup_complete?(%Tenant{} = tenant) do
    case fetch_connection(tenant) do
      {:ok, %AccountingConnection{access_token: t}} when is_binary(t) -> true
      _ -> false
    end
  end

  @impl true
  def provision(_tenant, _params), do: {:error, :hosted_required}

  @impl true
  def affiliate_config do
    %{
      ref_param: "ref",
      ref_id: Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
    }
  end

  @impl true
  def tenant_perk, do: nil

  defp fetch_connection(%Tenant{id: tid}) do
    AccountingConnection
    |> Ash.Query.filter(tenant_id == ^tid and provider == :zoho_books)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :error
      {:ok, conn} -> {:ok, conn}
      _ -> :error
    end
  end
end
```

### OAuth flow

`GET /onboarding/zoho/start` (admin-only):
1. Verify tenant + admin + `ZOHO_CLIENT_ID` configured (mirrors Stripe controller's cond chain).
2. Generate `state` token via `Platform.OauthState` (10-min TTL, single-use).
3. Build OAuth URL: `https://accounts.zoho.com/oauth/v2/auth?client_id=...&scope=ZohoBooks.fullaccess.all&redirect_uri=<callback>&access_type=offline&state=<token>`.
4. Pass through `Affiliate.tag_url/2` so `?ref=<id>` is appended when `ZOHO_AFFILIATE_REF_ID` is set. **First V1 caller of `tag_url/2`** outside its unit tests.
5. `Affiliate.log_event(tenant, :zoho_books, :click, %{wizard_step: "accounting"})`.
6. Redirect to Zoho.

`GET /onboarding/zoho/callback`:
1. `verify_state(state)` → tenant_id (CSRF guard).
2. POST to `https://accounts.zoho.com/oauth/v2/token` with the code → `{access_token, refresh_token, expires_in}`.
3. GET `https://www.zohoapis.com/books/v3/organizations` with the access_token → first `organization_id`.
4. Upsert `AccountingConnection` via `:connect` action (or `:refresh_tokens` if a row already exists for this tenant+provider).
5. `Affiliate.log_event(tenant, :zoho_books, :provisioned, %{external_org_id: ...})`.
6. Redirect to `/admin/integrations` with success flash.

Errors at any step → 400 response + flash + log; do not partial-write. Same posture as Stripe controller's `else _ -> send_resp(conn, 400, ...)` branch.

### SyncWorker

```elixir
defmodule DrivewayOS.Accounting.SyncWorker do
  use Oban.Worker, queue: :billing, max_attempts: 5

  alias DrivewayOS.Accounting
  alias DrivewayOS.Platform.AccountingConnection
  # ... aliases for Payment, Customer, Appointment, ServiceType ...
  require Logger

  @impl true
  def perform(%Oban.Job{args: %{"payment_id" => pid, "tenant_id" => tid}}) do
    with {:ok, connection} <- load_active_connection(tid, :zoho_books),
         {:ok, payment} <- Ash.get(Payment, pid, tenant: tid, authorize?: false),
         {:ok, customer} <- Ash.get(Customer, payment.customer_id, tenant: tid, authorize?: false),
         {:ok, connection} <- ensure_token_fresh(connection),
         service_name = resolve_service_name(payment, tid),
         :ok <- Accounting.sync_payment(connection, customer, payment, service_name) do
      record_sync_success(connection)
      :ok
    else
      {:error, :no_active_connection} ->
        Logger.info("Skipping sync — tenant #{tid} has no active accounting connection")
        :ok                                                           # success — nothing to do

      {:error, :auth_failed} = err ->
        handle_auth_failure(tid)
        :ok                                                           # do not retry; auto-paused

      {:error, reason} ->
        record_sync_error(tid, reason)
        {:error, reason}                                              # let Oban retry
    end
  end

  defp load_active_connection(tid, provider) do
    case Platform.get_active_accounting_connection(tid, provider) do
      {:ok, %{auto_sync_enabled: true, disconnected_at: nil} = conn} -> {:ok, conn}
      _ -> {:error, :no_active_connection}
    end
  end

  defp handle_auth_failure(tid) do
    {:ok, conn} = Platform.get_accounting_connection(tid, :zoho_books)
    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)
    conn |> Ash.Changeset.for_update(:record_sync_error,
      %{last_sync_error: "auth_failed; reconnect at /admin/integrations"})
      |> Ash.update!(authorize?: false)
    send_reconnect_email(tid)
  end

  # ... helpers ...
end
```

The `:no_active_connection` case returns `:ok` not `{:error, _}` — this is "tenant didn't connect accounting; nothing to sync" which is a normal state, not a retryable failure.

### Wizard / dashboard placement

The existing `Onboarding.Registry.needing_setup/1` already filters by `configured?/0` + `setup_complete?/1`. Adding `Providers.ZohoBooks` to `@providers` is enough for the dashboard checklist to surface the row when:
- `ZOHO_CLIENT_ID` is set on the platform, AND
- The tenant has no active AccountingConnection with `:zoho_books` provider.

Once connected, `setup_complete?/1` returns true and the row drops off.

**No `Steps.Accounting`** — accounting is optional, lives only on the post-wizard checklist. The linear wizard flow stays five steps (Branding → Services → Schedule → Payment → Email) per Phase 1.

**`/admin/integrations` LiveView** is a new top-level admin page. Lists each connected integration with:
- Provider name + connected_at + last_sync_at
- Status badge (`active` / `paused` / `disconnected` / `auth-failed`)
- Pause/Resume/Disconnect buttons (per row, role-gated)
- Last error message if any

Phase 4 adds QuickBooks rows here automatically once its provider lands.

### Affiliate integration (Phase 2 ties)

- `ZohoBooks.affiliate_config/0` returns `%{ref_param: "ref", ref_id: <env var>}`. Setting `ZOHO_AFFILIATE_REF_ID` causes outbound Zoho OAuth URLs to be ref-tagged via `Affiliate.tag_url/2`.
- **First V1 production caller of `Affiliate.tag_url/2`** outside its unit tests. Phase 2 added the abstraction; Phase 3 exercises it for real.
- `tenant_perk/0` returns `nil` for V1 (we ship before enrolling). Easy to flip on later.
- Events logged via `Affiliate.log_event/4`: `:click` on OAuth start, `:provisioned` on callback success. `:revenue_attributed` lights up in Phase 4 when we add Zoho's referral webhook handler.

## What "done" looks like

After Phase 3 ships:

1. A platform with `ZOHO_CLIENT_ID` + `ZOHO_CLIENT_SECRET` configured surfaces a "Connect Zoho" row on the `/admin` dashboard checklist for every tenant that hasn't connected. The OAuth redirect URI is derived from `:platform_host` config (matching the Stripe controller's pattern), not a separate env var.
2. Tenant clicks "Connect Zoho" → redirected to Zoho with `state` token + (when enrolled) affiliate ref param. Authorizes. Lands back on `/admin/integrations` with success flash.
3. `AccountingConnection` row exists with `:zoho_books` provider, `access_token`, `refresh_token`, `external_org_id`, `connected_at` populated.
4. Tenant takes a customer payment that succeeds → Oban `SyncWorker` fires → contact + invoice + payment land in tenant's Zoho org within ~10 seconds.
5. `last_sync_at` updates on every success. `last_sync_error` populates on failures.
6. Tenant can pause / resume / disconnect from `/admin/integrations`. Pause stops new sync without losing the connection. Disconnect clears tokens but keeps row for audit.
7. If Zoho revokes our tokens, SyncWorker auto-pauses + emails the tenant a reconnect link. No retry-bombing.
8. Two `tenant_referrals` rows land per successful tenant onboarding: `:click` (start) + `:provisioned` (callback).

## Out of scope

- **QuickBooks Online.** Phase 4 as second provider per category.
- **Multi-region Zoho** (`accounts.zoho.eu`, `.in`, etc.). Column reserved on `AccountingConnection`; UI region-picker and per-region API hosts are Phase 4+.
- **Two-way sync** (Zoho → DrivewayOS). One-way only in V1. Phase 5+ with reconciliation conflict handling.
- **Bulk historical sync** of payments completing before connection. Only post-connection payments sync. Phase 4+ adds a "backfill last 90 days" button if requested.
- **Per-line-item / per-product accounting mapping.** V1 invoices have one line item per payment using the service's name. Tenant chart-of-accounts mapping is Phase 5+.
- **Invoice template customization in DrivewayOS.** Tenants customize templates in their own Zoho dashboard; we don't fight that surface.
- **`Steps.Accounting` in the linear wizard.** Accounting is optional — dashboard checklist only.
- **OAuth token encryption at rest.** Same posture as Phase 1's `postmark_api_key` plaintext storage. Encryption is a Phase 2 hardening pass we'll do across all sensitive columns at once.
- **Granular RBAC on `/admin/integrations`.** Admin-only access for V1. Phase 5+ when a tenant has multiple roles.

## Decisions deferred to plan-writing

- **Whether to extend the existing Stripe `Platform.OauthState` resource for Zoho or create a separate one.** Plan reads the current resource first. Reuse if the shape fits (it should — state token + tenant_id + expiry).
- **Where exactly the Payment-status-flip hook lives.** Plan greps for `:succeeded` status transitions in the existing payment flow and picks the cleanest hook point.
- **Test layout for the Zoho HTTP client.** Mox-style behaviour mock at `lib/driveway_os/accounting/zoho_books/http.ex` with a test impl, mirroring Phase 1's `PostmarkClient` shape. Plan confirms the file structure.
- **Exact email body** sent on token-revoke. Plan-level copy detail.
- **Whether `Accounting` facade is its own module or merged into `Accounting.ZohoBooks`** since V1 has only one provider. Plan reads both options and picks based on Phase 4 readiness — keeping the facade separate makes adding QBO a per-provider edit, not a facade rewrite.

## Next step

Implementation plan for Phase 3 — task-by-task breakdown of:

1. `Platform.AccountingConnection` resource + migration
2. Port `Accounting.Provider` behaviour + multi-tenantify
3. Port `Accounting.ZohoBooks` impl + multi-tenantify
4. Port `Accounting.Accounting` facade + multi-tenantify
5. Port `Accounting.SyncWorker` + multi-tenantify (pre-flight checks, auth-failure handling)
6. `Onboarding.Providers.ZohoBooks` adapter
7. `ZohoOauthController` + routes
8. `Platform.get_accounting_connection/2` + `get_active_accounting_connection/2` helpers
9. Hook SyncWorker enqueue into Payment-success flow
10. `IntegrationsLive` (`/admin/integrations`) for pause/resume/disconnect
11. Runtime config (`ZOHO_*` env vars) + DEPLOY.md
12. Final verification + push

Each task has its own tests and lands behind `mix test` green. The plan
follows the same TDD shape Phase 1 + Phase 2 used.
