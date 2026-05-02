# Tenant Onboarding Phase 3 — Accounting (Zoho Books)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first `:accounting` category provider (Zoho Books) so tenants can connect their Zoho Books org via OAuth and have every successful payment auto-create the corresponding contact + invoice + payment in their books. QuickBooks Online ports across in Phase 4.

**Architecture:** Port + multi-tenantify ~575 LOC of working single-tenant Zoho code from the parent `MobileCarWash` repo. New `Platform.AccountingConnection` Ash resource holds per-tenant OAuth tokens + sync state. Provider behaviour shifts from "module-level config-read" to "first-arg connection struct" so multiple tenants share one server-wide module. `Accounting.SyncWorker` Oban job fires from a new Ash `change` on `Appointment.mark_paid`, takes `tenant_id` + `appointment_id`, gracefully bails when no active connection exists. `Onboarding.Providers.ZohoBooks` adapter + `ZohoOauthController` mirror the Stripe Connect shapes from Phase 0/1. Phase 2's `Affiliate.tag_url/2` gets its first production caller (outbound Zoho OAuth URLs).

**Tech Stack:** Elixir 1.18 / Phoenix LiveView 1.1 / Ash 3.24 / AshPostgres 2.9 / Oban / Req (HTTP) / Mox (test mocking). Tests use ExUnit with `DrivewayOS.DataCase` and `DrivewayOSWeb.ConnCase`. Standard test command: `mix test`.

**Spec:** `docs/superpowers/specs/2026-05-02-tenant-onboarding-phase-3-design.md` — read the "Constraints + decisions" + "Architecture" sections before starting.

**Phase 1 (already shipped):** `docs/superpowers/plans/2026-04-29-tenant-onboarding-phase-1.md`. Provides the wizard + Postmark provider + `Platform.OauthState` + `Mailer.for_tenant/1`.

**Phase 2 (already shipped):** `docs/superpowers/plans/2026-05-02-tenant-onboarding-phase-2.md`. Provides `Onboarding.Affiliate` (`tag_url/2`, `perk_copy/1`, `log_event/4`), `Platform.TenantReferral` events table, optional `affiliate_config/0` + `tenant_perk/0` callbacks on `Onboarding.Provider`.

**Branch policy:** Execute on `main`. Commit after each task. Push to origin after Task 12 (final verification).

---

## Spec deviations (decided during plan-writing)

Reading the codebase before writing the plan surfaced four facts the spec couldn't anticipate. Documented up front so per-task code is internally consistent.

1. **No separate `Payment` resource.** DrivewayOS stores payment status on `Appointment` (`payment_status :atom` constrained to `[:paid, :refunded, :failed]`). The spec's "When `Payment.status` flips to `:succeeded`" is implemented as: hook the `Appointment.mark_paid` action via an Ash `change` that enqueues `Accounting.SyncWorker` with `appointment_id` (not `payment_id`). The parent-repo SyncWorker took `payment_id`; ours takes `appointment_id`.

2. **`Accounting.SyncWorker` takes `appointment_id`, not `payment_id`.** Follows from #1. The worker reads the Appointment's `paid_at`, `stripe_payment_intent_id`, `service_type_id`, `customer_id`, and the tenant's `display_name` to build the invoice.

3. **Reuse existing `Platform.OauthState` resource** by extending its `:purpose` constraint from `[:stripe_connect]` to `[:stripe_connect, :zoho_books]`. The shape (token, tenant_id, expires_at, single-use) fits Zoho exactly. The migration is one column constraint change.

