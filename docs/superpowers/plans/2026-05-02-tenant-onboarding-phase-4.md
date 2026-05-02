# Tenant Onboarding Phase 4 — Square (payment, second-of-category) + multi-card picker UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Square as the second payment provider end-to-end (OAuth + Checkout + webhook + dual-routing in the booking flow). Plus the generic multi-card picker UI machinery in `Steps.Payment` so the wizard's Payment step renders N cards, and the IntegrationsLive merge to surface PaymentConnection rows alongside AccountingConnection rows.

**Architecture:** Mirror Phase 3's accounting integration shape but for payment. New `Platform.PaymentConnection` Ash resource (parallel to `AccountingConnection`). New `Square.OAuth` + `Square.Client` + `Square.Charge` modules (parallel to Phase 3's `Accounting.OAuth` + `Accounting.ZohoClient`). `SquareOauthController` mirrors `ZohoOauthController`. `SquareWebhookController` mirrors `StripeWebhookController` (already-existing raw-body plumbing via `CacheBodyReader` works as-is). Booking flow's existing `do_post_booking/5` in `BookingLive` gets a third `cond` branch (Stripe → Stripe Checkout, Square → Square Payment Link, neither → confirmation email). UI surfaces follow `design-system/MASTER.md` + ui-ux-pro-max rules.

**Tech Stack:** Elixir 1.18 / Phoenix LiveView 1.1 / Ash 3.24 / AshPostgres 2.9 / Oban / Req (HTTP) / Mox (test mocking). Tests use ExUnit with `DrivewayOS.DataCase` and `DrivewayOSWeb.ConnCase`. Standard test command: `mix test`.

**Spec:** `docs/superpowers/specs/2026-05-02-tenant-onboarding-phase-4-design.md` — read the "Constraints + decisions" + "Architecture" sections before starting.

**Phase 1-3 (already shipped):**
- Phase 1: `docs/superpowers/plans/2026-04-29-tenant-onboarding-phase-1.md` — wizard, Stripe Connect (Tenant.stripe_account_id), Postmark, BookingLive's `do_post_booking/5` Stripe Checkout call site at `lib/driveway_os_web/live/booking_live.ex:880-902`.
- Phase 2: `docs/superpowers/plans/2026-05-02-tenant-onboarding-phase-2.md` — `Onboarding.Affiliate` module + `Platform.TenantReferral`.
- Phase 3: `docs/superpowers/plans/2026-05-02-tenant-onboarding-phase-3.md` — `Platform.AccountingConnection` resource shape (mirror for `PaymentConnection`), `Accounting.OAuth` shape, `Accounting.ZohoClient` shape, `ZohoOauthController` shape, `IntegrationsLive` shape (extend in Task 12). Phase 3's M1 fix (`:reconnect` action with `disconnected_at: nil`) — preempt by including `:reconnect` in the Phase 4 PaymentConnection resource from day one.

**Branch policy:** Execute on `main`. Commit after each task. Push to origin after Task 14 (final verification).

---

## Spec deviations (decided during plan-writing)

Reading the codebase before writing the plan surfaced four facts the spec couldn't fully anticipate.

1. **`OauthState` `:purpose` constraint extension generates no migration.** Phase 3 Task 2 already proved this — Ash enforces `one_of` atom enums at the changeset layer, not a Postgres CHECK. The `mix ash_postgres.generate_migrations --name extend_oauth_state_purpose_for_square` call will report "No changes detected" and that's correct. Plan acknowledges; no migration file produced for Task 2.

2. **Booking flow's dual-routing call site is `lib/driveway_os_web/live/booking_live.ex:880-902` (`do_post_booking/5`).** Currently a 2-branch conditional (`if tenant.stripe_account_id`). Phase 4 expands to a 3-branch `cond` (Stripe → existing path; Square → new `Square.Charge.create_checkout_session/3` path; neither → existing confirmation-email path).

3. **Webhook raw-body plumbing already in place** via `lib/driveway_os_web/cache_body_reader.ex` registered as `Plug.Parsers` body_reader in `endpoint.ex:72`. New `SquareWebhookController` reads `conn.assigns[:raw_body]` exactly like `StripeWebhookController` does — no Plug pipeline changes needed.

4. **Table prefix `platform_payment_connections`** matches the dominant `platform_*` prefix established in Phase 2's deviation #2 (every other platform-tier table prefixes `platform_`).

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `priv/repo/migrations/<ts>_create_platform_payment_connections.exs` | Generated. `platform_payment_connections` table + FK + unique-tenant-provider identity. |
| `priv/repo/migrations/<ts>_add_square_order_id_to_appointments.exs` | Generated. Adds `square_order_id :string` to `appointments`. |
| `lib/driveway_os/platform/payment_connection.ex` | Ash resource. Mirrors Phase 3 `AccountingConnection` shape with payment-flavored field names. |
| `lib/driveway_os/square.ex` | Thin facade module. Aliases the OAuth, Client, Charge submodules. |
| `lib/driveway_os/square/oauth.ex` | Mirrors `Accounting.OAuth`. `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`, `configured?/0`. |
| `lib/driveway_os/square/client.ex` | `@behaviour` for HTTP layer + `impl/0` + `defdelegate`s. 5 callbacks: `exchange_oauth_code/2`, `refresh_access_token/1`, `api_get/3`, `api_post/3`, `create_payment_link/2`. |
| `lib/driveway_os/square/client/http.ex` | Concrete Req-based impl. Reads OAuth + API base URLs from app env at runtime (`:square_oauth_base`, `:square_api_base`) — sandbox/prod toggle. |
| `lib/driveway_os/square/charge.ex` | Square Checkout (Payment Links) session creation. `create_checkout_session/3` takes `%PaymentConnection{}`, an Appointment, and a redirect URL. Returns `{:ok, %{checkout_url, payment_link_id, order_id}}` or `{:error, term}`. |
| `lib/driveway_os/onboarding/providers/square.ex` | `Onboarding.Provider` adapter. Hosted-redirect — `provision/2` returns `{:error, :hosted_required}`. |
| `lib/driveway_os_web/controllers/square_oauth_controller.ex` | `GET /onboarding/square/start` + `GET /onboarding/square/callback`. Mirrors `ZohoOauthController`. Logs `:click` + `:provisioned` via `Affiliate.log_event/4`. |
| `lib/driveway_os_web/controllers/square_webhook_controller.ex` | `POST /webhooks/square`. HMAC-SHA256 signature verification. On `payment.updated` with `COMPLETED`, looks up Appointment by `square_order_id` and calls `:mark_paid`. |
| `test/driveway_os/platform/payment_connection_test.exs` | Resource CRUD + lifecycle (connect/refresh/reconnect/pause/resume/disconnect). |
| `test/driveway_os/square/client_test.exs` | HTTP behaviour conformance (Mox-stubbed). |
| `test/driveway_os/square/oauth_test.exs` | OAuth URL building, state verification, code exchange. |
| `test/driveway_os/square/charge_test.exs` | Checkout-session creation (Mox-stubbed `Square.Client`). |
| `test/driveway_os/onboarding/providers/square_test.exs` | Provider behaviour conformance + callbacks. |
| `test/driveway_os_web/controllers/square_oauth_controller_test.exs` | Start logs `:click`, callback logs `:provisioned`, error path returns 400. |
| `test/driveway_os_web/controllers/square_webhook_controller_test.exs` | Signature verification + payment.updated event → Appointment.mark_paid. |

**Modified:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform.ex` | Register `PaymentConnection` in domain. Add `Platform.get_payment_connection/2` + `get_active_payment_connection/2` helpers. |
| `lib/driveway_os/platform/oauth_state.ex` | Extend `:purpose` constraint from `[:stripe_connect, :zoho_books]` to `[:stripe_connect, :zoho_books, :square]`. |
| `lib/driveway_os/onboarding/registry.ex` | Add `Providers.Square` to `@providers`. |
| `lib/driveway_os/onboarding/steps/payment.ex` | Generalize `render/1` to iterate `Registry.by_category(:payment)`. Generalize `complete?/1` to "any provider in `:payment` category complete." |
| `lib/driveway_os/scheduling/appointment.ex` | Add `attribute :square_order_id, :string`. Add `:by_square_order_id` read action. Extend `:mark_paid` action's argument set + accept list. |
| `lib/driveway_os_web/live/booking_live.ex` | `do_post_booking/5`: replace the `if tenant.stripe_account_id` 2-branch with a 3-branch `cond` (Stripe / Square / neither). |
| `lib/driveway_os_web/live/admin/integrations_live.ex` | Merge `PaymentConnection` rows alongside `AccountingConnection`. Add Category column. Mobile card-per-row layout below `md:` breakpoint. `aria-live="polite"`. `aria-label` on action buttons. `min-h-[44px]` on action buttons. Generic over resource module via `with_owned_connection/3`. Align borders to MASTER (`border-slate-200`). |
| `lib/driveway_os_web/router.ex` | Add `/onboarding/square/start` + `/onboarding/square/callback` routes. Add `POST /webhooks/square` route. |
| `config/runtime.exs` | Add `square_app_id`, `square_app_secret`, `square_webhook_signature_key`, `square_affiliate_ref_id`, `square_oauth_base`, `square_api_base` env reads. |
| `config/test.exs` | Test placeholders + Mox `:square_client` config. |
| `config/config.exs` | Default `:square_client` to `Square.Client.Http`. |
| `test/test_helper.exs` | `Mox.defmock(DrivewayOS.Square.Client.Mock, for: DrivewayOS.Square.Client)`. |
| `DEPLOY.md` | Add `SQUARE_APP_ID`, `SQUARE_APP_SECRET`, `SQUARE_WEBHOOK_SIGNATURE_KEY`, `SQUARE_AFFILIATE_REF_ID` rows. |

---

## Task 1: `Platform.PaymentConnection` resource + migration + helpers

**Files:**
- Create: `lib/driveway_os/platform/payment_connection.ex`
- Create: `priv/repo/migrations/<ts>_create_platform_payment_connections.exs` (via `mix ash_postgres.generate_migrations`)
- Modify: `lib/driveway_os/platform.ex` (register + helpers)
- Test: `test/driveway_os/platform/payment_connection_test.exs`

- [ ] **Step 1: Write the failing resource test**

Create `test/driveway_os/platform/payment_connection_test.exs`:

```elixir
defmodule DrivewayOS.Platform.PaymentConnectionTest do
  @moduledoc """
  Pin the `Platform.PaymentConnection` contract: per-(tenant, provider)
  OAuth tokens + lifecycle state for payment integrations. Mirrors
  Phase 3's AccountingConnection shape with payment-flavored field
  names. The `:reconnect` action incorporates Phase 3's M1 fix
  preemptively (clears disconnected_at, refreshes tokens, restores
  auto_charge_enabled, sets connected_at to now).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PaymentConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "pc-#{System.unique_integer([:positive])}",
        display_name: "Payment Conn Test",
        admin_email: "pc-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "connect creates a row with auto_charge_enabled true and connected_at set", ctx do
    {:ok, conn} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :square,
        external_merchant_id: "MLR-1",
        access_token: "at-1",
        refresh_token: "rt-1",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)

    assert conn.tenant_id == ctx.tenant.id
    assert conn.provider == :square
    assert conn.access_token == "at-1"
    assert conn.refresh_token == "rt-1"
    assert conn.auto_charge_enabled == true
    assert %DateTime{} = conn.connected_at
    assert conn.disconnected_at == nil
  end

  test "refresh_tokens updates the three token fields", ctx do
    conn = connect_square!(ctx.tenant.id)

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

  test "disconnect clears tokens, sets disconnected_at, pauses charge", ctx do
    conn = connect_square!(ctx.tenant.id)

    {:ok, updated} =
      conn
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update(authorize?: false)

    assert updated.access_token == nil
    assert updated.refresh_token == nil
    assert updated.access_token_expires_at == nil
    assert %DateTime{} = updated.disconnected_at
    assert updated.auto_charge_enabled == false
  end

  test "pause and resume toggle auto_charge_enabled", ctx do
    conn = connect_square!(ctx.tenant.id)
    {:ok, paused} = conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update(authorize?: false)
    refute paused.auto_charge_enabled

    {:ok, resumed} = paused |> Ash.Changeset.for_update(:resume, %{}) |> Ash.update(authorize?: false)
    assert resumed.auto_charge_enabled
  end

  test "record_charge_success sets last_charge_at and clears error", ctx do
    conn = connect_square!(ctx.tenant.id)

    {:ok, with_err} =
      conn
      |> Ash.Changeset.for_update(:record_charge_error, %{last_charge_error: "boom"})
      |> Ash.update(authorize?: false)

    assert with_err.last_charge_error == "boom"

    {:ok, healed} =
      with_err
      |> Ash.Changeset.for_update(:record_charge_success, %{})
      |> Ash.update(authorize?: false)

    assert %DateTime{} = healed.last_charge_at
    assert healed.last_charge_error == nil
  end

  test "reconnect clears disconnected_at, restores active state, updates merchant_id", ctx do
    conn = connect_square!(ctx.tenant.id)

    {:ok, disconnected} =
      conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update(authorize?: false)

    assert %DateTime{} = disconnected.disconnected_at
    refute disconnected.auto_charge_enabled

    {:ok, reconnected} =
      disconnected
      |> Ash.Changeset.for_update(:reconnect, %{
        access_token: "at-fresh",
        refresh_token: "rt-fresh",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        external_merchant_id: "MLR-DIFFERENT"
      })
      |> Ash.update(authorize?: false)

    assert reconnected.disconnected_at == nil
    assert reconnected.auto_charge_enabled == true
    assert reconnected.access_token == "at-fresh"
    assert reconnected.external_merchant_id == "MLR-DIFFERENT"
    assert %DateTime{} = reconnected.connected_at
  end

  test "unique_tenant_provider identity rejects duplicate (tenant, provider)", ctx do
    _ = connect_square!(ctx.tenant.id)

    {:error, %Ash.Error.Invalid{}} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :square,
        external_merchant_id: "MLR-2",
        access_token: "at-99",
        refresh_token: "rt-99",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)
  end

  test "provider rejects unknown values (only :square in V1)", ctx do
    {:error, %Ash.Error.Invalid{}} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :totally_not_a_real_provider,
        external_merchant_id: "x",
        access_token: "x",
        refresh_token: "y",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)
  end

  defp connect_square!(tenant_id) do
    PaymentConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :square,
      external_merchant_id: "MLR-1",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> Ash.create!(authorize?: false)
  end
end
```

- [ ] **Step 2: Run the test — should fail (module not found)**

```bash
mix test test/driveway_os/platform/payment_connection_test.exs
```

Expected: compile error / module not found for `DrivewayOS.Platform.PaymentConnection`.

- [ ] **Step 3: Create the resource**

Create `lib/driveway_os/platform/payment_connection.ex`:

```elixir
defmodule DrivewayOS.Platform.PaymentConnection do
  @moduledoc """
  Per-(tenant, payment provider) integration record. Stores OAuth
  tokens, sync settings, and last-charge metadata. Platform-tier — no
  multitenancy block; tenants don't read this directly, only the
  Square modules and the IntegrationsLive page do.

  Lifecycle:
    * `:connect` — first time tenant authorizes; populates tokens.
    * `:refresh_tokens` — periodic; replaces access/refresh tokens.
    * `:reconnect` — on OAuth re-authorize after a disconnect; updates
       tokens + merchant_id, clears disconnected_at, sets
       auto_charge_enabled true. Single atomic action — Phase 3's M1
       fix incorporated preemptively.
    * `:record_charge_success` / `:record_charge_error` — webhook updates.
    * `:pause` / `:resume` — tenant-controlled, toggles auto_charge_enabled.
    * `:disconnect` — clears tokens, sets disconnected_at, auto-pauses.

  Tokens are sensitive (Ash redacts them in logs); plaintext at rest
  in V1, matching Phase 1's `postmark_api_key` and Phase 3's
  AccountingConnection access tokens.

  V1's only `:provider` value is `:square`; Phase 5+ extends to other
  payment providers.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

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
      constraints one_of: [:square]
    end

    attribute :external_merchant_id, :string, public?: true

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