4. **Table is `platform_accounting_connections`** (matches dominant `platform_*` prefix established in Phase 2's deviation #2 — `platform_tenant_referrals`, `platform_oauth_states`, `platform_custom_domains`).

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `priv/repo/migrations/<ts>_create_platform_accounting_connections.exs` | Generated via `mix ash_postgres.generate_migrations`. Creates `platform_accounting_connections` table + FK + unique-tenant-provider identity. |
| `priv/repo/migrations/<ts>_extend_oauth_state_purpose_for_zoho.exs` | Extends `platform_oauth_states.purpose` constraint to allow `:zoho_books`. |
| `lib/driveway_os/platform/accounting_connection.ex` | Ash resource. Platform-tier (no multitenancy). Per-(tenant, provider) OAuth tokens + sync state. |
| `lib/driveway_os/accounting.ex` | Domain module. Registers `AccountingConnection` (no — wait, AccountingConnection is in Platform domain — see Task 1). This file is the FACADE — `Accounting.sync_payment/4`, `Accounting.find_or_create_contact/2`, etc. takes a `connection :: AccountingConnection.t()` as the first arg. |
| `lib/driveway_os/accounting/provider.ex` | Behaviour. Five callbacks: `create_contact/2`, `find_contact_by_email/2`, `create_invoice/2`, `record_payment/3`, `get_invoice/2`. Each takes `connection` as first arg. |
| `lib/driveway_os/accounting/zoho_client.ex` | `@behaviour` for HTTP layer + concrete impl using Req. Mockable in tests via Mox. |
| `lib/driveway_os/accounting/zoho_books.ex` | `Accounting.Provider` impl for Zoho. Reads tokens from passed-in `connection`, calls `ZohoClient` for HTTP. |
| `lib/driveway_os/accounting/sync_worker.ex` | Oban worker. Pre-flight checks (active connection? auto-sync enabled? token unexpired?), then calls `Accounting.sync_payment/4`. Auto-pauses + emails on auth failure. |
| `lib/driveway_os/accounting/oauth.ex` | Mirrors `Billing.StripeConnect`. `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`, `configured?/0`. |
| `lib/driveway_os/onboarding/providers/zoho_books.ex` | `Onboarding.Provider` adapter. Mirrors `providers/stripe_connect.ex`. |
| `lib/driveway_os_web/controllers/zoho_oauth_controller.ex` | `GET /onboarding/zoho/start` + `GET /onboarding/zoho/callback`. Mirrors `stripe_onboarding_controller.ex`. |
| `lib/driveway_os_web/live/admin/integrations_live.ex` | `/admin/integrations` LiveView. Connected-integrations table with pause/resume/disconnect buttons per row. |
| `test/driveway_os/platform/accounting_connection_test.exs` | Resource CRUD + identity uniqueness. |
| `test/driveway_os/accounting/zoho_books_test.exs` | Provider behaviour conformance + each callback's happy + error paths (mocked HTTP). |
| `test/driveway_os/accounting/sync_worker_test.exs` | Worker pre-flight checks (no connection, paused, disconnected, auth-fail). |
| `test/driveway_os/accounting/oauth_test.exs` | OAuth URL building, state verification, code exchange. |
| `test/driveway_os/onboarding/providers/zoho_books_test.exs` | Adapter conformance + callbacks. |
| `test/driveway_os_web/controllers/zoho_oauth_controller_test.exs` | Start logs `:click`, callback logs `:provisioned`, error path returns 400. |
| `test/driveway_os_web/live/admin/integrations_live_test.exs` | Auth gate + rows render + pause/resume/disconnect actions. |

**Modified:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform.ex` | Register `AccountingConnection` in the domain. Add `Platform.get_accounting_connection/2` + `get_active_accounting_connection/2` helpers. |
| `lib/driveway_os/platform/oauth_state.ex` | Extend `:purpose` constraint to `[:stripe_connect, :zoho_books]`. |
| `lib/driveway_os/onboarding/registry.ex` | Add `Providers.ZohoBooks` to `@providers`. |
| `lib/driveway_os/scheduling/appointment.ex` | Add `change` to the `:mark_paid` action that enqueues `Accounting.SyncWorker`. |
| `lib/driveway_os_web/router.ex` | Add `/onboarding/zoho/start`, `/onboarding/zoho/callback`, `/admin/integrations` routes. |
| `config/runtime.exs` | Add `zoho_client_id`, `zoho_client_secret`, `zoho_affiliate_ref_id` env reads. |
| `config/test.exs` | Test placeholders. Mox `defmock` for `ZohoClient`. |
| `config/config.exs` | Default `:zoho_client` impl to `ZohoClient.Http` (test override applies via `config/test.exs`). |
| `DEPLOY.md` | Add `ZOHO_CLIENT_ID`, `ZOHO_CLIENT_SECRET`, `ZOHO_AFFILIATE_REF_ID` rows. |
| `test/test_helper.exs` | Mox `defmock` for `ZohoClient`. |

---

## Task 1: `Platform.AccountingConnection` resource + migration

**Files:**
- Create: `lib/driveway_os/platform/accounting_connection.ex`
- Create: `priv/repo/migrations/<ts>_create_platform_accounting_connections.exs` (via `mix ash_postgres.generate_migrations`)
- Modify: `lib/driveway_os/platform.ex` (register resource + helpers)
- Test: `test/driveway_os/platform/accounting_connection_test.exs`

- [ ] **Step 1: Write the failing resource test**

Create `test/driveway_os/platform/accounting_connection_test.exs`:

```elixir
defmodule DrivewayOS.Platform.AccountingConnectionTest do
  @moduledoc """
  Pin the `Platform.AccountingConnection` contract: per-(tenant,
  provider) OAuth tokens + sync state. Connect creates, refresh
  updates tokens, disconnect clears tokens but keeps row, pause/resume
  toggles auto_sync_enabled. Reconnecting the same provider for the
  same tenant upserts via the unique identity.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ac-#{System.unique_integer([:positive])}",
        display_name: "Accounting Test",
        admin_email: "ac-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "connect creates a row with auto_sync_enabled true and connected_at set", ctx do
    {:ok, conn} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :zoho_books,
        external_org_id: "12345",
        access_token: "at-1",
        refresh_token: "rt-1",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        region: "com"
      })
      |> Ash.create(authorize?: false)

    assert conn.tenant_id == ctx.tenant.id
    assert conn.provider == :zoho_books
    assert conn.access_token == "at-1"
    assert conn.refresh_token == "rt-1"
    assert conn.auto_sync_enabled == true
    assert %DateTime{} = conn.connected_at
    assert conn.disconnected_at == nil
  end

  test "refresh_tokens updates the three token fields", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:refresh_tokens, %{
        access_token: "at-2",
        refresh_token: "rt-2",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 7200, :second)
      })
      |> Ash.update(authorize?: false)

    assert updated.access_token == "at-2"
    assert updated.refresh_token == "rt-2"
  end

  test "disconnect clears tokens, sets disconnected_at, pauses sync", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update(authorize?: false)

    assert updated.access_token == nil
    assert updated.refresh_token == nil
    assert updated.access_token_expires_at == nil
    assert %DateTime{} = updated.disconnected_at
    assert updated.auto_sync_enabled == false
  end

  test "pause and resume toggle auto_sync_enabled", ctx do
    conn = connect_zoho!(ctx.tenant.id)
    {:ok, paused} = conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update(authorize?: false)
    refute paused.auto_sync_enabled

    {:ok, resumed} = paused |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update(authorize?: false)
    assert resumed.auto_sync_enabled
  end

  test "record_sync_success sets last_sync_at and clears error", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    {:ok, with_err} =
      conn
      |> Ash.Changeset.for_update(:record_sync_error, %{last_sync_error: "boom"})
      |> Ash.update(authorize?: false)

    assert with_err.last_sync_error == "boom"

    {:ok, healed} =
      with_err
      |> Ash.Changeset.for_update(:record_sync_success, %{})
      |> Ash.update(authorize?: false)

    assert %DateTime{} = healed.last_sync_at
    assert healed.last_sync_error == nil
  end

  test "unique_tenant_provider identity rejects duplicate (tenant, provider)", ctx do
    _ = connect_zoho!(ctx.tenant.id)

    {:error, %Ash.Error.Invalid{}} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :zoho_books,
        external_org_id: "67890",
        access_token: "at-99",
        refresh_token: "rt-99",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        region: "com"
      })
      |> Ash.create(authorize?: false)
  end

  test "provider rejects unknown values (only :zoho_books in V1)", ctx do
    {:error, %Ash.Error.Invalid{}} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :totally_not_a_real_provider,
        external_org_id: "1",
        access_token: "x",
        refresh_token: "y",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)
  end

  defp connect_zoho!(tenant_id) do
    AccountingConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :zoho_books,
      external_org_id: "12345",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    })
    |> Ash.create!(authorize?: false)
  end
end
```

- [ ] **Step 2: Run the test — should fail (module not found)**

```bash
mix test test/driveway_os/platform/accounting_connection_test.exs
```

Expected: compile error / module not found for `DrivewayOS.Platform.AccountingConnection`.

- [ ] **Step 3: Create the resource**

Create `lib/driveway_os/platform/accounting_connection.ex`:

```elixir
defmodule DrivewayOS.Platform.AccountingConnection do
  @moduledoc """
  Per-(tenant, provider) accounting integration record. Stores OAuth
  tokens, sync settings, and last-sync metadata. Platform-tier — no
  multitenancy block; tenants don't read this directly, only the
  Accounting modules and the IntegrationsLive page do.

  Lifecycle:
    * `:connect` — first time tenant authorizes; populates tokens.
    * `:refresh_tokens` — periodic; replaces access/refresh tokens.
    * `:record_sync_success` / `:record_sync_error` — SyncWorker.
    * `:pause` / `:resume` — tenant-controlled, toggles auto_sync_enabled.
    * `:disconnect` — clears tokens, sets disconnected_at, auto-pauses.
       Reconnect upserts via the `:unique_tenant_provider` identity.

  Tokens are sensitive (Ash redacts them in logs); plaintext at rest
  in V1, matching Phase 1's `postmark_api_key` posture. Encryption is
  a Phase 2 hardening pass (separate from the multi-phase onboarding
  roadmap).
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

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
      constraints one_of: [:zoho_books]
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

    attribute :auto_sync_enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

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

- [ ] **Step 4: Register in Platform domain + add helpers**

Edit `lib/driveway_os/platform.ex`. Find the `alias DrivewayOS.Platform.{...}` block at the top and add `AccountingConnection` to the list. Find the `resources do` block and add `resource AccountingConnection`.

Then append two query helpers near the existing `get_tenant_by_*` helpers:

```elixir
  @doc """
  Look up the AccountingConnection for a (tenant, provider) tuple.
  Returns `{:ok, connection}` or `{:error, :not_found}`. Used by the
  Accounting modules to load credentials before any provider call.
  """
  @spec get_accounting_connection(binary(), atom()) ::
          {:ok, AccountingConnection.t()} | {:error, :not_found}
  def get_accounting_connection(tenant_id, provider)
      when is_binary(tenant_id) and is_atom(provider) do
    AccountingConnection
    |> Ash.Query.filter(tenant_id == ^tenant_id and provider == ^provider)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Like `get_accounting_connection/2` but also rejects rows that
  aren't actively syncing — disconnected, paused, or missing tokens.
  Returns `{:error, :no_active_connection}` for any of those states.
  """
  @spec get_active_accounting_connection(binary(), atom()) ::
          {:ok, AccountingConnection.t()} | {:error, :no_active_connection}
  def get_active_accounting_connection(tenant_id, provider) do
    case get_accounting_connection(tenant_id, provider) do
      {:ok, %AccountingConnection{
         auto_sync_enabled: true,
         disconnected_at: nil,
         access_token: token
       } = conn}
      when is_binary(token) ->
        {:ok, conn}

      _ ->
        {:error, :no_active_connection}
    end
  end
```

- [ ] **Step 5: Generate the migration**

```bash
mix ash_postgres.generate_migrations --name create_platform_accounting_connections
```

Expected: a new file at `priv/repo/migrations/<ts>_create_platform_accounting_connections.exs` containing `create table(:platform_accounting_connections)` with `tenant_id` FK, all attributes, the unique index on `(tenant_id, provider)`.

- [ ] **Step 6: Apply the migration in test env**

```bash
MIX_ENV=test mix ecto.migrate
```

Expected: clean migration apply.

- [ ] **Step 7: Re-run the test**

```bash
mix test test/driveway_os/platform/accounting_connection_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/driveway_os/platform/accounting_connection.ex \
        lib/driveway_os/platform.ex \
        priv/repo/migrations/*_create_platform_accounting_connections.exs \
        priv/resource_snapshots/repo/platform_accounting_connections \
        test/driveway_os/platform/accounting_connection_test.exs

git commit -m "Platform: AccountingConnection resource + Platform.get_*_accounting_connection helpers"
```

---

## Task 2: Extend `Platform.OauthState` for `:zoho_books`

**Files:**
- Modify: `lib/driveway_os/platform/oauth_state.ex` (extend `:purpose` constraint)
- Create: `priv/repo/migrations/<ts>_extend_oauth_state_purpose_for_zoho.exs` (generated)

- [ ] **Step 1: Extend the constraint**

In `lib/driveway_os/platform/oauth_state.ex`, find:

```elixir
    attribute :purpose, :atom do
      constraints one_of: [:stripe_connect]
      default :stripe_connect
      allow_nil? false
      public? true
    end
```

Change to:

```elixir
    attribute :purpose, :atom do
      constraints one_of: [:stripe_connect, :zoho_books]
      default :stripe_connect
      allow_nil? false
      public? true
    end
```

- [ ] **Step 2: Generate the migration**

```bash
mix ash_postgres.generate_migrations --name extend_oauth_state_purpose_for_zoho
```

Expected: a migration that updates the check constraint on `platform_oauth_states.purpose` to allow the new value. (AshPostgres handles atom-enum constraint changes via DROP + ADD.)

- [ ] **Step 3: Apply migration**

```bash
MIX_ENV=test mix ecto.migrate
```

- [ ] **Step 4: Run the existing OauthState tests to confirm no regression**

```bash
mix test --only platform
```

Expected: all green; `:stripe_connect` issue + verify still works.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/platform/oauth_state.ex \
        priv/repo/migrations/*_extend_oauth_state_purpose_for_zoho.exs \
        priv/resource_snapshots/repo/platform_oauth_states

git commit -m "Platform.OauthState: extend :purpose constraint to allow :zoho_books"
```

---

## Task 3: `Accounting.Provider` behaviour + facade

**Files:**
- Create: `lib/driveway_os/accounting.ex` (facade — function-only module, no Ash domain)
- Create: `lib/driveway_os/accounting/provider.ex` (behaviour)

- [ ] **Step 1: Create the behaviour**

Create `lib/driveway_os/accounting/provider.ex`:

```elixir
defmodule DrivewayOS.Accounting.Provider do
  @moduledoc """
  Behaviour for accounting integrations. Each provider implements
  the same five callbacks; the facade in `DrivewayOS.Accounting`
  delegates based on the connection's `provider` atom.

  Every callback takes `connection :: AccountingConnection.t()` as
  its first arg. The connection carries the OAuth credentials, the
  tenant's external_org_id (Zoho's organization_id, QBO's realm_id),
  and the region — everything a provider call needs.

  Phase 4 adds QuickBooks Online by implementing this behaviour
  against the QBO REST API.
  """

  alias DrivewayOS.Platform.AccountingConnection

  @type connection :: AccountingConnection.t()

  @type contact_params :: %{
          required(:name) => String.t(),
          required(:email) => String.t(),
          optional(:phone) => String.t() | nil
        }

  @type line_item :: %{
          required(:name) => String.t(),
          required(:amount_cents) => integer(),
          optional(:quantity) => integer()
        }

  @type invoice_params :: %{
          required(:contact_id) => String.t(),
          required(:line_items) => [line_item()],
          required(:payment_id) => String.t(),
          optional(:notes) => String.t()
        }

  @type payment_params :: %{
          required(:amount_cents) => integer(),
          required(:payment_date) => Date.t(),
          optional(:reference) => String.t() | nil
        }

  @callback create_contact(connection(), contact_params()) :: {:ok, map()} | {:error, term()}
  @callback find_contact_by_email(connection(), String.t()) ::
              {:ok, map()} | {:error, :not_found} | {:error, term()}
  @callback create_invoice(connection(), invoice_params()) :: {:ok, map()} | {:error, term()}
  @callback record_payment(connection(), invoice_id :: String.t(), payment_params()) ::
              {:ok, map()} | {:error, term()}
  @callback get_invoice(connection(), invoice_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
```

- [ ] **Step 2: Create the facade**

Create `lib/driveway_os/accounting.ex`:

```elixir
defmodule DrivewayOS.Accounting do
  @moduledoc """
  Facade over per-provider accounting modules. Resolves the provider
  module from `connection.provider` and delegates each call. Phase 3
  has only `:zoho_books`; Phase 4 will add `:quickbooks`.

  `sync_payment/4` is the high-level operation called from the Oban
  SyncWorker — it does the find-or-create-contact + create-invoice +
  record-payment chain in one call.
  """

  require Logger

  alias DrivewayOS.Platform.AccountingConnection

  @providers %{
    zoho_books: DrivewayOS.Accounting.ZohoBooks
  }

  @doc """
  Resolve a provider module from a connection. Raises if the provider
  isn't registered (programmer error — we'd never store an unknown
  provider in the DB given the `:one_of` constraint).
  """
  @spec provider_module!(AccountingConnection.t()) :: module()
  def provider_module!(%AccountingConnection{provider: provider}) do
    Map.fetch!(@providers, provider)
  end

  @doc """
  Find or create a contact in the accounting system by email.
  """
  @spec find_or_create_contact(AccountingConnection.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def find_or_create_contact(%AccountingConnection{} = conn, params) do
    mod = provider_module!(conn)

    case mod.find_contact_by_email(conn, params.email) do
      {:ok, contact} -> {:ok, contact}
      {:error, :not_found} -> mod.create_contact(conn, params)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_invoice(AccountingConnection.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_invoice(%AccountingConnection{} = conn, params) do
    provider_module!(conn).create_invoice(conn, params)
  end

  @spec record_payment(AccountingConnection.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def record_payment(%AccountingConnection{} = conn, invoice_id, params) do
    provider_module!(conn).record_payment(conn, invoice_id, params)
  end

  @doc """
  Full sync: find/create contact, create invoice, record payment.
  Called by `Accounting.SyncWorker`. Uses `tenant.display_name` in
  the invoice notes so each tenant's invoices look like their brand,
  not DrivewayOS's.
  """
  @spec sync_payment(
          AccountingConnection.t(),
          DrivewayOS.Platform.Tenant.t(),
          DrivewayOS.Scheduling.Appointment.t(),
          DrivewayOS.Accounts.Customer.t(),
          String.t()
        ) ::
          :ok | {:error, term()}
  def sync_payment(%AccountingConnection{} = conn, tenant, appointment, customer, service_name) do
    with {:ok, contact} <-
           find_or_create_contact(conn, %{
             name: customer.name,
             email: to_string(customer.email),
             phone: customer.phone
           }),
         contact_id = extract_contact_id(contact),
         {:ok, invoice} <-
           create_invoice(conn, %{
             contact_id: contact_id,
             line_items: [
               %{name: service_name, amount_cents: appointment.price_cents, quantity: 1}
             ],
             payment_id: appointment.stripe_payment_intent_id || appointment.id,
             notes: "#{tenant.display_name} — #{service_name}"
           }),
         invoice_id = extract_invoice_id(invoice),
         {:ok, _payment} <-
           record_payment(conn, invoice_id, %{
             amount_cents: appointment.price_cents,
             payment_date:
               (appointment.paid_at && DateTime.to_date(appointment.paid_at)) ||
                 Date.utc_today(),
             reference: appointment.stripe_payment_intent_id
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Accounting.sync_payment failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Provider response shapes vary; each impl returns a contact map,
  # but the id field's name differs. Phase 4 (QBO) extends these.
  defp extract_contact_id(%{"contact_id" => id}), do: id
  defp extract_contact_id(%{"Id" => id}), do: id
  defp extract_contact_id(c), do: c["id"]

  defp extract_invoice_id(%{"invoice_id" => id}), do: id
  defp extract_invoice_id(%{"Id" => id}), do: id
  defp extract_invoice_id(i), do: i["id"]
end
```

- [ ] **Step 3: Verify compilation**

```bash
mix compile
```

Expected: clean compile (warning expected: `DrivewayOS.Accounting.ZohoBooks` referenced in `@providers` but not yet defined — Task 5 will land it).

- [ ] **Step 4: Commit**

```bash
git add lib/driveway_os/accounting.ex lib/driveway_os/accounting/provider.ex

git commit -m "Accounting: behaviour + facade scaffolding (Zoho impl lands Task 5)"
```

---

## Task 4: `Accounting.ZohoClient` HTTP wrapper + Mox mock

**Files:**
- Create: `lib/driveway_os/accounting/zoho_client.ex` (behaviour + Http impl)
- Modify: `config/config.exs` (default impl)
- Modify: `config/test.exs` (Mox mock)
- Modify: `test/test_helper.exs` (Mox.defmock)
- Test: integrated into `zoho_books_test.exs` (Task 5)

The HTTP wrapper isolates Req calls behind a behaviour so tests can mock without making real network calls — same pattern Phase 1 used for `PostmarkClient`.

- [ ] **Step 1: Create the behaviour + concrete impl in one file**

Create `lib/driveway_os/accounting/zoho_client.ex`:

```elixir
defmodule DrivewayOS.Accounting.ZohoClient do
  @moduledoc """
  Behaviour for the Zoho Books HTTP layer. Three concerns:

    * `exchange_oauth_code/2` — POST to /oauth/v2/token to convert
      the authorization code returned on the OAuth callback into an
      access_token + refresh_token.
    * `refresh_access_token/2` — POST to /oauth/v2/token with grant
      type `refresh_token` to get a fresh access_token when the
      stored one expires.
    * `api_get/4` / `api_post/4` — REST calls against
      `https://www.zohoapis.com/books/v3/...` with the access_token
      in the auth header. Always pass `organization_id` query param.

  Tests Mox-mock this behaviour. Production uses
  `DrivewayOS.Accounting.ZohoClient.Http`.
  """

  @callback exchange_oauth_code(code :: String.t(), redirect_uri :: String.t()) ::
              {:ok, %{
                 access_token: String.t(),
                 refresh_token: String.t(),
                 expires_in: integer()
               }}
              | {:error, term()}

  @callback refresh_access_token(refresh_token :: String.t(), client_secret :: String.t()) ::
              {:ok, %{access_token: String.t(), expires_in: integer()}}
              | {:error, term()}

  @callback api_get(
              access_token :: String.t(),
              organization_id :: String.t(),
              path :: String.t(),
              params :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback api_post(
              access_token :: String.t(),
              organization_id :: String.t(),
              path :: String.t(),
              body :: map()
            ) :: {:ok, map()} | {:error, term()}

  @doc "Returns the configured impl module — production = Http, tests = Mox mock."
  @spec impl() :: module()
  def impl, do: Application.get_env(:driveway_os, :zoho_client, __MODULE__.Http)

  defdelegate exchange_oauth_code(code, redirect_uri), to: __MODULE__.Http
  defdelegate refresh_access_token(refresh_token, client_secret), to: __MODULE__.Http
  defdelegate api_get(access_token, org_id, path, params), to: __MODULE__.Http
  defdelegate api_post(access_token, org_id, path, body), to: __MODULE__.Http
end
```

Append (in same file or a separate file — separate is cleaner):

Create `lib/driveway_os/accounting/zoho_client/http.ex`:

```elixir
defmodule DrivewayOS.Accounting.ZohoClient.Http do
  @moduledoc """
  Production impl of the `ZohoClient` behaviour. Uses Req. Hardcoded
  to the .com region for V1 (per spec decision #8).
  """
  @behaviour DrivewayOS.Accounting.ZohoClient

  require Logger

  @oauth_base "https://accounts.zoho.com"
  @api_base "https://www.zohoapis.com/books/v3"

  @impl true
  def exchange_oauth_code(code, redirect_uri) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "client_id" => Application.fetch_env!(:driveway_os, :zoho_client_id),
        "client_secret" => Application.fetch_env!(:driveway_os, :zoho_client_secret),
        "redirect_uri" => redirect_uri,
        "code" => code
      })

    case Req.post("#{@oauth_base}/oauth/v2/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => at, "refresh_token" => rt} = b}} ->
        {:ok,
         %{
           access_token: at,
           refresh_token: rt,
           expires_in: b["expires_in"] || 3600
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Zoho code exchange failed status=#{status} body=#{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def refresh_access_token(refresh_token, _client_secret) do
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "client_id" => Application.fetch_env!(:driveway_os, :zoho_client_id),
        "client_secret" => Application.fetch_env!(:driveway_os, :zoho_client_secret),
        "refresh_token" => refresh_token
      })

    case Req.post("#{@oauth_base}/oauth/v2/token",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => at} = b}} ->
        {:ok, %{access_token: at, expires_in: b["expires_in"] || 3600}}

      {:ok, %{status: 401}} ->
        {:error, :auth_failed}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def api_get(access_token, org_id, path, params \\ []) do
    params = Keyword.put(params, :organization_id, org_id)

    case Req.get("#{@api_base}#{path}",
           params: params,
           headers: auth_headers(access_token)
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :auth_failed}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def api_post(access_token, org_id, path, body) do
    url = "#{@api_base}#{path}?organization_id=#{org_id}"

    # Zoho expects form-encoded JSONString param.
    form = %{"JSONString" => Jason.encode!(body)}

    case Req.post(url, form: form, headers: auth_headers(access_token)) do
      {:ok, %{status: status, body: body}} when status in [200, 201] -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :auth_failed}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth_headers(token), do: [{"authorization", "Zoho-oauthtoken #{token}"}]
end
```

- [ ] **Step 2: Add Mox mock + test config**

Edit `test/test_helper.exs`. Find the existing Mox lines (Phase 1's `PostmarkClient.Mock`) and add:

```elixir
Mox.defmock(DrivewayOS.Accounting.ZohoClient.Mock, for: DrivewayOS.Accounting.ZohoClient)
```

Edit `config/test.exs`. Near the existing `:postmark_client` mock config or alongside, add:

```elixir
config :driveway_os, :zoho_client, DrivewayOS.Accounting.ZohoClient.Mock
config :driveway_os, :zoho_client_id, "test-zoho-client-id"
config :driveway_os, :zoho_client_secret, "test-zoho-client-secret"
config :driveway_os, :zoho_affiliate_ref_id, nil
```

Edit `config/config.exs`. Near where Phase 1 might have set the default postmark_client, add:

```elixir
config :driveway_os, :zoho_client, DrivewayOS.Accounting.ZohoClient.Http
```

(If no postmark_client default is set in config.exs because it was deferred to runtime.exs, do the same for zoho_client — set the default in `config/config.exs` so test.exs can override it cleanly.)

- [ ] **Step 3: Verify compilation**

```bash
mix compile
```

Expected: clean compile.

- [ ] **Step 4: Run the full test suite**

```bash
mix test
```

Expected: 0 failures (no new tests added in this task — implementation lands behind a Mox mock, exercised in Task 5).

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/accounting/zoho_client.ex \
        lib/driveway_os/accounting/zoho_client/http.ex \
        config/config.exs config/test.exs test/test_helper.exs

git commit -m "Accounting.ZohoClient: behaviour + Http impl + Mox mock + config wiring"
```

---

## Task 5: `Accounting.ZohoBooks` provider impl

**Files:**
- Create: `lib/driveway_os/accounting/zoho_books.ex`
- Test: `test/driveway_os/accounting/zoho_books_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/accounting/zoho_books_test.exs`:

```elixir
defmodule DrivewayOS.Accounting.ZohoBooksTest do
  @moduledoc """
  Provider behaviour conformance + happy/error paths for each
  callback. HTTP is Mox-stubbed via `ZohoClient.Mock`. Tests pass a
  pre-built AccountingConnection struct (no DB, no provision_tenant)
  to keep the surface fast — the provider doesn't care where the
  connection came from.
  """
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Accounting.ZohoBooks
  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform.AccountingConnection

  setup :verify_on_exit!

  defp connection do
    %AccountingConnection{
      tenant_id: "tenant-1",
      provider: :zoho_books,
      external_org_id: "org-99",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    }
  end

  describe "create_contact/2" do
    test "happy path returns the new contact map" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn at, org, path, body ->
        assert at == "at-1"
        assert org == "org-99"
        assert path == "/contacts"
        assert body["contact_name"] == "Pat Customer"
        assert body["email"] == "pat@example.com"
        assert body["contact_type"] == "customer"
        {:ok, %{"contact" => %{"contact_id" => "c-1", "contact_name" => "Pat Customer"}}}
      end)

      assert {:ok, %{"contact_id" => "c-1"}} =
               ZohoBooks.create_contact(conn, %{
                 name: "Pat Customer",
                 email: "pat@example.com",
                 phone: "555-0100"
               })
    end

    test "error path propagates the http error" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn _, _, _, _ ->
        {:error, %{status: 422, body: %{"message" => "duplicate"}}}
      end)

      assert {:error, %{status: 422}} =
               ZohoBooks.create_contact(conn, %{name: "X", email: "x@y", phone: nil})
    end
  end

  describe "find_contact_by_email/2" do
    test "returns the first contact when one or more match" do
      conn = connection()

      expect(ZohoClient.Mock, :api_get, fn _at, _org, "/contacts", params ->
        assert params[:email] == "pat@example.com"
        {:ok, %{"contacts" => [%{"contact_id" => "c-1"}, %{"contact_id" => "c-2"}]}}
      end)

      assert {:ok, %{"contact_id" => "c-1"}} =
               ZohoBooks.find_contact_by_email(conn, "pat@example.com")
    end

    test "returns :not_found when contacts list is empty" do
      conn = connection()

      expect(ZohoClient.Mock, :api_get, fn _, _, _, _ ->
        {:ok, %{"contacts" => []}}
      end)

      assert {:error, :not_found} =
               ZohoBooks.find_contact_by_email(conn, "nope@example.com")
    end
  end

  describe "create_invoice/2" do
    test "shapes the request body and returns the invoice map" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn _at, _org, "/invoices", body ->
        assert body["customer_id"] == "c-1"
        assert [item] = body["line_items"]
        assert item["name"] == "Basic Wash"
        assert item["rate"] == 50.0
        assert body["notes"] =~ "Thank you"
        assert body["reference_number"] == "pi_123"
        {:ok, %{"invoice" => %{"invoice_id" => "inv-1"}}}
      end)

      assert {:ok, %{"invoice_id" => "inv-1"}} =
               ZohoBooks.create_invoice(conn, %{
                 contact_id: "c-1",
                 line_items: [%{name: "Basic Wash", amount_cents: 5000, quantity: 1}],
                 payment_id: "pi_123",
                 notes: "Acme Wash — Thank you for your business!"
               })
    end
  end

  describe "record_payment/3" do
    test "ISO8601-encodes the date and posts to the invoice's payments path" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn _at, _org, path, body ->
        assert path == "/invoices/inv-1/payments"
        assert body["amount"] == 50.0
        assert body["date"] == "2026-05-02"
        assert body["payment_mode"] == "creditcard"
        assert body["reference_number"] == "pi_123"
        {:ok, %{"payment" => %{"payment_id" => "pay-1"}}}
      end)

      assert {:ok, %{"payment_id" => "pay-1"}} =
               ZohoBooks.record_payment(conn, "inv-1", %{
                 amount_cents: 5000,
                 payment_date: ~D[2026-05-02],
                 reference: "pi_123"
               })
    end
  end

  describe "get_invoice/2" do
    test "fetches and unwraps the invoice envelope" do
      conn = connection()

      expect(ZohoClient.Mock, :api_get, fn _, _, "/invoices/inv-1", _ ->
        {:ok, %{"invoice" => %{"invoice_id" => "inv-1", "status" => "paid"}}}
      end)

      assert {:ok, %{"status" => "paid"}} = ZohoBooks.get_invoice(conn, "inv-1")
    end
  end
end
```

- [ ] **Step 2: Run the test — should fail (module not defined)**

```bash
mix test test/driveway_os/accounting/zoho_books_test.exs
```

Expected: compile error / undefined `DrivewayOS.Accounting.ZohoBooks`.

- [ ] **Step 3: Implement the provider**

Create `lib/driveway_os/accounting/zoho_books.ex`:

```elixir
defmodule DrivewayOS.Accounting.ZohoBooks do
  @moduledoc """
  Zoho Books `Accounting.Provider` impl.

  Each callback takes the `AccountingConnection` and pulls the
  access_token + organization_id from it. HTTP is delegated to
  `ZohoClient.impl()` (production = `ZohoClient.Http`, tests = Mox).

  Shape ported from
  `MobileCarWash.Accounting.ZohoBooks` (single-tenant) — the three
  surgical multi-tenant edits per spec decision #2 are:
    1. tokens come from connection, not Application config
    2. organization_id comes from connection, not Application config
    3. invoice notes are caller-supplied (facade injects tenant.display_name)
  """
  @behaviour DrivewayOS.Accounting.Provider

  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform.AccountingConnection

  @impl true
  def create_contact(%AccountingConnection{} = conn, params) do
    body = %{
      "contact_name" => params.name,
      "email" => params.email,
      "phone" => params[:phone],
      "contact_type" => "customer"
    }

    case ZohoClient.impl().api_post(conn.access_token, conn.external_org_id, "/contacts", body) do
      {:ok, %{"contact" => contact}} -> {:ok, contact}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def find_contact_by_email(%AccountingConnection{} = conn, email) when is_binary(email) do
    case ZohoClient.impl().api_get(
           conn.access_token,
           conn.external_org_id,
           "/contacts",
           email: email
         ) do
      {:ok, %{"contacts" => [contact | _]}} -> {:ok, contact}
      {:ok, %{"contacts" => []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_invoice(%AccountingConnection{} = conn, params) do
    line_items =
      Enum.map(params.line_items, fn item ->
        %{
          "name" => item.name,
          "rate" => item.amount_cents / 100,
          "quantity" => item[:quantity] || 1
        }
      end)

    body = %{
      "customer_id" => params.contact_id,
      "line_items" => line_items,
      "notes" => params[:notes] || "Thank you for your business!",
      "reference_number" => params.payment_id
    }

    case ZohoClient.impl().api_post(conn.access_token, conn.external_org_id, "/invoices", body) do
      {:ok, %{"invoice" => invoice}} -> {:ok, invoice}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def record_payment(%AccountingConnection{} = conn, invoice_id, params) do
    body = %{
      "amount" => params.amount_cents / 100,
      "date" => Date.to_iso8601(params.payment_date),
      "payment_mode" => "creditcard",
      "reference_number" => params[:reference]
    }

    case ZohoClient.impl().api_post(
           conn.access_token,
           conn.external_org_id,
           "/invoices/#{invoice_id}/payments",
           body
         ) do
      {:ok, %{"payment" => payment}} -> {:ok, payment}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_invoice(%AccountingConnection{} = conn, invoice_id) do
    case ZohoClient.impl().api_get(
           conn.access_token,
           conn.external_org_id,
           "/invoices/#{invoice_id}",
           []
         ) do
      {:ok, %{"invoice" => invoice}} -> {:ok, invoice}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Re-run the test**

```bash
mix test test/driveway_os/accounting/zoho_books_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/accounting/zoho_books.ex \
        test/driveway_os/accounting/zoho_books_test.exs

git commit -m "Accounting.ZohoBooks: provider impl with connection-arg pattern"
```

---

## Task 6: `Accounting.SyncWorker` Oban worker

**Files:**
- Create: `lib/driveway_os/accounting/sync_worker.ex`
- Test: `test/driveway_os/accounting/sync_worker_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/accounting/sync_worker_test.exs`:

```elixir
defmodule DrivewayOS.Accounting.SyncWorkerTest do
  @moduledoc """
  Pre-flight checks dominate the worker's surface. The actual
  Accounting.sync_payment call is exercised by zoho_books_test +
  the facade test (Task 3 doesn't add one — facade is thin
  delegation), so this suite focuses on the worker's gating logic.
  """
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Accounting.{SyncWorker, ZohoClient}
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sw-#{System.unique_integer([:positive])}",
        display_name: "Sync Worker Test",
        admin_email: "sw-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "skips sync when tenant has no AccountingConnection (returns :ok)", ctx do
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    # No Mox expectations — the worker shouldn't call ZohoClient.
    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })
  end

  test "skips sync when AccountingConnection is paused", ctx do
    connect_zoho!(ctx.tenant.id)
    pause_zoho!(ctx.tenant.id)
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })
  end

  test "skips sync when AccountingConnection is disconnected", ctx do
    conn = connect_zoho!(ctx.tenant.id)

    conn
    |> Ash.Changeset.for_update(:disconnect, %{})
    |> Ash.update!(authorize?: false)

    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })
  end

  test "happy path: pushes contact + invoice + payment, records last_sync_at", ctx do
    conn = connect_zoho!(ctx.tenant.id)
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    expect(ZohoClient.Mock, :api_get, fn _, _, "/contacts", _ ->
      {:ok, %{"contacts" => []}}
    end)

    expect(ZohoClient.Mock, :api_post, fn _, _, "/contacts", _ ->
      {:ok, %{"contact" => %{"contact_id" => "c-1"}}}
    end)

    expect(ZohoClient.Mock, :api_post, fn _, _, "/invoices", _ ->
      {:ok, %{"invoice" => %{"invoice_id" => "inv-1"}}}
    end)

    expect(ZohoClient.Mock, :api_post, fn _, _, "/invoices/inv-1/payments", _ ->
      {:ok, %{"payment" => %{"payment_id" => "pay-1"}}}
    end)

    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })

    {:ok, refreshed} =
      Ash.get(AccountingConnection, conn.id, authorize?: false)

    assert %DateTime{} = refreshed.last_sync_at
    assert refreshed.last_sync_error == nil
  end

  test "auth failure (401) auto-pauses + emails", ctx do
    _conn = connect_zoho!(ctx.tenant.id)
    appt = create_paid_appointment!(ctx.tenant.id, ctx.admin.id)

    # First HTTP call returns auth_failed.
    expect(ZohoClient.Mock, :api_get, fn _, _, _, _ -> {:error, :auth_failed} end)

    # Worker returns :ok (no Oban retries; we auto-paused).
    assert :ok =
             perform_job(SyncWorker, %{
               "tenant_id" => ctx.tenant.id,
               "appointment_id" => appt.id
             })

    {:ok, refreshed} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    refute refreshed.auto_sync_enabled
    assert refreshed.last_sync_error =~ "auth_failed"

    # Email captured by the Test adapter.
    import Swoosh.TestAssertions
    assert_email_sent(fn email -> assert email.subject =~ "reconnect" end)
  end

  defp connect_zoho!(tenant_id) do
    AccountingConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :zoho_books,
      external_org_id: "org-99",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    })
    |> Ash.create!(authorize?: false)
  end

  defp pause_zoho!(tenant_id) do
    {:ok, conn} = Platform.get_accounting_connection(tenant_id, :zoho_books)
    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)
  end

  defp create_paid_appointment!(tenant_id, admin_id) do
    # Helper: build a ServiceType + Appointment in :paid state. Uses
    # whatever existing test helpers the codebase has — the Phase 1
    # email_test.exs already creates appointments via similar setup
    # (refer to its `setup` block for the canonical shape).
    # Adapt to local helpers when implementing.
    raise "Implement using existing test helpers when wiring the test up"
  end
end
```

**Note for the implementer**: `create_paid_appointment!/2` is a local helper. When implementing, look at how `test/driveway_os_web/controllers/stripe_webhook_controller_test.exs` constructs an appointment (the same shape the Stripe webhook test uses). Lift that helper into this test file. Don't import — copy. Tests should be readable as standalone.

The `perform_job/2` helper comes from `Oban.Testing` — already used in Phase 1's worker tests.

- [ ] **Step 2: Run the test — should fail**

```bash
mix test test/driveway_os/accounting/sync_worker_test.exs
```

Expected: failure on undefined `SyncWorker` module.

- [ ] **Step 3: Implement the worker**

Create `lib/driveway_os/accounting/sync_worker.ex`:

```elixir
defmodule DrivewayOS.Accounting.SyncWorker do
  @moduledoc """
  Oban worker that syncs a paid Appointment to the tenant's accounting
  system. Enqueued from the Ash `:mark_paid` change on Appointment
  (Task 9).

  Pre-flight checks (in order):
    1. Active connection exists for (tenant, :zoho_books)?
       If not — `:ok`, nothing to do (most tenants).
    2. Connection's access_token still valid? If expired, refresh.
       If refresh fails with auth, auto-pause + email + `:ok`.
    3. Hand off to `Accounting.sync_payment/5`. On `{:error, :auth_failed}`,
       same auto-pause path. On other errors, return `{:error, reason}`
       so Oban retries up to `max_attempts`.

  Never blocks tenant flows (the `:mark_paid` change wraps the
  Oban.insert in try/rescue per Task 9 — failure to enqueue logs but
  doesn't fail the payment).
  """
  use Oban.Worker, queue: :billing, max_attempts: 5

  alias DrivewayOS.Accounting
  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Mailer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tid, "appointment_id" => aid}}) do
    with {:ok, connection} <- Platform.get_active_accounting_connection(tid, :zoho_books),
         {:ok, tenant} <- Ash.get(DrivewayOS.Platform.Tenant, tid, authorize?: false),
         {:ok, appt} <- Ash.get(Appointment, aid, tenant: tid, authorize?: false),
         {:ok, customer} <- Ash.get(Customer, appt.customer_id, tenant: tid, authorize?: false),
         {:ok, connection} <- ensure_token_fresh(connection),
         service_name = resolve_service_name(appt, tid),
         :ok <- Accounting.sync_payment(connection, tenant, appt, customer, service_name) do
      record_sync_success(connection)
      :ok
    else
      {:error, :no_active_connection} ->
        Logger.info("Accounting sync skipped: no active connection for tenant=#{tid}")
        :ok

      {:error, :auth_failed} ->
        handle_auth_failure(tid)
        :ok

      {:error, reason} ->
        record_sync_error(tid, reason)
        {:error, reason}
    end
  end

  defp ensure_token_fresh(%AccountingConnection{access_token_expires_at: exp} = conn) do
    if DateTime.compare(exp, DateTime.utc_now()) == :gt do
      {:ok, conn}
    else
      case ZohoClient.impl().refresh_access_token(conn.refresh_token, "") do
        {:ok, %{access_token: at, expires_in: secs}} ->
          conn
          |> Ash.Changeset.for_update(:refresh_tokens, %{
            access_token: at,
            refresh_token: conn.refresh_token,
            access_token_expires_at: DateTime.add(DateTime.utc_now(), secs, :second)
          })
          |> Ash.update(authorize?: false)

        {:error, :auth_failed} = err ->
          err

        err ->
          err
      end
    end
  end

  defp handle_auth_failure(tenant_id) do
    case Platform.get_accounting_connection(tenant_id, :zoho_books) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:pause, %{})
        |> Ash.update!(authorize?: false)

        conn
        |> Ash.Changeset.for_update(:record_sync_error, %{
          last_sync_error: "auth_failed; reconnect at /admin/integrations"
        })
        |> Ash.update!(authorize?: false)

        send_reconnect_email(tenant_id)

      _ ->
        :ok
    end
  end

  defp record_sync_success(conn) do
    conn
    |> Ash.Changeset.for_update(:record_sync_success, %{})
    |> Ash.update!(authorize?: false)
  end

  defp record_sync_error(tenant_id, reason) do
    case Platform.get_accounting_connection(tenant_id, :zoho_books) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:record_sync_error, %{
          last_sync_error: inspect(reason)
        })
        |> Ash.update!(authorize?: false)

      _ ->
        :ok
    end
  end

  defp send_reconnect_email(tenant_id) do
    with {:ok, tenant} <- Ash.get(DrivewayOS.Platform.Tenant, tenant_id, authorize?: false),
         [admin | _] <- DrivewayOS.Accounts.tenant_admins(tenant_id) do
      email = reconnect_email(tenant, admin)
      Mailer.deliver(email, Mailer.for_tenant(tenant))
    end

    :ok
  rescue
    _ -> :ok
  end

  defp reconnect_email(tenant, admin) do
    Swoosh.Email.new()
    |> Swoosh.Email.to({admin.name, to_string(admin.email)})
    |> Swoosh.Email.from(DrivewayOS.Branding.from_address(tenant))
    |> Swoosh.Email.subject("Action needed: reconnect Zoho Books")
    |> Swoosh.Email.text_body("""
    Hi #{admin.name},

    Your Zoho Books connection for #{tenant.display_name} stopped
    working — likely an expired token or revoked authorization. To
    resume syncing payments to your books, please reconnect:

    /admin/integrations

    No payments are missed in DrivewayOS — only the auto-sync to
    Zoho is paused.

    -- DrivewayOS
    """)
  end

  defp resolve_service_name(appt, tenant_id) do
    case Ash.get(ServiceType, appt.service_type_id, tenant: tenant_id, authorize?: false) do
      {:ok, svc} -> svc.name
      _ -> "Detailing Service"
    end
  end
end
```

- [ ] **Step 4: Re-run the test**

Implement the `create_paid_appointment!/2` helper in the test file (copy from existing webhook test patterns), then run:

```bash
mix test test/driveway_os/accounting/sync_worker_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/accounting/sync_worker.ex \
        test/driveway_os/accounting/sync_worker_test.exs

git commit -m "Accounting.SyncWorker: pre-flight gating + auto-pause-on-auth-fail"
```

---

## Task 7: `Accounting.OAuth` module

**Files:**
- Create: `lib/driveway_os/accounting/oauth.ex`
- Test: `test/driveway_os/accounting/oauth_test.exs`

This is the Zoho-side analog of `Billing.StripeConnect` — `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`, `configured?/0`. The shape mirrors Stripe Connect exactly.

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/accounting/oauth_test.exs`:

```elixir
defmodule DrivewayOS.Accounting.OAuthTest do
  @moduledoc """
  Pin the Zoho OAuth helper module: URL construction, state token
  consumption, code exchange. HTTP is Mox-stubbed.
  """
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Accounting.{OAuth, ZohoClient}
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "oa-#{System.unique_integer([:positive])}",
        display_name: "OAuth Test",
        admin_email: "oa-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  describe "configured?/0" do
    test "true when zoho_client_id is set" do
      assert OAuth.configured?()
    end

    test "false when zoho_client_id is empty/nil" do
      original = Application.get_env(:driveway_os, :zoho_client_id)
      Application.put_env(:driveway_os, :zoho_client_id, "")
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_client_id, original) end)

      refute OAuth.configured?()
    end
  end

  describe "oauth_url_for/1" do
    test "builds the auth URL with state token bound to the tenant", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)

      assert url =~ "accounts.zoho.com/oauth/v2/auth"
      assert url =~ "client_id=test-zoho-client-id"
      assert url =~ "scope=ZohoBooks.fullaccess.all"
      assert url =~ "access_type=offline"
      assert url =~ "state="

      # State token persisted with :zoho_books purpose
      [state_param] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, _} =
               DrivewayOS.Platform.OauthState
               |> Ash.Query.for_read(:by_token, %{token: state_param})
               |> Ash.read(authorize?: false)
    end
  end

  describe "verify_state/1" do
    test "consumes a valid state token and returns the tenant_id", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, tid} = OAuth.verify_state(token)
      assert tid == ctx.tenant.id

      # Single-use: a second verify fails
      assert {:error, :invalid_state} = OAuth.verify_state(token)
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_state} = OAuth.verify_state("nope-not-a-real-token")
    end
  end

  describe "complete_onboarding/2" do
    test "exchanges code, probes orgs, upserts AccountingConnection", ctx do
      expect(ZohoClient.Mock, :exchange_oauth_code, fn code, _redirect_uri ->
        assert code == "auth-code-123"
        {:ok, %{access_token: "at-99", refresh_token: "rt-99", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _at, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "999"}]}}
      end)

      assert {:ok, %AccountingConnection{} = conn} =
               OAuth.complete_onboarding(ctx.tenant, "auth-code-123")

      assert conn.tenant_id == ctx.tenant.id
      assert conn.provider == :zoho_books
      assert conn.access_token == "at-99"
      assert conn.refresh_token == "rt-99"
      assert conn.external_org_id == "999"
    end

    test "reconnect upserts the existing row instead of creating a duplicate", ctx do
      # First connect
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-1", refresh_token: "rt-1", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "999"}]}}
      end)

      {:ok, _} = OAuth.complete_onboarding(ctx.tenant, "code-1")

      # Reconnect — fresh tokens, same row.
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-2", refresh_token: "rt-2", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "999"}]}}
      end)

      {:ok, conn2} = OAuth.complete_onboarding(ctx.tenant, "code-2")
      assert conn2.access_token == "at-2"
      assert conn2.refresh_token == "rt-2"

      # Confirm only one row exists.
      {:ok, all} = Ash.read(AccountingConnection, authorize?: false)
      assert Enum.count(all, &(&1.tenant_id == ctx.tenant.id)) == 1
    end

    test "code-exchange failure returns error tuple, no row written", ctx do
      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:error, %{status: 400, body: %{"error" => "invalid_code"}}}
      end)

      assert {:error, %{status: 400}} =
               OAuth.complete_onboarding(ctx.tenant, "bad-code")

      assert {:error, :not_found} =
               Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    end
  end
end
```

- [ ] **Step 2: Run the test — should fail**

```bash
mix test test/driveway_os/accounting/oauth_test.exs
```

Expected: undefined module `DrivewayOS.Accounting.OAuth`.

- [ ] **Step 3: Implement the module**

Create `lib/driveway_os/accounting/oauth.ex`:

```elixir
defmodule DrivewayOS.Accounting.OAuth do
  @moduledoc """
  Zoho Books OAuth helper. Mirrors `DrivewayOS.Billing.StripeConnect`'s
  shape — same `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`,
  `configured?/0` quartet.

  V1 hardcodes the `.com` region (per spec decision #8).
  """

  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform.{AccountingConnection, OauthState, Tenant}

  require Ash.Query

  @oauth_authorize_url "https://accounts.zoho.com/oauth/v2/auth"

  @doc """
  Build the Zoho OAuth URL for `tenant`. Mints a CSRF-safe state
  token bound to the tenant, then encodes it in the URL.
  """
  @spec oauth_url_for(Tenant.t()) :: String.t()
  def oauth_url_for(%Tenant{id: tenant_id}) do
    {:ok, state} =
      OauthState
      |> Ash.Changeset.for_create(:issue, %{
        tenant_id: tenant_id,
        purpose: :zoho_books
      })
      |> Ash.create(authorize?: false)

    params = %{
      response_type: "code",
      client_id: client_id(),
      scope: "ZohoBooks.fullaccess.all",
      access_type: "offline",
      state: state.token,
      redirect_uri: redirect_uri()
    }

    @oauth_authorize_url <> "?" <> URI.encode_query(params)
  end

  @doc """
  Verify a state token and consume it (single-use).
  """
  @spec verify_state(String.t()) :: {:ok, binary()} | {:error, :invalid_state}
  def verify_state(token) when is_binary(token) do
    case OauthState
         |> Ash.Query.for_read(:by_token, %{token: token})
         |> Ash.read(authorize?: false) do
      {:ok, [%OauthState{purpose: :zoho_books} = state]} ->
        Ash.destroy!(state, authorize?: false)
        {:ok, state.tenant_id}

      _ ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Exchange a code for tokens, probe the tenant's first organization,
  and upsert an AccountingConnection. Reconnects (existing row) update
  the tokens; first connects create a new row.
  """
  @spec complete_onboarding(Tenant.t(), String.t()) ::
          {:ok, AccountingConnection.t()} | {:error, term()}
  def complete_onboarding(%Tenant{id: tenant_id}, code) when is_binary(code) do
    with {:ok, %{access_token: at, refresh_token: rt, expires_in: secs}} <-
           ZohoClient.impl().exchange_oauth_code(code, redirect_uri()),
         {:ok, %{"organizations" => [%{"organization_id" => org_id} | _]}} <-
           ZohoClient.impl().api_get(at, "", "/organizations", []) do
      expires_at = DateTime.add(DateTime.utc_now(), secs, :second)
      upsert_connection(tenant_id, org_id, at, rt, expires_at)
    end
  end

  @doc "True when Zoho OAuth credentials are configured on the platform."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:driveway_os, :zoho_client_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  # --- Helpers ---

  defp upsert_connection(tenant_id, org_id, access_token, refresh_token, expires_at) do
    case DrivewayOS.Platform.get_accounting_connection(tenant_id, :zoho_books) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:refresh_tokens, %{
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at
        })
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, updated} ->
            updated
            |> Ash.Changeset.for_update(:resume, %{})
            |> Ash.update(authorize?: false)

          err ->
            err
        end

      {:error, :not_found} ->
        AccountingConnection
        |> Ash.Changeset.for_create(:connect, %{
          tenant_id: tenant_id,
          provider: :zoho_books,
          external_org_id: org_id,
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at,
          region: "com"
        })
        |> Ash.create(authorize?: false)
    end
  end

  defp client_id, do: Application.fetch_env!(:driveway_os, :zoho_client_id)

  defp redirect_uri do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        port = endpoint_port() || 4000
        {"http", ":#{port}"}
      else
        {"https", ""}
      end

    "#{scheme}://#{host}#{port_suffix}/onboarding/zoho/callback"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
```

- [ ] **Step 4: Re-run the test**

```bash
mix test test/driveway_os/accounting/oauth_test.exs
```

Expected: 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/accounting/oauth.ex \
        test/driveway_os/accounting/oauth_test.exs

git commit -m "Accounting.OAuth: Zoho URL/state/exchange helper (mirrors Billing.StripeConnect)"
```

---

## Task 8: `Onboarding.Providers.ZohoBooks` adapter

**Files:**
- Create: `lib/driveway_os/onboarding/providers/zoho_books.ex`
- Modify: `lib/driveway_os/onboarding/registry.ex` (register provider)
- Test: `test/driveway_os/onboarding/providers/zoho_books_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/onboarding/providers/zoho_books_test.exs`:

```elixir
defmodule DrivewayOS.Onboarding.Providers.ZohoBooksTest do
  @moduledoc """
  Pin the Provider behaviour conformance for the Zoho Books adapter.
  The adapter is thin — `Accounting.OAuth.configured?/0` and
  `Platform.get_accounting_connection/2` do the heavy lifting.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Providers.ZohoBooks, as: Provider
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ozb-#{System.unique_integer([:positive])}",
        display_name: "Zoho Adapter Test",
        admin_email: "ozb-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :zoho_books" do
    assert Provider.id() == :zoho_books
  end

  test "category/0 is :accounting" do
    assert Provider.category() == :accounting
  end

  test "display/0 returns the canonical card copy" do
    d = Provider.display()
    assert d.title == "Sync to Zoho Books"
    assert d.cta_label == "Connect Zoho"
    assert d.href == "/onboarding/zoho/start"
  end

  test "configured?/0 mirrors the OAuth helper" do
    assert Provider.configured?()
  end

  test "setup_complete?/1 false when no AccountingConnection exists", ctx do
    refute Provider.setup_complete?(ctx.tenant)
  end

  test "setup_complete?/1 true when an AccountingConnection has tokens", ctx do
    {:ok, _} =
      AccountingConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :zoho_books,
        external_org_id: "999",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        region: "com"
      })
      |> Ash.create(authorize?: false)

    assert Provider.setup_complete?(ctx.tenant)
  end

  test "provision/2 returns {:error, :hosted_required} (Zoho is OAuth-redirect)", ctx do
    assert {:error, :hosted_required} = Provider.provision(ctx.tenant, %{})
  end

  describe "affiliate_config/0" do
    test "ref_id from app env" do
      original = Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
      Application.put_env(:driveway_os, :zoho_affiliate_ref_id, "drivewayos-affil")
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: "drivewayos-affil"} = Provider.affiliate_config()
    end

    test "ref_id nil when env unset" do
      original = Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
      Application.put_env(:driveway_os, :zoho_affiliate_ref_id, nil)
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: nil} = Provider.affiliate_config()
    end
  end

  test "tenant_perk/0 returns nil — no perk shipping in V1" do
    assert Provider.tenant_perk() == nil
  end
end
```

- [ ] **Step 2: Run the test — should fail**

```bash
mix test test/driveway_os/onboarding/providers/zoho_books_test.exs
```

Expected: undefined `DrivewayOS.Onboarding.Providers.ZohoBooks`.

- [ ] **Step 3: Implement the adapter**

Create `lib/driveway_os/onboarding/providers/zoho_books.ex`:

```elixir
defmodule DrivewayOS.Onboarding.Providers.ZohoBooks do
  @moduledoc """
  Onboarding adapter for Zoho Books. Hosted-redirect OAuth provider —
  `provision/2` returns `{:error, :hosted_required}`; the wizard
  routes the operator to `display.href` (= `/onboarding/zoho/start`)
  instead.

  Mirrors `Onboarding.Providers.StripeConnect`'s shape exactly. The
  underlying OAuth + API + sync logic lives in `DrivewayOS.Accounting`;
  this module just answers the questions the `Onboarding.Provider`
  behaviour asks.
  """
  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Accounting.OAuth
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{AccountingConnection, Tenant}

  @impl true
  def id, do: :zoho_books

  @impl true
  def category, do: :accounting

  @impl true
  def display do
    %{
      title: "Sync to Zoho Books",
      blurb:
        "Auto-create invoices in Zoho Books when customers pay. " <>
          "Tax-time exports without manual entry.",
      cta_label: "Connect Zoho",
      href: "/onboarding/zoho/start"
    }
  end

  @impl true
  def configured?, do: OAuth.configured?()

  @impl true
  def setup_complete?(%Tenant{id: tid}) do
    case Platform.get_accounting_connection(tid, :zoho_books) do
      {:ok, %AccountingConnection{access_token: at}} when is_binary(at) -> true
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
end
```

- [ ] **Step 4: Register in the Registry**

Edit `lib/driveway_os/onboarding/registry.ex`. Find:

```elixir
  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect,
    DrivewayOS.Onboarding.Providers.Postmark
  ]
```

Add `ZohoBooks` to the list:

```elixir
  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect,
    DrivewayOS.Onboarding.Providers.Postmark,
    DrivewayOS.Onboarding.Providers.ZohoBooks
  ]
```

- [ ] **Step 5: Run the test**

```bash
mix test test/driveway_os/onboarding/providers/zoho_books_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 6: Run the full suite to ensure Registry change doesn't regress**

```bash
mix test
```

Expected: 0 failures. Registry tests should still pass — `fetch(:zoho_books)` now resolves.

- [ ] **Step 7: Commit**

```bash
git add lib/driveway_os/onboarding/providers/zoho_books.ex \
        lib/driveway_os/onboarding/registry.ex \
        test/driveway_os/onboarding/providers/zoho_books_test.exs

git commit -m "Onboarding.Providers.ZohoBooks: adapter + Registry registration"
```

---

## Task 9: `ZohoOauthController` + routes

**Files:**
- Create: `lib/driveway_os_web/controllers/zoho_oauth_controller.ex`
- Modify: `lib/driveway_os_web/router.ex`
- Test: `test/driveway_os_web/controllers/zoho_oauth_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os_web/controllers/zoho_oauth_controller_test.exs`:

```elixir
defmodule DrivewayOSWeb.ZohoOauthControllerTest do
  @moduledoc """
  Pin the Zoho OAuth controller's contract: start logs :click +
  redirects (with affiliate ref tag when configured), callback
  exchanges code + creates AccountingConnection + logs :provisioned,
  errors return 400.

  Mirrors `stripe_onboarding_controller_test.exs` setup pattern —
  JWT-tokened admin session on the tenant subdomain.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{AccountingConnection, TenantReferral}

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "zo-#{System.unique_integer([:positive])}",
        display_name: "Zoho Controller Test",
        admin_email: "zo-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    # Use whatever existing helper sign-in pattern stripe_onboarding_controller_test
    # uses (likely `log_in_admin/2` or session put via JWT). Copy that
    # helper into this file.
    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)

    %{conn: conn, tenant: tenant, admin: admin}
  end

  describe "GET /onboarding/zoho/start" do
    test "redirects to Zoho OAuth and logs :click", ctx do
      conn = get(ctx.conn, "/onboarding/zoho/start")

      url = redirected_to(conn, 302)
      assert url =~ "accounts.zoho.com/oauth/v2/auth"
      assert url =~ "state="

      {:ok, all} = Ash.read(TenantReferral, authorize?: false)
      [event] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
      assert event.provider == :zoho_books
      assert event.event_type == :click
    end

    test "appends affiliate ref when ZOHO_AFFILIATE_REF_ID is set", ctx do
      original = Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
      Application.put_env(:driveway_os, :zoho_affiliate_ref_id, "myref")
      on_exit(fn -> Application.put_env(:driveway_os, :zoho_affiliate_ref_id, original) end)

      conn = get(ctx.conn, "/onboarding/zoho/start")
      url = redirected_to(conn, 302)
      assert url =~ "ref=myref"
    end

    test "non-admin gets bounced to /admin (or root)", ctx do
      # Sign in as non-admin customer instead — adapt to whatever
      # the existing stripe_onboarding test does for this case.
      # If no such test exists, skip this case.
      :ok
    end
  end

  describe "GET /onboarding/zoho/callback" do
    test "exchanges code, creates AccountingConnection, logs :provisioned, redirects to /admin/integrations",
         ctx do
      # Issue a state token via OAuth.oauth_url_for/1 first to get a
      # valid token paired with this tenant.
      url = DrivewayOS.Accounting.OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      expect(ZohoClient.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-cb", refresh_token: "rt-cb", expires_in: 3600}}
      end)

      expect(ZohoClient.Mock, :api_get, fn _, _, "/organizations", _ ->
        {:ok, %{"organizations" => [%{"organization_id" => "12345"}]}}
      end)

      conn = get(ctx.conn, "/onboarding/zoho/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn, 302) =~ "/admin/integrations"

      {:ok, conn_row} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
      assert conn_row.access_token == "at-cb"
      assert conn_row.external_org_id == "12345"

      {:ok, all_events} = Ash.read(TenantReferral, authorize?: false)

      provisioned =
        all_events
        |> Enum.filter(&(&1.tenant_id == ctx.tenant.id and &1.event_type == :provisioned))

      assert [_event] = provisioned
    end

    test "returns 400 on invalid state", ctx do
      conn = get(ctx.conn, "/onboarding/zoho/callback?code=x&state=not-a-real-token")
      assert response(conn, 400) =~ "Zoho onboarding failed"
    end

    test "returns 400 on missing params", ctx do
      conn = get(ctx.conn, "/onboarding/zoho/callback")
      assert response(conn, 400) =~ "Missing"
    end
  end

  defp sign_in_admin_for_tenant(_conn, _tenant, _admin) do
    # Copy from test/driveway_os_web/controllers/stripe_onboarding_controller_test.exs
    # — exact helper to reuse depends on what's already there. Adapt
    # at implementation time.
    raise "Implement using existing stripe controller test's auth helper"
  end
end
```

- [ ] **Step 2: Run the test — should fail**

```bash
mix test test/driveway_os_web/controllers/zoho_oauth_controller_test.exs
```

Expected: undefined module / route not found.

- [ ] **Step 3: Implement the controller**

Create `lib/driveway_os_web/controllers/zoho_oauth_controller.ex`:

```elixir
defmodule DrivewayOSWeb.ZohoOauthController do
  @moduledoc """
  Zoho Books OAuth endpoints. Mirrors `StripeOnboardingController`.

      GET /onboarding/zoho/start    — admin-only, redirects to Zoho OAuth
      GET /onboarding/zoho/callback — Zoho redirects here after auth

  The callback runs on the marketing host (where Zoho sends them
  back), not the tenant subdomain — we resolve which tenant via
  the state token.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Accounting.OAuth
  alias DrivewayOS.Onboarding.Affiliate
  alias DrivewayOS.Platform

  def start(conn, _params) do
    cond do
      is_nil(conn.assigns[:current_tenant]) ->
        conn |> redirect(to: ~p"/") |> halt()

      is_nil(conn.assigns[:current_customer]) ->
        conn |> redirect(to: ~p"/sign-in") |> halt()

      conn.assigns.current_customer.role != :admin ->
        conn |> redirect(to: ~p"/") |> halt()

      not OAuth.configured?() ->
        conn
        |> put_flash(
          :error,
          "Zoho Books isn't configured on this server yet. " <>
            "Ask the platform admin to set ZOHO_CLIENT_ID."
        )
        |> redirect(to: ~p"/admin")
        |> halt()

      true ->
        url =
          conn.assigns.current_tenant
          |> OAuth.oauth_url_for()
          |> Affiliate.tag_url(:zoho_books)

        :ok =
          Affiliate.log_event(
            conn.assigns.current_tenant,
            :zoho_books,
            :click,
            %{wizard_step: "accounting"}
          )

        redirect(conn, external: url)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, tenant_id} <- OAuth.verify_state(state),
         {:ok, tenant} <- Ash.get(Platform.Tenant, tenant_id, authorize?: false),
         {:ok, accounting_conn} <- OAuth.complete_onboarding(tenant, code) do
      :ok =
        Affiliate.log_event(
          tenant,
          :zoho_books,
          :provisioned,
          %{external_org_id: accounting_conn.external_org_id}
        )

      redirect(conn, external: tenant_integrations_url(tenant))
    else
      _ -> send_resp(conn, 400, "Zoho onboarding failed.")
    end
  end

  def callback(conn, _params), do: send_resp(conn, 400, "Missing code/state.")

  # --- Helpers ---

  defp tenant_integrations_url(tenant) do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        port = endpoint_port() || 4000
        {"http", ":#{port}"}
      else
        {"https", ""}
      end

    "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}/admin/integrations"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
```

- [ ] **Step 4: Add routes**

Edit `lib/driveway_os_web/router.ex`. Find the existing `/onboarding/stripe/*` routes (likely in the same scope as other admin routes — see existing Stripe wiring). Add:

```elixir
    get "/onboarding/zoho/start", ZohoOauthController, :start
    get "/onboarding/zoho/callback", ZohoOauthController, :callback
```

The `/admin/integrations` route lands in Task 10.

- [ ] **Step 5: Re-run the test**

```bash
mix test test/driveway_os_web/controllers/zoho_oauth_controller_test.exs
```

Expected: 5 tests (4 + 1 admin-bounce that may be skipped), 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os_web/controllers/zoho_oauth_controller.ex \
        lib/driveway_os_web/router.ex \
        test/driveway_os_web/controllers/zoho_oauth_controller_test.exs

git commit -m "ZohoOauthController: start/callback + Affiliate.tag_url first prod caller"
```

---

## Task 10: Hook `Accounting.SyncWorker` into `Appointment.mark_paid`

**Files:**
- Modify: `lib/driveway_os/scheduling/appointment.ex` (add Ash change to `:mark_paid` action)
- Test: `test/driveway_os/scheduling/appointment_test.exs` (extend OR add to a sync-trigger test file)

- [ ] **Step 1: Find the `mark_paid` action and write the failing test**

Edit (or create) a test that exercises the `:mark_paid` action and asserts an Oban job lands in the queue:

Add to `test/driveway_os/scheduling/appointment_test.exs` (or whatever existing test file covers Appointment) — wrap in a new describe block:

```elixir
  describe ":mark_paid enqueues SyncWorker" do
    use Oban.Testing, repo: DrivewayOS.Repo

    setup do
      {:ok, %{tenant: tenant, admin: admin}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "mp-#{System.unique_integer([:positive])}",
          display_name: "Mark Paid Test",
          admin_email: "mp-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant, admin: admin}
    end

    test "enqueues SyncWorker with tenant_id + appointment_id", ctx do
      appt = create_pending_appointment!(ctx.tenant.id, ctx.admin.id)

      appt
      |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: "pi_test_123"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      assert_enqueued(
        worker: DrivewayOS.Accounting.SyncWorker,
        args: %{"tenant_id" => ctx.tenant.id, "appointment_id" => appt.id}
      )
    end

    defp create_pending_appointment!(_tenant_id, _admin_id) do
      raise "Implement using existing test helper for Appointment in :pending state"
    end
  end
```

- [ ] **Step 2: Run the test — should fail (no enqueue happens yet)**

```bash
mix test test/driveway_os/scheduling/appointment_test.exs --only mark_paid
```

Expected: `assert_enqueued` fails — no Oban job in the queue.

- [ ] **Step 3: Add the enqueue change to the Ash action**

Edit `lib/driveway_os/scheduling/appointment.ex`. Find:

```elixir
    update :mark_paid do
      argument :stripe_payment_intent_id, :string

      change set_attribute(:payment_status, :paid)
      change set_attribute(:paid_at, &DateTime.utc_now/0)
      change set_attribute(:status, :confirmed)
      change set_attribute(:stripe_payment_intent_id, arg(:stripe_payment_intent_id))
    end
```

Append a new `change` that enqueues the worker after the action commits:

```elixir
    update :mark_paid do
      argument :stripe_payment_intent_id, :string

      change set_attribute(:payment_status, :paid)
      change set_attribute(:paid_at, &DateTime.utc_now/0)
      change set_attribute(:status, :confirmed)
      change set_attribute(:stripe_payment_intent_id, arg(:stripe_payment_intent_id))

      # Phase 3: kick off accounting sync for this paid appointment.
      # Wrapped in `after_action` so it only fires on success. Errors
      # in Oban.insert are swallowed — never block the payment flow.
      change after_action(fn _changeset, appointment, _ctx ->
               try do
                 DrivewayOS.Accounting.SyncWorker.new(%{
                   "tenant_id" => appointment.tenant_id,
                   "appointment_id" => appointment.id
                 })
                 |> Oban.insert()
               rescue
                 e ->
                   require Logger
                   Logger.warning("Accounting sync enqueue failed: #{Exception.message(e)}")
               end

               {:ok, appointment}
             end)
    end
```

The `appointment.tenant_id` access works because `Appointment` is tenant-scoped — every row carries its `tenant_id`.

- [ ] **Step 4: Re-run the test**

```bash
mix test test/driveway_os/scheduling/appointment_test.exs --only mark_paid
```

Expected: passing.

- [ ] **Step 5: Run full suite to confirm no regression in Stripe webhook or other mark_paid call sites**

```bash
mix test
```

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/scheduling/appointment.ex \
        test/driveway_os/scheduling/appointment_test.exs

git commit -m "Appointment.mark_paid: enqueue Accounting.SyncWorker after action commits"
```

---

## Task 11: `IntegrationsLive` (`/admin/integrations`)

**Files:**
- Create: `lib/driveway_os_web/live/admin/integrations_live.ex`
- Modify: `lib/driveway_os_web/router.ex` (add route)
- Test: `test/driveway_os_web/live/admin/integrations_live_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os_web/live/admin/integrations_live_test.exs`:

```elixir
defmodule DrivewayOSWeb.Admin.IntegrationsLiveTest do
  @moduledoc """
  Tenant admin → integrations page. Lists connected integrations
  with pause/resume/disconnect buttons. Empty state shows a "no
  integrations connected" message.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.AccountingConnection

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "il-#{System.unique_integer([:positive])}",
        display_name: "Integrations LV Test",
        admin_email: "il-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)

    %{conn: conn, tenant: tenant, admin: admin}
  end

  test "redirects unauthenticated users to /sign-in", _ctx do
    conn = build_conn() |> put_host("integrations-lv-1.lvh.me")
    assert {:error, {:redirect, %{to: "/sign-in" <> _}}} = live(conn, "/admin/integrations")
  end

  test "empty state when tenant has no AccountingConnections", ctx do
    {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
    assert html =~ "No integrations connected yet"
  end

  test "lists Zoho Books row when an active connection exists", ctx do
    connect_zoho!(ctx.tenant.id)

    {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
    assert html =~ "Zoho Books"
    assert html =~ "Active"
    assert html =~ "Pause"
    assert html =~ "Disconnect"
  end

  test "shows Paused status when auto_sync_enabled is false", ctx do
    conn_row = connect_zoho!(ctx.tenant.id)
    conn_row |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)

    {:ok, _view, html} = live(ctx.conn, "/admin/integrations")
    assert html =~ "Paused"
    assert html =~ "Resume"
  end

  test "Pause button toggles auto_sync_enabled to false", ctx do
    connect_zoho!(ctx.tenant.id)

    {:ok, view, _html} = live(ctx.conn, "/admin/integrations")
    view |> element("button", "Pause") |> render_click()

    {:ok, refreshed} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    refute refreshed.auto_sync_enabled
  end

  test "Disconnect button clears tokens", ctx do
    connect_zoho!(ctx.tenant.id)

    {:ok, view, _html} = live(ctx.conn, "/admin/integrations")
    view |> element("button", "Disconnect") |> render_click()

    {:ok, refreshed} = Platform.get_accounting_connection(ctx.tenant.id, :zoho_books)
    assert refreshed.access_token == nil
    assert refreshed.disconnected_at != nil
  end

  defp connect_zoho!(tenant_id) do
    AccountingConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :zoho_books,
      external_org_id: "999",
      access_token: "at",
      refresh_token: "rt",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    })
    |> Ash.create!(authorize?: false)
  end

  defp sign_in_admin_for_tenant(_conn, _tenant, _admin) do
    raise "Implement using existing admin LV test sign-in helper " <>
            "(see customer_detail_live_test.exs or appointments_live_test.exs)"
  end
end
```

- [ ] **Step 2: Run the test — should fail**

```bash
mix test test/driveway_os_web/live/admin/integrations_live_test.exs
```

Expected: route not found, undefined LiveView module.

- [ ] **Step 3: Implement the LiveView**

Create `lib/driveway_os_web/live/admin/integrations_live.ex`:

```elixir
defmodule DrivewayOSWeb.Admin.IntegrationsLive do
  @moduledoc """
  Tenant admin → integrations page at `/admin/integrations`.

  Lists every AccountingConnection row for the current tenant with
  status badge + pause/resume/disconnect buttons. V1 only has Zoho
  Books rows; Phase 4 adds QuickBooks rows automatically once its
  provider lands.

  Auth: Customer with role `:admin` in the current tenant.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Platform.AccountingConnection

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      true ->
        {:ok, load_connections(socket)}
    end
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket) do
    {:ok, conn} = Ash.get(AccountingConnection, id, authorize?: false)
    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)
    {:noreply, load_connections(socket)}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    {:ok, conn} = Ash.get(AccountingConnection, id, authorize?: false)
    conn |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update!(authorize?: false)
    {:noreply, load_connections(socket)}
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    {:ok, conn} = Ash.get(AccountingConnection, id, authorize?: false)
    conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)
    {:noreply, load_connections(socket)}
  end

  defp load_connections(socket) do
    tenant_id = socket.assigns.current_tenant.id

    {:ok, connections} =
      AccountingConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    assign(socket, :connections, connections)
  end

  defp status(%AccountingConnection{disconnected_at: dt}) when not is_nil(dt), do: "Disconnected"
  defp status(%AccountingConnection{auto_sync_enabled: false}), do: "Paused"
  defp status(%AccountingConnection{last_sync_error: err}) when is_binary(err), do: "Error"
  defp status(_), do: "Active"

  defp provider_label(:zoho_books), do: "Zoho Books"
  defp provider_label(p), do: p |> Atom.to_string() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold mb-4">Integrations</h1>

      <%= if @connections == [] do %>
        <div class="bg-base-200 rounded-lg p-8 text-center text-base-content/70">
          <p>No integrations connected yet.</p>
          <p class="text-sm mt-2">
            Connect from the dashboard checklist on
            <.link navigate={~p"/admin"} class="link link-primary">/admin</.link>.
          </p>
        </div>
      <% else %>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Provider</th>
                <th>Status</th>
                <th>Connected</th>
                <th>Last sync</th>
                <th>Last error</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for conn <- @connections do %>
                <tr>
                  <td>{provider_label(conn.provider)}</td>
                  <td>{status(conn)}</td>
                  <td>{conn.connected_at && Calendar.strftime(conn.connected_at, "%Y-%m-%d")}</td>
                  <td>{conn.last_sync_at && Calendar.strftime(conn.last_sync_at, "%Y-%m-%d %H:%M")}</td>
                  <td class="text-error text-sm">{conn.last_sync_error}</td>
                  <td class="flex gap-2">
                    <%= if conn.auto_sync_enabled do %>
                      <button phx-click="pause" phx-value-id={conn.id} class="btn btn-sm">
                        Pause
                      </button>
                    <% else %>
                      <%= if is_nil(conn.disconnected_at) do %>
                        <button phx-click="resume" phx-value-id={conn.id} class="btn btn-sm btn-primary">
                          Resume
                        </button>
                      <% end %>
                    <% end %>
                    <button phx-click="disconnect" phx-value-id={conn.id} class="btn btn-sm btn-error">
                      Disconnect
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end
end
```

- [ ] **Step 4: Add the route**

Edit `lib/driveway_os_web/router.ex`. Find the cluster of `/admin/*` routes (around `Admin.BrandingLive`, `Admin.CustomDomainsLive`, etc.) and add:

```elixir
    live "/admin/integrations", Admin.IntegrationsLive
```

- [ ] **Step 5: Re-run the test**

```bash
mix test test/driveway_os_web/live/admin/integrations_live_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os_web/live/admin/integrations_live.ex \
        lib/driveway_os_web/router.ex \
        test/driveway_os_web/live/admin/integrations_live_test.exs

git commit -m "IntegrationsLive: /admin/integrations with pause/resume/disconnect"
```

---

## Task 12: Runtime config + DEPLOY.md + final verification

**Files:**
- Modify: `config/runtime.exs`
- Modify: `DEPLOY.md`
- (config/test.exs and config/config.exs already touched in Task 4)

- [ ] **Step 1: Add runtime env reads**

Edit `config/runtime.exs`. Find the existing `if config_env() != :test do` block where Stripe + Postmark env vars are read. Extend the keyword list:

```elixir
if config_env() != :test do
  config :driveway_os,
    stripe_client_id: System.get_env("STRIPE_CLIENT_ID") || "",
    stripe_secret_key: System.get_env("STRIPE_SECRET_KEY") || "",
    stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "",
    postmark_account_token: System.get_env("POSTMARK_ACCOUNT_TOKEN") || "",
    postmark_affiliate_ref_id: System.get_env("POSTMARK_AFFILIATE_REF_ID"),
    zoho_client_id: System.get_env("ZOHO_CLIENT_ID") || "",
    zoho_client_secret: System.get_env("ZOHO_CLIENT_SECRET") || "",
    zoho_affiliate_ref_id: System.get_env("ZOHO_AFFILIATE_REF_ID")
end
```

(Note: `zoho_client_id` and `zoho_client_secret` use `|| ""` like Stripe — empty string means "not configured." `zoho_affiliate_ref_id` uses `nil` like `postmark_affiliate_ref_id` — `nil` means "no affiliate enrolled.")

- [ ] **Step 2: Update DEPLOY.md**

Edit `DEPLOY.md`. Find the per-tenant integrations env-var table. Add three rows after the existing Postmark rows:

```markdown
| `ZOHO_CLIENT_ID` | Zoho Books OAuth client id (one per platform — every tenant uses the same one). Get from Zoho's API console at https://api-console.zoho.com. |
| `ZOHO_CLIENT_SECRET` | Paired with ZOHO_CLIENT_ID. |
| `ZOHO_AFFILIATE_REF_ID` | Optional. Platform-level Zoho affiliate referral code; appended to outbound Zoho OAuth URLs as `?ref=<value>`. Leave unset until enrolled in Zoho's referral program. |
```

- [ ] **Step 3: Run the full suite**

```bash
mix test
```

Expected: 0 failures.

- [ ] **Step 4: Verify clean working tree**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 5: Commit config + push**

```bash
git add config/runtime.exs DEPLOY.md

git commit -m "Config: ZOHO_CLIENT_ID + ZOHO_CLIENT_SECRET + ZOHO_AFFILIATE_REF_ID"

git push origin main
```

Expected: push succeeds. Phase 3's commits are visible on `origin/main`.

---

## Self-review

**Spec coverage:**

| Spec section | Covered by task |
|---|---|
| Constraints / V1 = Zoho Books only | All tasks (no QBO impl shipped) |
| Constraints / port + multi-tenantify | Tasks 3, 5, 6 |
| Constraints / `Platform.AccountingConnection` resource | Task 1 |
| Constraints / payment-completed sync trigger | Task 10 |
| Constraints / `auto_sync_enabled` toggle | Task 1 (resource action) + Task 6 (worker check) + Task 11 (UI) |
| Constraints / disconnect = clear tokens, keep row | Task 1 (action) + Task 11 (UI button) |
| Constraints / token-revoke = auto-pause + email | Task 6 (`handle_auth_failure`) |
| Constraints / `.com` region hardcoded, column reserved | Task 1 (column) + Task 4 (constants) + Task 7 (URL) |
| Constraints / one-way sync only | Task 6 (worker only writes; no read paths) |
| Architecture / Module layout — AccountingConnection | Task 1 |
| Architecture / Module layout — Onboarding adapter | Task 8 |
| Architecture / Module layout — OAuth controller | Task 9 |
| Architecture / Module layout — IntegrationsLive | Task 11 |
| Architecture / Ported modules — provider behaviour | Task 3 |
| Architecture / Ported modules — facade | Task 3 |
| Architecture / Ported modules — ZohoBooks impl | Task 5 |
| Architecture / Ported modules — SyncWorker | Task 6 |
| Architecture / Modified — Registry | Task 8 |
| Architecture / Modified — Appointment.mark_paid | Task 10 |
| Architecture / Modified — router | Tasks 9 + 11 |
| Architecture / Modified — runtime/test/config + DEPLOY | Tasks 4 + 12 |
| Architecture / Data model | Task 1 |
| Architecture / Adapter | Task 8 |
| Architecture / OAuth flow | Task 7 (helper) + Task 9 (controller) |
| Architecture / SyncWorker | Task 6 |
| Architecture / Wizard placement (no Steps.Accounting) | Task 8 (Registry only) |
| Architecture / Affiliate ties — first tag_url caller | Task 9 |
| Architecture / Affiliate ties — :click + :provisioned events | Task 9 |
| Spec deviation #1 — no Payment resource → Appointment hook | Task 10 |
| Spec deviation #2 — appointment_id not payment_id | Task 6 |
| Spec deviation #3 — reuse OauthState with extended :purpose | Task 2 |
| Spec deviation #4 — `platform_*` table prefix | Task 1 |
| Out of scope (QBO, multi-region, two-way sync, bulk historical, encryption) | Confirmed not in any task |

**Type / signature consistency check:**

- `AccountingConnection` actions (`:connect`, `:refresh_tokens`, `:record_sync_success`, `:record_sync_error`, `:disconnect`, `:pause`, `:resume`) used identically across Tasks 1, 6, 7, 11. ✓
- `Provider.create_contact/2`, `find_contact_by_email/2`, `create_invoice/2`, `record_payment/3`, `get_invoice/2` — all take `connection` first; consistent across Tasks 3 (behaviour), 5 (impl), 6 (facade caller). ✓
- `ZohoClient` callbacks (`exchange_oauth_code/2`, `refresh_access_token/2`, `api_get/4`, `api_post/4`) — same signatures in Tasks 4 (defn), 5 (caller), 6 (caller), 7 (caller). ✓
- `OAuth.oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`, `configured?/0` — same signatures in Tasks 7 (defn), 8 (caller), 9 (caller). ✓
- `Platform.get_accounting_connection/2` returns `{:ok, conn} | {:error, :not_found}`; `get_active_accounting_connection/2` returns `{:ok, conn} | {:error, :no_active_connection}` — consistent across Tasks 1 (defn), 6, 7, 8, 11. ✓
- SyncWorker args shape `%{"tenant_id" => ..., "appointment_id" => ...}` — consistent across Tasks 6 (worker) + 10 (enqueue site). ✓
- `Affiliate.log_event/4` signature `(tenant, provider_id, event_type, metadata)` — consistent with Phase 2; used in Task 9. ✓

**Placeholder scan:**
- Two helper-stub raises in test files (`create_paid_appointment!`, `sign_in_admin_for_tenant`, `create_pending_appointment!`). Each has an explicit comment pointing to the existing test file the implementer should copy from. Acceptable — the helper code lives in copy-target files; pasting it into test files keeps tests readable as standalone, which is a valid trade-off vs. shared-helper indirection. The implementer must wire these up at execution time.
- No "TBD" / "TODO" / "fill in details" / "similar to Task N (without code)".
- Every code step has actual code; every command step has actual command + expected output.

**Bite-size check:**
- Each step is one concrete action.
- Each task ends in a commit.
- Twelve tasks, each ~5-15 minutes for an engineer with the context.

If you find issues during execution, stop and ask — don't guess.