- [ ] **Step 4: Register in Platform domain + add helpers**

Edit `lib/driveway_os/platform.ex`. Find the `alias DrivewayOS.Platform.{...}` block and add `PaymentConnection`. Find the `resources do` block and add `resource PaymentConnection`.

Append two query helpers near `get_accounting_connection/2` (added in Phase 3):

```elixir
  @doc """
  Look up the PaymentConnection for a (tenant, provider) tuple.
  Returns `{:ok, connection}` or `{:error, :not_found}`.
  """
  @spec get_payment_connection(binary(), atom()) ::
          {:ok, PaymentConnection.t()} | {:error, :not_found}
  def get_payment_connection(tenant_id, provider)
      when is_binary(tenant_id) and is_atom(provider) do
    PaymentConnection
    |> Ash.Query.filter(tenant_id == ^tenant_id and provider == ^provider)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, conn} -> {:ok, conn}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Like `get_payment_connection/2` but rejects rows that aren't
  actively chargeable — disconnected, paused, or missing tokens.
  Returns `{:error, :no_active_connection}` for any of those.
  """
  @spec get_active_payment_connection(binary(), atom()) ::
          {:ok, PaymentConnection.t()} | {:error, :no_active_connection}
  def get_active_payment_connection(tenant_id, provider) do
    case get_payment_connection(tenant_id, provider) do
      {:ok, %PaymentConnection{
         auto_charge_enabled: true,
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
mix ash_postgres.generate_migrations --name create_platform_payment_connections
```

Expected: a new file `priv/repo/migrations/<ts>_create_platform_payment_connections.exs` with `create table(:platform_payment_connections)`, `tenant_id` FK, all attributes, unique index on `(tenant_id, provider)`.

- [ ] **Step 6: Apply migration**

```bash
MIX_ENV=test mix ecto.migrate
```

- [ ] **Step 7: Re-run the test**

```bash
mix test test/driveway_os/platform/payment_connection_test.exs
```

Expected: 8 tests, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/driveway_os/platform/payment_connection.ex \
        lib/driveway_os/platform.ex \
        priv/repo/migrations/*_create_platform_payment_connections.exs \
        priv/resource_snapshots/repo/platform_payment_connections \
        test/driveway_os/platform/payment_connection_test.exs

git commit -m "Platform: PaymentConnection resource + Platform.get_*_payment_connection helpers"
```

---

## Task 2: Extend `Platform.OauthState` for `:square`

**Files:**
- Modify: `lib/driveway_os/platform/oauth_state.ex`

Per spec deviation #1, this generates no migration (Ash atom-enum is changeset-layer enforcement, not a Postgres CHECK).

- [ ] **Step 1: Extend the constraint**

In `lib/driveway_os/platform/oauth_state.ex`, find:

```elixir
    attribute :purpose, :atom do
      constraints one_of: [:stripe_connect, :zoho_books]
      ...
```

Change to:

```elixir
    attribute :purpose, :atom do
      constraints one_of: [:stripe_connect, :zoho_books, :square]
      default :stripe_connect
      allow_nil? false
      public? true
    end
```

Update the moduledoc's "third-party OAuth flow (Stripe Connect, Zoho Books)" to "third-party OAuth flow (Stripe Connect, Zoho Books, Square)".

- [ ] **Step 2: Generate migration (will report no changes)**

```bash
mix ash_postgres.generate_migrations --name extend_oauth_state_purpose_for_square
```

Expected: "No changes detected." This is correct per spec deviation #1.

- [ ] **Step 3: Verify no regression on existing OauthState tests**

```bash
mix test test/driveway_os/platform/
```

Expected: green; `:stripe_connect` + `:zoho_books` issue + verify still work.

- [ ] **Step 4: Commit**

```bash
git add lib/driveway_os/platform/oauth_state.ex
git commit -m "Platform.OauthState: extend :purpose constraint to allow :square"
```

---

## Task 3: `Square.Client` HTTP behaviour + Http impl + Mox + config wiring

**Files:**
- Create: `lib/driveway_os/square/client.ex`
- Create: `lib/driveway_os/square/client/http.ex`
- Modify: `config/config.exs`, `config/test.exs`, `test/test_helper.exs`

- [ ] **Step 1: Create the behaviour**

Create `lib/driveway_os/square/client.ex`:

```elixir
defmodule DrivewayOS.Square.Client do
  @moduledoc """
  Behaviour for the Square HTTP layer. Five concerns:

    * `exchange_oauth_code/2` — POST to /oauth2/token (grant_type:
      authorization_code) to convert the OAuth callback's code into
      access + refresh tokens. Square returns the tenant's
      merchant_id directly in this response — no separate org probe.
    * `refresh_access_token/1` — POST to /oauth2/token (grant_type:
      refresh_token).
    * `api_get/3` / `api_post/3` — REST calls against
      https://connect.squareup.com/v2/... (or sandbox host) with the
      access_token in Authorization header.
    * `create_payment_link/2` — POST /v2/online-checkout/payment-links
      to create a hosted Square Checkout session for a booking.

  Tests Mox-mock this behaviour. Production uses
  `DrivewayOS.Square.Client.Http`.
  """

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

  @callback api_get(
              access_token :: String.t(),
              path :: String.t(),
              params :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback api_post(
              access_token :: String.t(),
              path :: String.t(),
              body :: map()
            ) :: {:ok, map()} | {:error, term()}

  @callback create_payment_link(
              access_token :: String.t(),
              body :: map()
            ) ::
              {:ok, %{
                 checkout_url: String.t(),
                 payment_link_id: String.t(),
                 order_id: String.t()
               }}
              | {:error, term()}

  @doc "Returns the configured impl module — production = Http, tests = Mox mock."
  @spec impl() :: module()
  def impl, do: Application.get_env(:driveway_os, :square_client, __MODULE__.Http)

  defdelegate exchange_oauth_code(code, redirect_uri), to: __MODULE__.Http
  defdelegate refresh_access_token(refresh_token), to: __MODULE__.Http
  defdelegate api_get(access_token, path, params), to: __MODULE__.Http
  defdelegate api_post(access_token, path, body), to: __MODULE__.Http
  defdelegate create_payment_link(access_token, body), to: __MODULE__.Http
end
```

- [ ] **Step 2: Create the Http impl**

Create `lib/driveway_os/square/client/http.ex`:

```elixir
defmodule DrivewayOS.Square.Client.Http do
  @moduledoc """
  Production impl of the `Square.Client` behaviour. Uses Req.

  Base URLs are read from app env at runtime so sandbox/prod toggle
  via `SQUARE_OAUTH_BASE` + `SQUARE_API_BASE` env vars without
  recompile (per Phase 4 design decision #7). Defaults to prod when
  unset.

  401 → `{:error, :auth_failed}` for refresh + api_get + api_post
  + create_payment_link. exchange_oauth_code returns the full
  {status, body} map on non-200 (preserves Square's
  error_description for the OAuth controller's error handling —
  same divergence as Phase 3's ZohoClient.Http).
  """
  @behaviour DrivewayOS.Square.Client

  require Logger

  defp oauth_base, do: Application.get_env(:driveway_os, :square_oauth_base, "https://connect.squareup.com")
  defp api_base, do: Application.get_env(:driveway_os, :square_api_base, "https://connect.squareup.com/v2")

  @impl true
  def exchange_oauth_code(code, redirect_uri) do
    body = %{
      "grant_type" => "authorization_code",
      "client_id" => Application.fetch_env!(:driveway_os, :square_app_id),
      "client_secret" => Application.fetch_env!(:driveway_os, :square_app_secret),
      "redirect_uri" => redirect_uri,
      "code" => code
    }

    case Req.post("#{oauth_base()}/oauth2/token",
           json: body,
           headers: [{"square-version", "2024-01-18"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => at, "refresh_token" => rt, "merchant_id" => mid} = b}} ->
        {:ok,
         %{
           access_token: at,
           refresh_token: rt,
           expires_in: parse_expires_in(b),
           merchant_id: mid
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Square code exchange failed status=#{status} body=#{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def refresh_access_token(refresh_token) do
    body = %{
      "grant_type" => "refresh_token",
      "client_id" => Application.fetch_env!(:driveway_os, :square_app_id),
      "client_secret" => Application.fetch_env!(:driveway_os, :square_app_secret),
      "refresh_token" => refresh_token
    }

    case Req.post("#{oauth_base()}/oauth2/token",
           json: body,
           headers: [{"square-version", "2024-01-18"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => at} = b}} ->
        {:ok, %{access_token: at, expires_in: parse_expires_in(b)}}

      {:ok, %{status: 401}} ->
        {:error, :auth_failed}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def api_get(access_token, path, params \\ []) do
    case Req.get("#{api_base()}#{path}",
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
  def api_post(access_token, path, body) do
    case Req.post("#{api_base()}#{path}", json: body, headers: auth_headers(access_token)) do
      {:ok, %{status: status, body: body}} when status in [200, 201] -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :auth_failed}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_payment_link(access_token, body) do
    case Req.post("#{api_base()}/online-checkout/payment-links",
           json: body,
           headers: auth_headers(access_token)
         ) do
      {:ok, %{status: 200, body: %{"payment_link" => link, "related_resources" => %{"orders" => [%{"id" => order_id} | _]}}}} ->
        {:ok, %{
          checkout_url: link["url"],
          payment_link_id: link["id"],
          order_id: order_id
        }}

      {:ok, %{status: 200, body: %{"payment_link" => link} = b}} ->
        # Some Square responses don't include orders in related_resources;
        # fall back to the order_id field on the link itself.
        {:ok, %{
          checkout_url: link["url"],
          payment_link_id: link["id"],
          order_id: link["order_id"] || get_in(b, ["related_resources", "orders", Access.at(0), "id"])
        }}

      {:ok, %{status: 401}} -> {:error, :auth_failed}
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth_headers(token) do
    [{"authorization", "Bearer #{token}"}, {"square-version", "2024-01-18"}]
  end

  # Square's token responses include `expires_at` (ISO-8601) — convert
  # to seconds-from-now for parity with Zoho's `expires_in`.
  defp parse_expires_in(%{"expires_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.diff(dt, DateTime.utc_now(), :second)
      _ -> 30 * 86_400
    end
  end

  defp parse_expires_in(_), do: 30 * 86_400  # Square default 30 days
end
```

- [ ] **Step 3: Add Mox mock + test config**

Edit `test/test_helper.exs`. Below the existing Mox.defmock lines (Postmark, Zoho), add:

```elixir
Mox.defmock(DrivewayOS.Square.Client.Mock, for: DrivewayOS.Square.Client)
```

Edit `config/test.exs`. Near the Zoho test config, add:

```elixir
config :driveway_os, :square_client, DrivewayOS.Square.Client.Mock
config :driveway_os, :square_app_id, "test-square-app-id"
config :driveway_os, :square_app_secret, "test-square-app-secret"
config :driveway_os, :square_webhook_signature_key, "test-square-webhook-key"
config :driveway_os, :square_affiliate_ref_id, nil
```

Edit `config/config.exs`. Near Zoho's default-impl line, add:

```elixir
config :driveway_os, :square_client, DrivewayOS.Square.Client.Http
```

- [ ] **Step 4: Verify compilation**

```bash
mix compile
```

Expected: clean compile.

- [ ] **Step 5: Run full test suite**

```bash
mix test
```

Expected: 0 failures (no new tests; behaviour scaffolding only).

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/square/client.ex \
        lib/driveway_os/square/client/http.ex \
        config/config.exs config/test.exs test/test_helper.exs

git commit -m "Square.Client: behaviour + Http impl + Mox mock + config wiring"
```

---

## Task 4: `Square.OAuth` helper module

**Files:**
- Create: `lib/driveway_os/square.ex` (thin facade)
- Create: `lib/driveway_os/square/oauth.ex`
- Test: `test/driveway_os/square/oauth_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/square/oauth_test.exs`:

```elixir
defmodule DrivewayOS.Square.OAuthTest do
  @moduledoc """
  Pin the Square OAuth helper module: URL construction, state token
  consumption, code exchange. HTTP is Mox-stubbed via
  Square.Client.Mock.
  """
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Square.{Client, OAuth}
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PaymentConnection

  require Ash.Query

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "sqo-#{System.unique_integer([:positive])}",
        display_name: "Square OAuth Test",
        admin_email: "sqo-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  describe "configured?/0" do
    test "true when square_app_id is set" do
      assert OAuth.configured?()
    end

    test "false when square_app_id is empty/nil" do
      original = Application.get_env(:driveway_os, :square_app_id)
      Application.put_env(:driveway_os, :square_app_id, "")
      on_exit(fn -> Application.put_env(:driveway_os, :square_app_id, original) end)

      refute OAuth.configured?()
    end
  end

  describe "oauth_url_for/1" do
    test "builds the auth URL with state token bound to the tenant", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)

      assert url =~ "connect.squareup.com/oauth2/authorize"
      assert url =~ "client_id=test-square-app-id"
      assert url =~ "scope=PAYMENTS_WRITE+PAYMENTS_READ+MERCHANT_PROFILE_READ"
      assert url =~ "session=false"
      assert url =~ "state="

      [state_param] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, _} =
               DrivewayOS.Platform.OauthState
               |> Ash.Query.for_read(:by_token, %{token: state_param})
               |> Ash.read(authorize?: false)
    end
  end

  describe "verify_state/1" do
    test "consumes a valid state token (single-use)", ctx do
      url = OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      assert {:ok, tid} = OAuth.verify_state(token)
      assert tid == ctx.tenant.id
      assert {:error, :invalid_state} = OAuth.verify_state(token)
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_state} = OAuth.verify_state("nope")
    end

    test "rejects a state token with non-square purpose", ctx do
      {:ok, zoho_state} =
        DrivewayOS.Platform.OauthState
        |> Ash.Changeset.for_create(:issue, %{
          tenant_id: ctx.tenant.id,
          purpose: :zoho_books
        })
        |> Ash.create(authorize?: false)

      assert {:error, :invalid_state} = OAuth.verify_state(zoho_state.token)
    end
  end

  describe "complete_onboarding/2" do
    test "exchanges code, upserts PaymentConnection (first connect)", ctx do
      expect(Client.Mock, :exchange_oauth_code, fn code, _redirect_uri ->
        assert code == "auth-code-123"
        {:ok, %{
          access_token: "at-99",
          refresh_token: "rt-99",
          expires_in: 30 * 86_400,
          merchant_id: "MLR-99"
        }}
      end)

      assert {:ok, %PaymentConnection{} = conn} =
               OAuth.complete_onboarding(ctx.tenant, "auth-code-123")

      assert conn.tenant_id == ctx.tenant.id
      assert conn.provider == :square
      assert conn.access_token == "at-99"
      assert conn.refresh_token == "rt-99"
      assert conn.external_merchant_id == "MLR-99"
    end

    test "reconnect upserts the existing row, clears disconnected_at", ctx do
      # First connect
      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-1", refresh_token: "rt-1", expires_in: 86_400, merchant_id: "MLR-1"}}
      end)

      {:ok, conn1} = OAuth.complete_onboarding(ctx.tenant, "code-1")

      # Disconnect
      conn1
      |> Ash.Changeset.for_update(:disconnect, %{})
      |> Ash.update!(authorize?: false)

      # Reconnect
      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{access_token: "at-2", refresh_token: "rt-2", expires_in: 86_400, merchant_id: "MLR-2"}}
      end)

      {:ok, conn2} = OAuth.complete_onboarding(ctx.tenant, "code-2")

      assert conn2.access_token == "at-2"
      assert conn2.external_merchant_id == "MLR-2"
      assert conn2.disconnected_at == nil
      assert conn2.auto_charge_enabled == true

      # Confirm only one row
      {:ok, all} = Ash.read(PaymentConnection, authorize?: false)
      assert Enum.count(all, &(&1.tenant_id == ctx.tenant.id)) == 1

      assert {:ok, _} =
               Platform.get_active_payment_connection(ctx.tenant.id, :square)
    end

    test "code-exchange failure returns error tuple, no row written", ctx do
      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:error, %{status: 400, body: %{"error" => "invalid_code"}}}
      end)

      assert {:error, %{status: 400}} =
               OAuth.complete_onboarding(ctx.tenant, "bad-code")

      assert {:error, :not_found} =
               Platform.get_payment_connection(ctx.tenant.id, :square)
    end
  end
end
```

- [ ] **Step 2: Run the test — should fail**

```bash
mix test test/driveway_os/square/oauth_test.exs
```

Expected: undefined module `DrivewayOS.Square.OAuth`.

- [ ] **Step 3: Create Square facade module**

Create `lib/driveway_os/square.ex`:

```elixir
defmodule DrivewayOS.Square do
  @moduledoc """
  Public namespace for Square integration. Aliases the OAuth, Client,
  and Charge submodules. The integration is split into:

    * `Square.OAuth` — connect/reconnect lifecycle (mirrors
      Accounting.OAuth from Phase 3).
    * `Square.Client` — HTTP behaviour (Mox-mockable in tests).
    * `Square.Charge` — Square Checkout (Payment Links) session
      creation, used at booking checkout time when the tenant has
      Square connected.
  """

  alias DrivewayOS.Square.{OAuth, Client, Charge}

  defdelegate oauth_url_for(tenant), to: OAuth
  defdelegate verify_state(token), to: OAuth
  defdelegate complete_onboarding(tenant, code), to: OAuth
  defdelegate configured?(), to: OAuth
end
```

- [ ] **Step 4: Implement Square.OAuth**

Create `lib/driveway_os/square/oauth.ex`:

```elixir
defmodule DrivewayOS.Square.OAuth do
  @moduledoc """
  Square OAuth helper. Mirrors `DrivewayOS.Accounting.OAuth`'s shape —
  same `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`,
  `configured?/0` quartet.

  V1 hardcodes prod base URL via app env (sandbox toggle via
  SQUARE_OAUTH_BASE).
  """

  alias DrivewayOS.Square.Client
  alias DrivewayOS.Platform.{OauthState, PaymentConnection, Tenant}

  require Ash.Query

  @doc """
  Build the Square OAuth URL for `tenant`. Mints a CSRF-safe state
  token bound to the tenant.
  """
  @spec oauth_url_for(Tenant.t()) :: String.t()
  def oauth_url_for(%Tenant{id: tenant_id}) do
    {:ok, state} =
      OauthState
      |> Ash.Changeset.for_create(:issue, %{
        tenant_id: tenant_id,
        purpose: :square
      })
      |> Ash.create(authorize?: false)

    params = %{
      response_type: "code",
      client_id: client_id(),
      scope: "PAYMENTS_WRITE PAYMENTS_READ MERCHANT_PROFILE_READ",
      session: "false",
      state: state.token,
      redirect_uri: redirect_uri()
    }

    "#{oauth_base()}/oauth2/authorize?" <> URI.encode_query(params)
  end

  @doc """
  Verify a state token and consume it (single-use). Pins
  purpose: :square so a Stripe/Zoho-purpose token can't satisfy
  a Square callback.
  """
  @spec verify_state(String.t()) :: {:ok, binary()} | {:error, :invalid_state}
  def verify_state(token) when is_binary(token) do
    case OauthState
         |> Ash.Query.for_read(:by_token, %{token: token})
         |> Ash.read(authorize?: false) do
      {:ok, [%OauthState{purpose: :square} = state]} ->
        Ash.destroy!(state, authorize?: false)
        {:ok, state.tenant_id}

      _ ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Exchange a code for tokens, upsert PaymentConnection. Reconnects
  (existing row) update tokens + clear disconnected_at via the
  :reconnect action; first connects create a new row.
  """
  @spec complete_onboarding(Tenant.t(), String.t()) ::
          {:ok, PaymentConnection.t()} | {:error, term()}
  def complete_onboarding(%Tenant{id: tenant_id}, code) when is_binary(code) do
    with {:ok, %{access_token: at, refresh_token: rt, expires_in: secs, merchant_id: mid}} <-
           Client.impl().exchange_oauth_code(code, redirect_uri()) do
      expires_at = DateTime.add(DateTime.utc_now(), secs, :second)
      upsert_connection(tenant_id, mid, at, rt, expires_at)
    end
  end

  @doc "True when Square OAuth credentials are configured on the platform."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:driveway_os, :square_app_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  # --- Helpers ---

  defp upsert_connection(tenant_id, merchant_id, access_token, refresh_token, expires_at) do
    case DrivewayOS.Platform.get_payment_connection(tenant_id, :square) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:reconnect, %{
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at,
          external_merchant_id: merchant_id
        })
        |> Ash.update(authorize?: false)

      {:error, :not_found} ->
        PaymentConnection
        |> Ash.Changeset.for_create(:connect, %{
          tenant_id: tenant_id,
          provider: :square,
          external_merchant_id: merchant_id,
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at
        })
        |> Ash.create(authorize?: false)
    end
  end

  defp client_id, do: Application.fetch_env!(:driveway_os, :square_app_id)

  defp oauth_base, do: Application.get_env(:driveway_os, :square_oauth_base, "https://connect.squareup.com")

  defp redirect_uri do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        port = endpoint_port() || 4000
        {"http", ":#{port}"}
      else
        {"https", ""}
      end

    "#{scheme}://#{host}#{port_suffix}/onboarding/square/callback"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
```

- [ ] **Step 5: Re-run test**

```bash
mix test test/driveway_os/square/oauth_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/square.ex \
        lib/driveway_os/square/oauth.ex \
        test/driveway_os/square/oauth_test.exs

git commit -m "Square.OAuth: URL/state/exchange helper (mirrors Accounting.OAuth)"
```

---

## Task 5: `Onboarding.Providers.Square` adapter + Registry registration

**Files:**
- Create: `lib/driveway_os/onboarding/providers/square.ex`
- Modify: `lib/driveway_os/onboarding/registry.ex`
- Test: `test/driveway_os/onboarding/providers/square_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/onboarding/providers/square_test.exs`:

```elixir
defmodule DrivewayOS.Onboarding.Providers.SquareTest do
  @moduledoc """
  Pin the Provider behaviour conformance for the Square adapter.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Providers.Square, as: Provider
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PaymentConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "osq-#{System.unique_integer([:positive])}",
        display_name: "Square Adapter Test",
        admin_email: "osq-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :square" do
    assert Provider.id() == :square
  end

  test "category/0 is :payment" do
    assert Provider.category() == :payment
  end

  test "display/0 returns the canonical card copy" do
    d = Provider.display()
    assert d.title == "Take card payments via Square"
    assert d.cta_label == "Connect Square"
    assert d.href == "/onboarding/square/start"
  end

  test "configured?/0 mirrors the OAuth helper" do
    assert Provider.configured?()
  end

  test "setup_complete?/1 false when no PaymentConnection exists", ctx do
    refute Provider.setup_complete?(ctx.tenant)
  end

  test "setup_complete?/1 true when PaymentConnection has tokens", ctx do
    {:ok, _} =
      PaymentConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :square,
        external_merchant_id: "MLR-1",
        access_token: "at",
        refresh_token: "rt",
        access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Ash.create(authorize?: false)

    assert Provider.setup_complete?(ctx.tenant)
  end

  test "provision/2 returns {:error, :hosted_required} (Square is OAuth-redirect)", ctx do
    assert {:error, :hosted_required} = Provider.provision(ctx.tenant, %{})
  end

  describe "affiliate_config/0" do
    test "ref_id from app env" do
      original = Application.get_env(:driveway_os, :square_affiliate_ref_id)
      Application.put_env(:driveway_os, :square_affiliate_ref_id, "drivewayos-square")
      on_exit(fn -> Application.put_env(:driveway_os, :square_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: "drivewayos-square"} = Provider.affiliate_config()
    end

    test "ref_id nil when env unset" do
      original = Application.get_env(:driveway_os, :square_affiliate_ref_id)
      Application.put_env(:driveway_os, :square_affiliate_ref_id, nil)
      on_exit(fn -> Application.put_env(:driveway_os, :square_affiliate_ref_id, original) end)

      assert %{ref_param: "ref", ref_id: nil} = Provider.affiliate_config()
    end
  end

  test "tenant_perk/0 returns nil — no perk shipping in V1" do
    assert Provider.tenant_perk() == nil
  end
end
```

- [ ] **Step 2: Run test — should fail**

```bash
mix test test/driveway_os/onboarding/providers/square_test.exs
```

Expected: undefined module.

- [ ] **Step 3: Implement adapter**

Create `lib/driveway_os/onboarding/providers/square.ex`:

```elixir
defmodule DrivewayOS.Onboarding.Providers.Square do
  @moduledoc """
  Onboarding adapter for Square. Hosted-redirect OAuth provider —
  `provision/2` returns `{:error, :hosted_required}`; the wizard
  routes the operator to `display.href` (= `/onboarding/square/start`).

  Mirrors `Onboarding.Providers.ZohoBooks`'s shape exactly. The
  underlying OAuth + Client + Charge logic lives in `DrivewayOS.Square`.
  """
  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Square.OAuth
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{PaymentConnection, Tenant}

  @impl true
  def id, do: :square

  @impl true
  def category, do: :payment

  @impl true
  def display do
    %{
      title: "Take card payments via Square",
      blurb:
        "Connect your existing Square account. Customers pay at booking; " <>
          "funds land in your Square balance.",
      cta_label: "Connect Square",
      href: "/onboarding/square/start"
    }
  end

  @impl true
  def configured?, do: OAuth.configured?()

  @impl true
  def setup_complete?(%Tenant{id: tid}) do
    case Platform.get_payment_connection(tid, :square) do
      {:ok, %PaymentConnection{access_token: at}} when is_binary(at) -> true
      _ -> false
    end
  end

  @impl true
  def provision(_tenant, _params), do: {:error, :hosted_required}

  @impl true
  def affiliate_config do
    %{
      ref_param: "ref",
      ref_id: Application.get_env(:driveway_os, :square_affiliate_ref_id)
    }
  end

  @impl true
  def tenant_perk, do: nil
end
```

- [ ] **Step 4: Register in Registry**

Edit `lib/driveway_os/onboarding/registry.ex`. Find:

```elixir
  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect,
    DrivewayOS.Onboarding.Providers.Postmark,
    DrivewayOS.Onboarding.Providers.ZohoBooks
  ]
```

Add `Square`:

```elixir
  @providers [
    DrivewayOS.Onboarding.Providers.StripeConnect,
    DrivewayOS.Onboarding.Providers.Postmark,
    DrivewayOS.Onboarding.Providers.ZohoBooks,
    DrivewayOS.Onboarding.Providers.Square
  ]
```

- [ ] **Step 5: Run tests**

```bash
mix test test/driveway_os/onboarding/providers/square_test.exs
mix test test/driveway_os/onboarding/registry_test.exs
mix test
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/onboarding/providers/square.ex \
        lib/driveway_os/onboarding/registry.ex \
        test/driveway_os/onboarding/providers/square_test.exs

git commit -m "Onboarding.Providers.Square: adapter + Registry registration"
```

---

## Task 6: `SquareOauthController` + routes

**Files:**
- Create: `lib/driveway_os_web/controllers/square_oauth_controller.ex`
- Modify: `lib/driveway_os_web/router.ex`
- Test: `test/driveway_os_web/controllers/square_oauth_controller_test.exs`

- [ ] **Step 1: Read the existing Zoho OAuth controller test for the auth-helper pattern**

Open `test/driveway_os_web/controllers/zoho_oauth_controller_test.exs` and find its `sign_in_admin_for_tenant/3` helper. Copy its shape into the new test file (don't import).

- [ ] **Step 2: Write the failing test**

Create `test/driveway_os_web/controllers/square_oauth_controller_test.exs`:

```elixir
defmodule DrivewayOSWeb.SquareOauthControllerTest do
  @moduledoc """
  Pin the Square OAuth controller's contract: start logs :click +
  redirects (with affiliate ref tag when configured), callback
  exchanges code + creates PaymentConnection + logs :provisioned,
  errors return 400.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Mox

  alias DrivewayOS.Square.Client
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{PaymentConnection, TenantReferral}

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sqc-#{System.unique_integer([:positive])}",
        display_name: "Square Controller Test",
        admin_email: "sqc-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    conn = sign_in_admin_for_tenant(build_conn(), tenant, admin)

    %{conn: conn, tenant: tenant, admin: admin}
  end

  describe "GET /onboarding/square/start" do
    test "redirects to Square OAuth and logs :click", ctx do
      conn = get(ctx.conn, "/onboarding/square/start")
      url = redirected_to(conn, 302)

      assert url =~ "connect.squareup.com/oauth2/authorize"
      assert url =~ "state="

      {:ok, all} = Ash.read(TenantReferral, authorize?: false)
      [event] = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
      assert event.provider == :square
      assert event.event_type == :click
    end

    test "appends affiliate ref when SQUARE_AFFILIATE_REF_ID is set", ctx do
      original = Application.get_env(:driveway_os, :square_affiliate_ref_id)
      Application.put_env(:driveway_os, :square_affiliate_ref_id, "myref")
      on_exit(fn -> Application.put_env(:driveway_os, :square_affiliate_ref_id, original) end)

      conn = get(ctx.conn, "/onboarding/square/start")
      url = redirected_to(conn, 302)
      assert url =~ "ref=myref"
    end
  end

  describe "GET /onboarding/square/callback" do
    test "exchanges code, creates PaymentConnection, logs :provisioned", ctx do
      url = DrivewayOS.Square.OAuth.oauth_url_for(ctx.tenant)
      [token] = Regex.run(~r/state=([^&]+)/, url, capture: :all_but_first)

      expect(Client.Mock, :exchange_oauth_code, fn _, _ ->
        {:ok, %{
          access_token: "at-cb",
          refresh_token: "rt-cb",
          expires_in: 30 * 86_400,
          merchant_id: "MLR-CB"
        }}
      end)

      conn = get(ctx.conn, "/onboarding/square/callback?code=auth-code&state=#{token}")

      assert redirected_to(conn, 302) =~ "/admin/integrations"

      {:ok, conn_row} = Platform.get_payment_connection(ctx.tenant.id, :square)
      assert conn_row.access_token == "at-cb"
      assert conn_row.external_merchant_id == "MLR-CB"

      {:ok, all_events} = Ash.read(TenantReferral, authorize?: false)
      provisioned = Enum.filter(all_events, &(&1.tenant_id == ctx.tenant.id and &1.event_type == :provisioned))
      assert [_] = provisioned
    end

    test "returns 400 on invalid state", ctx do
      conn = get(ctx.conn, "/onboarding/square/callback?code=x&state=not-a-real-token")
      assert response(conn, 400) =~ "Square onboarding failed"
    end

    test "returns 400 on missing params", ctx do
      conn = get(ctx.conn, "/onboarding/square/callback")
      assert response(conn, 400) =~ "Missing"
    end
  end

  defp sign_in_admin_for_tenant(_conn, _tenant, _admin) do
    raise "Implement using existing zoho_oauth_controller_test's auth helper (copy from there)"
  end
end
```

- [ ] **Step 3: Run test — should fail**

```bash
mix test test/driveway_os_web/controllers/square_oauth_controller_test.exs
```

Expected: undefined module / route not found.

- [ ] **Step 4: Implement controller**

Create `lib/driveway_os_web/controllers/square_oauth_controller.ex`:

```elixir
defmodule DrivewayOSWeb.SquareOauthController do
  @moduledoc """
  Square OAuth endpoints. Mirrors `ZohoOauthController`.

      GET /onboarding/square/start    — admin-only, redirects to Square OAuth
      GET /onboarding/square/callback — Square redirects here after auth

  Callback runs on the marketing host. We resolve which tenant via
  the state token.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Square.OAuth
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
        |> put_flash(:error,
          "Square isn't configured on this server yet. " <>
            "Ask the platform admin to set SQUARE_APP_ID."
        )
        |> redirect(to: ~p"/admin")
        |> halt()

      true ->
        url =
          conn.assigns.current_tenant
          |> OAuth.oauth_url_for()
          |> Affiliate.tag_url(:square)

        :ok =
          Affiliate.log_event(
            conn.assigns.current_tenant,
            :square,
            :click,
            %{wizard_step: "payment"}
          )

        redirect(conn, external: url)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, tenant_id} <- OAuth.verify_state(state),
         {:ok, tenant} <- Ash.get(Platform.Tenant, tenant_id, authorize?: false),
         {:ok, payment_conn} <- OAuth.complete_onboarding(tenant, code) do
      :ok =
        Affiliate.log_event(
          tenant,
          :square,
          :provisioned,
          %{external_merchant_id: payment_conn.external_merchant_id}
        )

      redirect(conn, external: tenant_integrations_url(tenant))
    else
      _ -> send_resp(conn, 400, "Square onboarding failed.")
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

- [ ] **Step 5: Add routes**

Edit `lib/driveway_os_web/router.ex`. Find the existing `/onboarding/zoho/*` routes; add:

```elixir
    get "/onboarding/square/start", SquareOauthController, :start
    get "/onboarding/square/callback", SquareOauthController, :callback
```

- [ ] **Step 6: Re-run test**

```bash
mix test test/driveway_os_web/controllers/square_oauth_controller_test.exs
```

Expected: 5 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lib/driveway_os_web/controllers/square_oauth_controller.ex \
        lib/driveway_os_web/router.ex \
        test/driveway_os_web/controllers/square_oauth_controller_test.exs

git commit -m "SquareOauthController: start/callback + Affiliate.tag_url integration"
```

---

## Task 7: `Steps.Payment` generalization (the picker)

**Files:**
- Modify: `lib/driveway_os/onboarding/steps/payment.ex`
- Test: `test/driveway_os/onboarding/steps/payment_test.exs` (extend)

- [ ] **Step 1: Extend the existing test**

In `test/driveway_os/onboarding/steps/payment_test.exs`, append a new describe block:

```elixir
  describe "render/1 picker (multi-provider)" do
    setup do
      {:ok, %{tenant: tenant}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "spp-#{System.unique_integer([:positive])}",
          display_name: "Picker Test",
          admin_email: "spp-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant}
    end

    test "renders cards for every configured payment provider not yet set up", ctx do
      html =
        Step.render(%{
          __changed__: %{},
          current_tenant: ctx.tenant
        })
        |> Phoenix.LiveViewTest.rendered_to_string()

      # Both V1 payment providers should be visible (Stripe Connect + Square)
      assert html =~ "Connect Stripe"
      assert html =~ "Connect Square"
      # Both are configured? in test env (stripe_client_id + square_app_id set)
    end

    test "applies UX rules: 44px touch targets, motion-reduce, slate-600 text", ctx do
      html =
        Step.render(%{
          __changed__: %{},
          current_tenant: ctx.tenant
        })
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "min-h-[44px]"
      assert html =~ "motion-reduce:transition-none"
      assert html =~ "text-slate-600"
    end
  end

  describe "complete?/1 generalization" do
    setup do
      {:ok, %{tenant: tenant}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "spc-#{System.unique_integer([:positive])}",
          display_name: "Complete Test",
          admin_email: "spc-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant}
    end

    test "false when no payment provider connected", ctx do
      refute Step.complete?(ctx.tenant)
    end

    test "true when Stripe is connected", ctx do
      {:ok, t} =
        ctx.tenant
        |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_test_123"})
        |> Ash.update(authorize?: false)

      assert Step.complete?(t)
    end

    test "true when Square is connected (PaymentConnection)", ctx do
      {:ok, _} =
        DrivewayOS.Platform.PaymentConnection
        |> Ash.Changeset.for_create(:connect, %{
          tenant_id: ctx.tenant.id,
          provider: :square,
          external_merchant_id: "MLR-1",
          access_token: "at",
          refresh_token: "rt",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Ash.create(authorize?: false)

      assert Step.complete?(ctx.tenant)
    end
  end
```

- [ ] **Step 2: Run test — should fail (render still single-card; complete? still single-provider)**

```bash
mix test test/driveway_os/onboarding/steps/payment_test.exs
```

Expected: failures on the picker + complete?/1 tests.

- [ ] **Step 3: Generalize Steps.Payment**

Replace the contents of `lib/driveway_os/onboarding/steps/payment.ex` with:

```elixir
defmodule DrivewayOS.Onboarding.Steps.Payment do
  @moduledoc """
  Payment wizard step. As of Phase 4, generic over N providers in
  the `:payment` category — iterates `Onboarding.Registry.by_category(:payment)`.

  Phase 1 shipped Stripe Connect (single-card render). Phase 4 added
  Square + the picker UI: tenant sees side-by-side cards for every
  configured payment provider not yet set up. Each card routes to its
  own OAuth start (no select-then-submit two-click flow).

  `complete?/1` returns true if ANY payment provider is connected for
  the tenant. Wizard skips the step once any one is done. There's no
  alternate entry point in V1 for tenants who already chose one
  provider — switching is support-driven (per spec decision #4).
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Onboarding.{Affiliate, Registry}
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :payment

  @impl true
  def title, do: "Take card payments"

  @impl true
  def complete?(%Tenant{} = tenant) do
    Registry.by_category(:payment)
    |> Enum.any?(& &1.setup_complete?(tenant))
  end

  @impl true
  def render(assigns) do
    cards = providers_for_picker(assigns.current_tenant)
    assigns = Map.put(assigns, :cards, cards)

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-slate-600">
        Pick the payment processor you want to use.
        You can change later by emailing support.
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

  @impl true
  def submit(_params, socket), do: {:ok, socket}

  defp providers_for_picker(tenant) do
    Registry.by_category(:payment)
    |> Enum.filter(& &1.configured?())
    |> Enum.reject(& &1.setup_complete?(tenant))
    |> Enum.map(fn mod -> Map.put(mod.display(), :id, mod.id()) end)
  end
end
```

- [ ] **Step 4: Re-run test**

```bash
mix test test/driveway_os/onboarding/steps/payment_test.exs
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/onboarding/steps/payment.ex \
        test/driveway_os/onboarding/steps/payment_test.exs

git commit -m "Steps.Payment: generalize to N-card picker; complete? checks any payment provider"
```

---

## Task 8: `Square.Charge` module — Square Checkout session creation

**Files:**
- Create: `lib/driveway_os/square/charge.ex`
- Test: `test/driveway_os/square/charge_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os/square/charge_test.exs`:

```elixir
defmodule DrivewayOS.Square.ChargeTest do
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Square.{Charge, Client}
  alias DrivewayOS.Platform.PaymentConnection

  setup :verify_on_exit!

  defp connection do
    %PaymentConnection{
      tenant_id: "tenant-1",
      provider: :square,
      external_merchant_id: "MLR-99",
      access_token: "at-1",
      refresh_token: "rt-1"
    }
  end

  defp appointment do
    %{
      id: "appt-1",
      price_cents: 5000,
      service_name: "Basic Wash"
    }
  end

  test "create_checkout_session/3 builds the right body and unwraps the response" do
    conn = connection()
    appt = appointment()

    expect(Client.Mock, :create_payment_link, fn at, body ->
      assert at == "at-1"
      assert body["idempotency_key"] == "appt-1"
      assert body["order"]["location_id"] == "MLR-99-LOC"
      assert [item] = body["order"]["line_items"]
      assert item["name"] == "Basic Wash"
      assert item["quantity"] == "1"
      assert item["base_price_money"]["amount"] == 5000
      assert item["base_price_money"]["currency"] == "USD"
      assert body["checkout_options"]["redirect_url"] == "https://example.com/back"

      {:ok, %{
        checkout_url: "https://checkout.square.example/abc",
        payment_link_id: "pl-1",
        order_id: "ord-1"
      }}
    end)

    assert {:ok, %{checkout_url: url, order_id: order_id}} =
             Charge.create_checkout_session(conn, appt, "https://example.com/back",
               location_id: "MLR-99-LOC")

    assert url == "https://checkout.square.example/abc"
    assert order_id == "ord-1"
  end

  test "propagates client errors" do
    expect(Client.Mock, :create_payment_link, fn _, _ ->
      {:error, %{status: 400, body: %{"errors" => [%{"code" => "INVALID_REQUEST_ERROR"}]}}}
    end)

    assert {:error, %{status: 400}} =
             Charge.create_checkout_session(connection(), appointment(),
               "https://example.com/back",
               location_id: "MLR-99-LOC")
  end
end
```

- [ ] **Step 2: Run test — fails**

```bash
mix test test/driveway_os/square/charge_test.exs
```

Expected: undefined module.

- [ ] **Step 3: Implement Square.Charge**

Create `lib/driveway_os/square/charge.ex`:

```elixir
defmodule DrivewayOS.Square.Charge do
  @moduledoc """
  Square Checkout (Payment Links) session creation.

  V1 charges one line item per appointment (the service name + price).
  Tenant's `external_merchant_id` is used as the location id stem;
  callers may override via `location_id` opt for tenants with multiple
  Square locations.

  Idempotency key = appointment id, so retrying the same booking
  doesn't create duplicate Payment Links in Square.

  `create_checkout_session/4` returns `{:ok, %{checkout_url, payment_link_id, order_id}}`
  on success. Caller (the booking flow) stores `order_id` on the
  Appointment as `square_order_id` so the webhook can match
  payment.updated events back to the right booking.
  """

  alias DrivewayOS.Square.Client
  alias DrivewayOS.Platform.PaymentConnection

  @doc """
  Build a Square Payment Link for `appointment` on behalf of the
  tenant connected via `connection`. `redirect_url` is where Square
  sends the customer after they pay.

  `opts`:
    * `:location_id` — Square Location ID for charge attribution.
       Defaults to the connection's `external_merchant_id` (Square
       merchants who have only one location can pass that as their
       primary location id, or the connection should populate it
       at OAuth time — V1 uses the merchant_id as a placeholder
       location_id; production deployments must pass an explicit
       location_id from the tenant's configured Square location.)
    * `:currency` — defaults to "USD".
  """
  @spec create_checkout_session(
          PaymentConnection.t(),
          appointment :: map(),
          redirect_url :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, %{checkout_url: String.t(), payment_link_id: String.t(), order_id: String.t()}}
          | {:error, term()}
  def create_checkout_session(%PaymentConnection{} = conn, appointment, redirect_url, opts \\ []) do
    location_id = Keyword.get(opts, :location_id, conn.external_merchant_id)
    currency = Keyword.get(opts, :currency, "USD")

    body = %{
      "idempotency_key" => appointment.id,
      "checkout_options" => %{
        "redirect_url" => redirect_url
      },
      "order" => %{
        "location_id" => location_id,
        "line_items" => [
          %{
            "name" => appointment.service_name,
            "quantity" => "1",
            "base_price_money" => %{
              "amount" => appointment.price_cents,
              "currency" => currency
            }
          }
        ]
      }
    }

    Client.impl().create_payment_link(conn.access_token, body)
  end
end
```

- [ ] **Step 4: Re-run test**

```bash
mix test test/driveway_os/square/charge_test.exs
```

Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/driveway_os/square/charge.ex \
        test/driveway_os/square/charge_test.exs

git commit -m "Square.Charge: Payment Link session creation"
```

---

## Task 9: `Appointment.square_order_id` attribute + migration + extend `:mark_paid`

**Files:**
- Modify: `lib/driveway_os/scheduling/appointment.ex`
- Create: `priv/repo/migrations/<ts>_add_square_order_id_to_appointments.exs` (generated)
- Test: extend appointment_test.exs

- [ ] **Step 1: Add attribute + read action + extend mark_paid**

Edit `lib/driveway_os/scheduling/appointment.ex`. In the `attributes do` block, add (near the existing `:stripe_payment_intent_id`):

```elixir
    attribute :square_order_id, :string do
      public? true
      description "Square Order id, set on `Square.Charge.create_checkout_session/3`. Webhook matches `payment.updated` events to this Appointment via this id."
    end
```

In the `actions do` block, find the existing `:by_payment_intent_or_session` read action; add a parallel `:by_square_order_id`:

```elixir
    read :by_square_order_id do
      argument :order_id, :string, allow_nil?: false
      filter expr(square_order_id == ^arg(:order_id))
    end
```

Find the `:mark_paid` action (line ~410):

```elixir
    update :mark_paid do
      argument :stripe_payment_intent_id, :string

      change set_attribute(:payment_status, :paid)
      change set_attribute(:paid_at, &DateTime.utc_now/0)
      change set_attribute(:status, :confirmed)
      change set_attribute(:stripe_payment_intent_id, arg(:stripe_payment_intent_id))
      change after_action(...)  # Phase 3 SyncWorker enqueue
    end
```

Extend the argument list and the change list:

```elixir
    update :mark_paid do
      argument :stripe_payment_intent_id, :string
      argument :square_order_id, :string

      change set_attribute(:payment_status, :paid)
      change set_attribute(:paid_at, &DateTime.utc_now/0)
      change set_attribute(:status, :confirmed)
      change set_attribute(:stripe_payment_intent_id, arg(:stripe_payment_intent_id))
      change set_attribute(:square_order_id, arg(:square_order_id))
      change after_action(...)  # unchanged
    end
```

Also extend the existing `:attach_stripe_session` action's accept list to include `:square_order_id` in case the booking flow's checkout-creation path wants to set it directly:

```elixir
    update :attach_stripe_session do
      accept [:stripe_checkout_session_id, :payment_status, :square_order_id]
    end
```

(Or — cleaner — add a parallel `:attach_square_order` action. Plan implementer picks based on existing-action ergonomics; the `:attach_stripe_session` rename to a generic name is too disruptive. Adding `:square_order_id` to its accept list is fine for V1.)

- [ ] **Step 2: Generate migration**

```bash
mix ash_postgres.generate_migrations --name add_square_order_id_to_appointments
```

Expected: a new migration adding `add :square_order_id, :text` to `appointments`.

- [ ] **Step 3: Apply migration**

```bash
MIX_ENV=test mix ecto.migrate
```

- [ ] **Step 4: Add test for the new read action**

Add to `test/driveway_os/scheduling/appointment_test.exs`:

```elixir
  describe ":by_square_order_id" do
    test "finds appointments by square_order_id", ctx do
      # Use existing `create_paid_appointment!` or `book!` helper
      appt = book_appointment!(ctx.tenant.id, ctx.admin.id)

      {:ok, updated} =
        appt
        |> Ash.Changeset.for_update(:attach_stripe_session, %{
          square_order_id: "ord-square-1"
        })
        |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

      {:ok, [found]} =
        DrivewayOS.Scheduling.Appointment
        |> Ash.Query.for_read(:by_square_order_id, %{order_id: "ord-square-1"})
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert found.id == updated.id
    end
  end
```

(Use whatever existing tenant + appointment-creation helper is in the file — the same one Phase 3 Task 10 used.)

- [ ] **Step 5: Run test**

```bash
mix test test/driveway_os/scheduling/appointment_test.exs
```

Expected: green (the new test passes; no regressions on existing).

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os/scheduling/appointment.ex \
        priv/repo/migrations/*_add_square_order_id_to_appointments.exs \
        priv/resource_snapshots/repo/appointments \
        test/driveway_os/scheduling/appointment_test.exs

git commit -m "Appointment: square_order_id attr + :by_square_order_id read + :mark_paid arg"
```

---

## Task 10: `SquareWebhookController` + signature verification + route

**Files:**
- Create: `lib/driveway_os_web/controllers/square_webhook_controller.ex`
- Modify: `lib/driveway_os_web/router.ex`
- Test: `test/driveway_os_web/controllers/square_webhook_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/driveway_os_web/controllers/square_webhook_controller_test.exs`:

```elixir
defmodule DrivewayOSWeb.SquareWebhookControllerTest do
  use DrivewayOSWeb.ConnCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.Appointment

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "swh-#{System.unique_integer([:positive])}",
        display_name: "Square WH Test",
        admin_email: "swh-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    # Create a paid-pending appointment with square_order_id
    appt = create_appointment_with_square_order!(tenant, admin, "ord-test-1")

    %{tenant: tenant, admin: admin, appt: appt}
  end

  test "POST /webhooks/square verifies signature and marks appointment paid", ctx do
    raw_body = build_payment_completed_event("ord-test-1")
    signature = sign_body(raw_body, "/webhooks/square")

    conn =
      build_conn()
      |> put_req_header("x-square-hmacsha256-signature", signature)
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/square", raw_body)

    assert response(conn, 200)

    {:ok, refreshed} = Ash.get(Appointment, ctx.appt.id, tenant: ctx.tenant.id, authorize?: false)
    assert refreshed.payment_status == :paid
  end

  test "POST /webhooks/square rejects bad signature" do
    raw_body = build_payment_completed_event("ord-test-1")

    conn =
      build_conn()
      |> put_req_header("x-square-hmacsha256-signature", "totally-wrong")
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/square", raw_body)

    assert response(conn, 400)
  end

  test "POST /webhooks/square ignores unknown order_id (returns 200, no-op)" do
    raw_body = build_payment_completed_event("ord-does-not-exist")
    signature = sign_body(raw_body, "/webhooks/square")

    conn =
      build_conn()
      |> put_req_header("x-square-hmacsha256-signature", signature)
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/square", raw_body)

    assert response(conn, 200)
  end

  defp build_payment_completed_event(order_id) do
    Jason.encode!(%{
      "type" => "payment.updated",
      "data" => %{
        "object" => %{
          "payment" => %{
            "order_id" => order_id,
            "status" => "COMPLETED",
            "id" => "pay_1"
          }
        }
      }
    })
  end

  defp sign_body(body, path) do
    # Square HMAC: base64(HMAC-SHA256(SIGNATURE_KEY, full_url + body))
    # In test the host is whatever Phoenix routes to — typically
    # "http://www.example.com" by default in ConnCase.
    full_url = "http://www.example.com#{path}"
    key = Application.fetch_env!(:driveway_os, :square_webhook_signature_key)

    :crypto.mac(:hmac, :sha256, key, full_url <> body)
    |> Base.encode64()
  end

  defp create_appointment_with_square_order!(_tenant, _admin, _order_id) do
    raise "Implement using existing test helper for booked Appointment + :attach_stripe_session with square_order_id"
  end
end
```

- [ ] **Step 2: Run test — fails**

```bash
mix test test/driveway_os_web/controllers/square_webhook_controller_test.exs
```

Expected: route not found.

- [ ] **Step 3: Implement controller**

Create `lib/driveway_os_web/controllers/square_webhook_controller.ex`:

```elixir
defmodule DrivewayOSWeb.SquareWebhookController do
  @moduledoc """
  Receives Square webhook events.

  Signature verification: Square signs each event with HMAC-SHA256.
  The signed payload is `full_request_url <> raw_body` (base64
  output). Header: `x-square-hmacsha256-signature`. The raw body
  is preserved by `DrivewayOSWeb.CacheBodyReader` (registered as
  the Plug.Parsers body_reader in endpoint.ex).

  V1 only handles `payment.updated` with status COMPLETED — looks
  up the matching Appointment by `square_order_id` and calls
  `Appointment.mark_paid`. Phase 3's after_action chain on `:mark_paid`
  fires the Accounting.SyncWorker for tenants with Zoho connected.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.Appointment

  require Ash.Query

  def handle(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""

    signature =
      case get_req_header(conn, "x-square-hmacsha256-signature") do
        [s | _] -> s
        _ -> ""
      end

    full_url = build_full_url(conn)
    key = Application.fetch_env!(:driveway_os, :square_webhook_signature_key)

    if valid_signature?(full_url <> raw_body, signature, key) do
      case Jason.decode(raw_body) do
        {:ok, event} ->
          process_event(event)
          send_resp(conn, 200, "ok")

        _ ->
          send_resp(conn, 400, "invalid body")
      end
    else
      send_resp(conn, 400, "invalid signature")
    end
  end

  # --- Event dispatch ---

  defp process_event(%{"type" => "payment.updated", "data" => %{"object" => %{"payment" => payment}}}) do
    if payment["status"] == "COMPLETED" do
      mark_paid(payment["order_id"], payment["id"])
    end

    :ok
  end

  defp process_event(_), do: :ok

  defp mark_paid(nil, _), do: :ok
  defp mark_paid(order_id, _payment_id) do
    # Find the Appointment by square_order_id across all tenants — we
    # don't know which tenant owns this order without checking. Use a
    # cross-tenant read via the Repo since Ash's tenant scoping
    # requires knowing the tenant up front, and the order_id is
    # globally unique per Square's design.
    case find_appointment_by_order_id(order_id) do
      {:ok, appt} ->
        appt
        |> Ash.Changeset.for_update(:mark_paid, %{square_order_id: order_id})
        |> Ash.update!(authorize?: false, tenant: appt.tenant_id)

      :error ->
        :ok
    end
  end

  defp find_appointment_by_order_id(order_id) do
    # Use Repo to bypass Ash tenant scoping since we don't know
    # the tenant up front. Square order_ids are globally unique.
    case DrivewayOS.Repo.get_by(Appointment, square_order_id: order_id) do
      nil -> :error
      appt -> {:ok, appt}
    end
  end

  defp valid_signature?(payload, candidate, key) when is_binary(candidate) and candidate != "" do
    expected = :crypto.mac(:hmac, :sha256, key, payload) |> Base.encode64()
    Plug.Crypto.secure_compare(expected, candidate)
  end

  defp valid_signature?(_, _, _), do: false

  defp build_full_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    host = conn.host

    port_part =
      cond do
        scheme == "https" and conn.port == 443 -> ""
        scheme == "http" and conn.port == 80 -> ""
        true -> ":#{conn.port}"
      end

    "#{scheme}://#{host}#{port_part}#{conn.request_path}"
  end
end
```

- [ ] **Step 4: Add route**

In `lib/driveway_os_web/router.ex`, find the existing `post "/stripe", StripeWebhookController, :handle` line and add:

```elixir
    post "/square", SquareWebhookController, :handle
```

- [ ] **Step 5: Run test**

Implement `create_appointment_with_square_order!/3` helper (look at how Phase 1's stripe_webhook_controller_test.exs creates an appointment with `:attach_stripe_session`; mirror with `square_order_id`). Then run:

```bash
mix test test/driveway_os_web/controllers/square_webhook_controller_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os_web/controllers/square_webhook_controller.ex \
        lib/driveway_os_web/router.ex \
        test/driveway_os_web/controllers/square_webhook_controller_test.exs

git commit -m "SquareWebhookController: HMAC verification + payment.updated → mark_paid"
```

---

## Task 11: Booking flow dual-routing

**Files:**
- Modify: `lib/driveway_os_web/live/booking_live.ex` (`do_post_booking/5` at line ~880)
- Test: extend `test/driveway_os_web/live/booking_live_test.exs` if Square branch can be exercised; otherwise rely on the SquareWebhookController test for end-to-end coverage

- [ ] **Step 1: Read current `do_post_booking/5`**

Open `lib/driveway_os_web/live/booking_live.ex` and find `do_post_booking/5` at line ~880. Current shape:

```elixir
defp do_post_booking(socket, tenant, customer, service, appt) do
  if tenant.stripe_account_id do
    params = checkout_params(tenant, customer, service, appt)

    case StripeClient.create_checkout_session(tenant.stripe_account_id, params) do
      {:ok, %{id: session_id, url: url}} ->
        appt
        |> Ash.Changeset.for_update(:attach_stripe_session, %{
          stripe_checkout_session_id: session_id,
          payment_status: :pending
        })
        |> Ash.update!(authorize?: false, tenant: tenant.id)

        {:noreply, redirect(socket, external: url)}

      {:error, _reason} ->
        {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
    end
  else
    send_confirmation_email(tenant, customer, appt, service)
    {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
  end
end
```

- [ ] **Step 2: Replace with 3-branch cond**

Replace `do_post_booking/5` with a `cond` that routes based on the tenant's payment provider state:

```elixir
defp do_post_booking(socket, tenant, customer, service, appt) do
  cond do
    tenant.stripe_account_id ->
      do_stripe_checkout(socket, tenant, customer, service, appt)

    has_active_square?(tenant) ->
      do_square_checkout(socket, tenant, customer, service, appt)

    true ->
      send_confirmation_email(tenant, customer, appt, service)
      {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
  end
end

defp do_stripe_checkout(socket, tenant, customer, service, appt) do
  params = checkout_params(tenant, customer, service, appt)

  case StripeClient.create_checkout_session(tenant.stripe_account_id, params) do
    {:ok, %{id: session_id, url: url}} ->
      appt
      |> Ash.Changeset.for_update(:attach_stripe_session, %{
        stripe_checkout_session_id: session_id,
        payment_status: :pending
      })
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      {:noreply, redirect(socket, external: url)}

    {:error, _reason} ->
      {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
  end
end

defp do_square_checkout(socket, tenant, customer, service, appt) do
  {:ok, square_conn} = DrivewayOS.Platform.get_active_payment_connection(tenant.id, :square)

  redirect_url = build_post_payment_url(tenant, appt)

  appt_for_charge = %{
    id: appt.id,
    price_cents: appt.price_cents,
    service_name: service.name
  }

  case DrivewayOS.Square.Charge.create_checkout_session(
         square_conn,
         appt_for_charge,
         redirect_url
       ) do
    {:ok, %{checkout_url: url, order_id: order_id}} ->
      appt
      |> Ash.Changeset.for_update(:attach_stripe_session, %{
        square_order_id: order_id,
        payment_status: :pending
      })
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      {:noreply, redirect(socket, external: url)}

    {:error, _reason} ->
      # On Square API failure, fall through to confirmation-only flow.
      # Tenant can manually invoice if needed; webhook will populate
      # square_order_id later if Square eventually completes.
      send_confirmation_email(tenant, customer, appt, service)
      {:noreply, push_navigate(socket, to: ~p"/book/success/#{appt.id}")}
  end
end

defp has_active_square?(tenant) do
  case DrivewayOS.Platform.get_active_payment_connection(tenant.id, :square) do
    {:ok, _} -> true
    _ -> false
  end
end

defp build_post_payment_url(tenant, appt) do
  host = Application.fetch_env!(:driveway_os, :platform_host)

  {scheme, port_suffix} =
    if host == "lvh.me" do
      port = endpoint_port() || 4000
      {"http", ":#{port}"}
    else
      {"https", ""}
    end

  "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}/book/success/#{appt.id}"
end

defp endpoint_port do
  Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
  |> Kernel.||([])
  |> Keyword.get(:http, [])
  |> Keyword.get(:port)
end
```

- [ ] **Step 3: Verify compile**

```bash
mix compile
```

Expected: clean.

- [ ] **Step 4: Run booking_live_test.exs**

```bash
mix test test/driveway_os_web/live/booking_live_test.exs
```

Expected: existing Stripe-path tests still pass (they go through the `tenant.stripe_account_id ->` branch unchanged). No new tests in this task — Square's path is covered by the controller test (Task 10) end-to-end.

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os_web/live/booking_live.ex

git commit -m "BookingLive: dual-routing — Stripe / Square / no-payment in do_post_booking"
```

---

## Task 12: `IntegrationsLive` extension — merged table + mobile card-stack

**Files:**
- Modify: `lib/driveway_os_web/live/admin/integrations_live.ex`
- Test: extend `test/driveway_os_web/live/admin/integrations_live_test.exs`

- [ ] **Step 1: Extend the test for Square rows + mobile layout + cross-tenant defense parameterized over resource**

Add to `test/driveway_os_web/live/admin/integrations_live_test.exs`:

```elixir
  describe "PaymentConnection rows" do
    test "Square row appears alongside Zoho row when both connected", ctx do
      connect_zoho!(ctx.tenant.id)
      connect_square!(ctx.tenant.id)

      {:ok, _view, html} = live(ctx.conn, "/admin/integrations")

      assert html =~ "Zoho Books"
      assert html =~ "Square"
      assert html =~ "Accounting"
      assert html =~ "Payment"
    end

    test "Pause button toggles auto_charge_enabled on Square row", ctx do
      connect_square!(ctx.tenant.id)

      {:ok, view, _html} = live(ctx.conn, "/admin/integrations")

      view |> element("button[phx-value-resource='payment']", "Pause") |> render_click()

      {:ok, refreshed} = DrivewayOS.Platform.get_payment_connection(ctx.tenant.id, :square)
      refute refreshed.auto_charge_enabled
    end

    test "Disconnect button clears Square tokens", ctx do
      connect_square!(ctx.tenant.id)

      {:ok, view, _html} = live(ctx.conn, "/admin/integrations")

      view |> element("button[phx-value-resource='payment']", "Disconnect") |> render_click()

      {:ok, refreshed} = DrivewayOS.Platform.get_payment_connection(ctx.tenant.id, :square)
      assert refreshed.access_token == nil
      assert refreshed.disconnected_at != nil
    end

    test "Cross-tenant tampering on Square rows is blocked", ctx do
      {:ok, %{tenant: other_tenant}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "other-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "other-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      other_conn = connect_square!(other_tenant.id)
      {:ok, view, _html} = live(ctx.conn, "/admin/integrations")

      render_click(view, "pause", %{"resource" => "payment", "id" => other_conn.id})

      {:ok, refreshed} = DrivewayOS.Platform.get_payment_connection(other_tenant.id, :square)
      assert refreshed.auto_charge_enabled == true  # not mutated
    end
  end

  describe "UX rules + mobile layout" do
    test "renders min-h-[44px], aria-live, aria-label on action buttons", ctx do
      connect_zoho!(ctx.tenant.id)
      connect_square!(ctx.tenant.id)

      {:ok, _view, html} = live(ctx.conn, "/admin/integrations")

      assert html =~ "min-h-[44px]"
      assert html =~ "aria-live=\"polite\""
      assert html =~ ~r/aria-label=\"(Pause|Resume|Disconnect)/
    end

    test "border-slate-200 alignment with MASTER design system", ctx do
      connect_zoho!(ctx.tenant.id)

      {:ok, _view, html} = live(ctx.conn, "/admin/integrations")

      assert html =~ "border-slate-200"
    end
  end

  defp connect_square!(tenant_id) do
    DrivewayOS.Platform.PaymentConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: tenant_id,
      provider: :square,
      external_merchant_id: "MLR-1",
      access_token: "at",
      refresh_token: "rt",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
    |> Ash.create!(authorize?: false)
  end
```

- [ ] **Step 2: Run test — fails**

```bash
mix test test/driveway_os_web/live/admin/integrations_live_test.exs
```

Expected: failures (no PaymentConnection support in the LV yet).

- [ ] **Step 3: Replace IntegrationsLive with merged-row + mobile-card-stack version**

Replace the entire body of `lib/driveway_os_web/live/admin/integrations_live.ex` with:

```elixir
defmodule DrivewayOSWeb.Admin.IntegrationsLive do
  @moduledoc """
  Tenant admin → integrations page at `/admin/integrations`.

  Lists every connection row for the current tenant — both
  AccountingConnection (Phase 3) and PaymentConnection (Phase 4) —
  in a unified table on desktop and a card-per-row stack on mobile.
  Pause / Resume / Disconnect buttons per row dispatch to the
  resource module identified by the row's `resource` field.

  Phase 4 also aligns borders to MASTER design system
  (`border-slate-200`), adds `min-h-[44px]` touch targets to action
  buttons, `aria-label` to disambiguate same-text buttons across
  rows, and `aria-live="polite"` on the table for screen-reader
  announcement of status changes after pause/resume/disconnect.

  Auth: Customer with role `:admin` in the current tenant.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Platform.{AccountingConnection, PaymentConnection}

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
        {:ok, load_rows(socket)}
    end
  end

  @impl true
  def handle_event("pause", %{"resource" => resource, "id" => id}, socket) do
    with_owned_connection(socket, resource_module(resource), id, fn conn ->
      Ash.Changeset.for_update(conn, :pause, %{})
    end)
  end

  def handle_event("resume", %{"resource" => resource, "id" => id}, socket) do
    with_owned_connection(socket, resource_module(resource), id, fn conn ->
      Ash.Changeset.for_update(conn, :resume, %{})
    end)
  end

  def handle_event("disconnect", %{"resource" => resource, "id" => id}, socket) do
    with_owned_connection(socket, resource_module(resource), id, fn conn ->
      Ash.Changeset.for_update(conn, :disconnect, %{})
    end)
  end

  defp resource_module("payment"), do: PaymentConnection
  defp resource_module("accounting"), do: AccountingConnection

  defp with_owned_connection(socket, resource, id, changeset_fn) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(resource, id, authorize?: false) do
      {:ok, %{tenant_id: ^tenant_id} = conn} ->
        conn |> changeset_fn.() |> Ash.update!(authorize?: false)
        {:noreply, load_rows(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  defp load_rows(socket) do
    tenant_id = socket.assigns.current_tenant.id

    {:ok, accounting_conns} =
      AccountingConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    {:ok, payment_conns} =
      PaymentConnection
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read(authorize?: false)

    rows =
      Enum.map(accounting_conns, &row_from_accounting/1) ++
        Enum.map(payment_conns, &row_from_payment/1)

    Phoenix.Component.assign(socket, :rows, rows)
  end

  defp row_from_accounting(%AccountingConnection{} = c) do
    %{
      id: c.id,
      resource: "accounting",
      provider: c.provider,
      category: "Accounting",
      status: status_text(c, :sync),
      connected_at: c.connected_at,
      last_activity_at: c.last_sync_at,
      last_error: c.last_sync_error,
      auto_enabled: c.auto_sync_enabled,
      disconnected_at: c.disconnected_at
    }
  end

  defp row_from_payment(%PaymentConnection{} = c) do
    %{
      id: c.id,
      resource: "payment",
      provider: c.provider,
      category: "Payment",
      status: status_text(c, :charge),
      connected_at: c.connected_at,
      last_activity_at: c.last_charge_at,
      last_error: c.last_charge_error,
      auto_enabled: c.auto_charge_enabled,
      disconnected_at: c.disconnected_at
    }
  end

  defp status_text(%{disconnected_at: dt}, _) when not is_nil(dt), do: "Disconnected"
  defp status_text(%AccountingConnection{auto_sync_enabled: false}, _), do: "Paused"
  defp status_text(%PaymentConnection{auto_charge_enabled: false}, _), do: "Paused"
  defp status_text(%{last_sync_error: err}, _) when is_binary(err), do: "Error"
  defp status_text(%{last_charge_error: err}, _) when is_binary(err), do: "Error"
  defp status_text(_, _), do: "Active"

  defp status_badge_class("Active"), do: "badge badge-success"
  defp status_badge_class("Paused"), do: "badge badge-warning"
  defp status_badge_class("Disconnected"), do: "badge badge-ghost"
  defp status_badge_class("Error"), do: "badge badge-error"
  defp status_badge_class(_), do: "badge"

  defp provider_label(:zoho_books), do: "Zoho Books"
  defp provider_label(:square), do: "Square"
  defp provider_label(p), do: p |> Atom.to_string() |> String.capitalize()

  defp format_date(nil), do: ""
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-slate-900 mb-4">Integrations</h1>

      <%= if @rows == [] do %>
        <div class="bg-slate-50 rounded-lg p-8 text-center text-slate-600">
          <p>No integrations connected yet.</p>
          <p class="text-sm mt-2">
            Connect from the dashboard checklist on
            <.link navigate={~p"/admin"} class="link link-primary">/admin</.link>.
          </p>
        </div>
      <% else %>
        <div class="hidden md:block overflow-x-auto" aria-live="polite">
          <table class="table">
            <thead>
              <tr>
                <th scope="col">Provider</th>
                <th scope="col">Category</th>
                <th scope="col">Status</th>
                <th scope="col">Connected</th>
                <th scope="col">Last activity</th>
                <th scope="col">Last error</th>
                <th scope="col">Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for row <- @rows do %>
                <tr>
                  <td class="font-medium">{provider_label(row.provider)}</td>
                  <td class="text-slate-600">{row.category}</td>
                  <td><span class={status_badge_class(row.status)}>{row.status}</span></td>
                  <td class="text-sm text-slate-600">{format_date(row.connected_at)}</td>
                  <td class="text-sm text-slate-600">{format_datetime(row.last_activity_at)}</td>
                  <td class="text-sm text-error truncate max-w-xs">{row.last_error}</td>
                  <td>
                    <.action_buttons row={row} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <div class="md:hidden space-y-3" aria-live="polite">
          <%= for row <- @rows do %>
            <div class="card bg-base-100 shadow-md border border-slate-200">
              <div class="card-body p-4 space-y-2">
                <div class="flex justify-between items-start gap-2">
                  <div>
                    <h3 class="font-semibold text-slate-900">{provider_label(row.provider)}</h3>
                    <p class="text-xs text-slate-600">{row.category}</p>
                  </div>
                  <span class={status_badge_class(row.status)}>{row.status}</span>
                </div>
                <div class="text-xs text-slate-600">
                  Connected {format_date(row.connected_at)}
                  <%= if row.last_activity_at do %>
                    · Last activity {format_datetime(row.last_activity_at)}
                  <% end %>
                </div>
                <p :if={row.last_error} class="text-xs text-error">{row.last_error}</p>
                <div class="flex gap-2 flex-wrap pt-2">
                  <.action_buttons row={row} />
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :row, :map, required: true

  defp action_buttons(assigns) do
    ~H"""
    <%= if @row.auto_enabled do %>
      <button
        phx-click="pause"
        phx-value-resource={@row.resource}
        phx-value-id={@row.id}
        class="btn btn-sm min-h-[44px]"
        aria-label={"Pause #{provider_label(@row.provider)} integration"}
      >Pause</button>
    <% else %>
      <%= if is_nil(@row.disconnected_at) do %>
        <button
          phx-click="resume"
          phx-value-resource={@row.resource}
          phx-value-id={@row.id}
          class="btn btn-sm btn-primary min-h-[44px]"
          aria-label={"Resume #{provider_label(@row.provider)} integration"}
        >Resume</button>
      <% end %>
    <% end %>
    <%= if is_nil(@row.disconnected_at) do %>
      <button
        phx-click="disconnect"
        phx-value-resource={@row.resource}
        phx-value-id={@row.id}
        class="btn btn-sm btn-error min-h-[44px]"
        aria-label={"Disconnect #{provider_label(@row.provider)} integration"}
      >Disconnect</button>
    <% end %>
    """
  end
end
```

- [ ] **Step 4: Run test**

```bash
mix test test/driveway_os_web/live/admin/integrations_live_test.exs
```

Expected: all green (Phase 3's existing tests still pass — the AccountingConnection rows still render correctly. New Phase 4 tests pass too.)

- [ ] **Step 5: Run full suite**

```bash
mix test
```

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/driveway_os_web/live/admin/integrations_live.ex \
        test/driveway_os_web/live/admin/integrations_live_test.exs

git commit -m "IntegrationsLive: merged PaymentConnection + AccountingConnection rows + mobile card-stack + MASTER alignment"
```

---

## Task 13: Runtime config + DEPLOY.md

**Files:**
- Modify: `config/runtime.exs`
- Modify: `DEPLOY.md`

- [ ] **Step 1: Extend runtime config**

Edit `config/runtime.exs`. Find the existing `if config_env() != :test do` block where Stripe + Postmark + Zoho env vars are read. Extend the keyword list:

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
    zoho_affiliate_ref_id: System.get_env("ZOHO_AFFILIATE_REF_ID"),
    square_app_id: System.get_env("SQUARE_APP_ID") || "",
    square_app_secret: System.get_env("SQUARE_APP_SECRET") || "",
    square_webhook_signature_key: System.get_env("SQUARE_WEBHOOK_SIGNATURE_KEY") || "",
    square_affiliate_ref_id: System.get_env("SQUARE_AFFILIATE_REF_ID")

  # Optional sandbox/prod toggle for Square. Defaults to prod
  # (https://connect.squareup.com) when unset.
  case System.get_env("SQUARE_OAUTH_BASE") do
    nil -> :ok
    "" -> :ok
    base -> config :driveway_os, :square_oauth_base, base
  end

  case System.get_env("SQUARE_API_BASE") do
    nil -> :ok
    "" -> :ok
    base -> config :driveway_os, :square_api_base, base
  end
end
```

- [ ] **Step 2: Update DEPLOY.md**

Edit `DEPLOY.md`. Find the per-tenant integrations env-var table. Add 4 new rows after the existing Zoho rows:

```markdown
| `SQUARE_APP_ID` | Square OAuth application id (one per platform — every tenant uses the same one). Get from the Square Developer Dashboard at https://developer.squareup.com/apps. |
| `SQUARE_APP_SECRET` | Paired with `SQUARE_APP_ID`. |
| `SQUARE_WEBHOOK_SIGNATURE_KEY` | HMAC-SHA256 signing key for Square webhook signature verification. From the same Square Developer Dashboard's webhook configuration. |
| `SQUARE_AFFILIATE_REF_ID` | Optional. Platform-level Square affiliate referral code; appended to outbound Square OAuth URLs as `?ref=<value>`. Leave unset until enrolled in Square's referral program. |
```

Optionally add a brief note about `SQUARE_OAUTH_BASE` / `SQUARE_API_BASE` for sandbox setups:

```markdown
> Square sandbox: set `SQUARE_OAUTH_BASE=https://connect.squareupsandbox.com` and `SQUARE_API_BASE=https://connect.squareupsandbox.com/v2` for testing. Defaults to prod when unset.
```

- [ ] **Step 3: Run full suite**

```bash
mix test
```

Expected: 0 failures.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs DEPLOY.md
git commit -m "Config: SQUARE_APP_ID + SQUARE_APP_SECRET + SQUARE_WEBHOOK_SIGNATURE_KEY + SQUARE_AFFILIATE_REF_ID"
```

---

## Task 14: Final verification + push

- [ ] **Step 1: Confirm clean working tree**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Run the full suite**

```bash
mix test
```

Expected: 0 failures. Phase 3 ended at 700 tests; Phase 4 adds roughly +35-40 (8 PaymentConnection + 9 OAuth + 9 Square adapter + 5 controller + 3 webhook + 2 charge + 5 picker + 5 IntegrationsLive merge).

- [ ] **Step 3: Push**

```bash
git push origin main
```

Expected: push succeeds. Phase 4's commits are visible on `origin/main`.

---

## Self-review

**Spec coverage:**

| Spec section | Covered by task |
|---|---|
| Constraints / V1 = Square + picker UI + charge-side end-to-end | All tasks |
| Constraints / Phase 4 ships Square only (Phase 4b is SendGrid) | Out of scope confirmed |
| Constraints / `Platform.PaymentConnection` resource | Task 1 |
| Constraints / `:reconnect` action incorporated preemptively | Task 1 |
| Constraints / Picker = side-by-side cards | Task 7 |
| Constraints / No alternate entry point for already-Stripe tenants | Task 7 (`complete?` returns true if any provider connected → wizard skips) |
| Constraints / Multi-active per category not supported | Task 7 + Task 11 (`cond` order: Stripe → Square → neither, never both) |
| Constraints / `auto_charge_enabled` reserved on PaymentConnection | Task 1 |
| Constraints / Square sandbox/prod via env override | Task 3 (`SQUARE_OAUTH_BASE` / `SQUARE_API_BASE`) + Task 13 |
| Constraints / IntegrationsLive merged-table | Task 12 |
| Constraints / UI follows MASTER + ui-ux-pro-max | Tasks 7 + 12 (44px, motion-reduce, slate-600, aria-label, aria-live) |
| Constraints / Square charge-side end-to-end | Tasks 8 + 10 + 11 |
| Constraints / Square Checkout API (Payment Links) | Task 8 |
| Constraints / Dual-routing in booking flow | Task 11 |
| Constraints / SquareWebhookController parallel to Stripe | Task 10 |
| Constraints / No per-charge platform fee on Square in V1 | Documented; no code path takes a fee |
| Architecture / Module layout — PaymentConnection | Task 1 |
| Architecture / Module layout — Square facade + OAuth + Client + Charge | Tasks 3 + 4 + 8 |
| Architecture / Module layout — SquareWebhookController | Task 10 |
| Architecture / Module layout — Onboarding adapter | Task 5 |
| Architecture / Module layout — controller | Task 6 |
| Architecture / Modified — Registry | Task 5 |
| Architecture / Modified — OauthState constraint | Task 2 |
| Architecture / Modified — Steps.Payment generalization | Task 7 |
| Architecture / Modified — Appointment.square_order_id | Task 9 |
| Architecture / Modified — booking flow dual-routing | Task 11 |
| Architecture / Modified — IntegrationsLive merge | Task 12 |
| Architecture / Modified — router | Tasks 6 + 10 |
| Architecture / Modified — runtime/test/config + DEPLOY | Tasks 3 + 13 |
| Architecture / Affiliate ties — first prod caller of tag_url for Square | Task 6 |
| Spec deviation #1 — OauthState constraint generates no migration | Task 2 |
| Spec deviation #2 — booking_live.ex:880-902 dual-routing call site | Task 11 |
| Spec deviation #3 — webhook raw-body via existing CacheBodyReader | Task 10 |
| Spec deviation #4 — `platform_payment_connections` table prefix | Task 1 |

**Type / signature consistency check:**

- `PaymentConnection` actions (`:connect`, `:reconnect`, `:refresh_tokens`, `:record_charge_success`, `:record_charge_error`, `:disconnect`, `:pause`, `:resume`) — used identically across Tasks 1, 4, 8, 11, 12. ✓
- `Square.Client` callbacks (`exchange_oauth_code/2`, `refresh_access_token/1`, `api_get/3`, `api_post/3`, `create_payment_link/2`) — same signatures in Tasks 3 (defn), 4 (caller), 8 (caller). ✓
- `Square.OAuth` quartet (`oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`, `configured?/0`) — same signatures in Tasks 4 (defn), 5 (caller), 6 (caller). ✓
- `Square.Charge.create_checkout_session/4` returning `{:ok, %{checkout_url, payment_link_id, order_id}}` — used in Task 8 (defn), Task 11 (caller). ✓
- `Platform.get_payment_connection/2` returns `{:ok, conn} | {:error, :not_found}`; `get_active_payment_connection/2` returns `{:ok, conn} | {:error, :no_active_connection}` — consistent across Tasks 1 (defn), 4, 5, 11. ✓
- Webhook signature pattern: `:crypto.mac(:hmac, :sha256, key, full_url <> body) |> Base.encode64()` — same in test (Task 10) and controller (Task 10). ✓
- `Affiliate.log_event/4` signature (Phase 2) — used in Task 6. ✓

**Placeholder scan:**
- Three test helpers stubbed with `raise` — each has a comment pointing the implementer at the existing pattern to copy from (`zoho_oauth_controller_test.exs`, `stripe_webhook_controller_test.exs`, the existing book/mark_paid patterns). Implementer wires these at execution time.
- Otherwise no "TBD" / "TODO" / vague-instruction patterns.

**Bite-size check:**
- Each step is one concrete action.
- Each task ends in a commit.
- Fourteen tasks, each ~5-15 minutes of focused work for an engineer with the context.

If you find issues during execution, stop and ask — don't guess.
