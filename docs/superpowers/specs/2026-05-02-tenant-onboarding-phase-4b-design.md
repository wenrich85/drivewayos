# Phase 4b design: Resend (email, second-of-category) + Steps.PickerStep macro

**Status:** Approved design. Plan next.
**Date:** 2026-05-02
**Owner:** Wendell Richards
**Scope:** Phase 4b of the tenant-onboarding roadmap — second provider per
category for the email category. V1 ships Resend (NOT SendGrid) end-to-end:
API-first provisioning + EmailConnection resource + Mailer routing extension.
Plus the `Onboarding.Steps.PickerStep` macro that DRYs the multi-card picker
shape Phase 4 introduced for Steps.Payment, with Steps.Email as the second
caller. SendGrid is deferred to Phase 5+ via paste-a-key.

## Why this exists

Phase 4 closed the "second provider per category" loop for payment (Stripe +
Square). Phase 4b closes the same loop for email (Postmark + Resend) and
generalizes the picker UI machinery via the `Steps.PickerStep` macro — Phase
5+ category steps reuse it mechanically.

The tenant-facing value of "Postmark vs Resend" choice is modest in V1: both
providers send `noreply@drivewayos.com` emails (per Phase 1's deferred
sending-domain decision), so the deliverability backbone is invisible to the
tenant. The architectural value is the win:

1. `Steps.PickerStep` macro proves the picker generalizes — Phase 4's
   Steps.Payment refactors to use it; future category steps lean on it for
   ~10-line implementations instead of ~70.
2. `Platform.EmailConnection` resource establishes the connection-resource
   pattern for email, parallel to PaymentConnection (Phase 4) and
   AccountingConnection (Phase 3). Phase 5+ Mailgun / SES / etc. add rows
   instead of columns.
3. `Mailer.for_tenant/1` routing extension is the email "charge-side" — once
   a tenant connects Resend, transactional emails actually flow through
   Resend's backbone. Without this, "connect Resend" would be misleading.

Resend over SendGrid for V1 because:
- SendGrid's Subuser API requires Pro plan ($89.95/mo) — a real cost barrier.
- SendGrid has no OAuth flow for transactional sending (their OAuth covers
  Marketing Campaigns only).
- Paste-a-key for SendGrid breaks Phase 1's "no API key paste" promise.
- Resend supports API-first provisioning natively (`POST /api-keys`), no plan
  tier gating, and their API surface is modern and clean.

## Constraints + decisions (locked)

| # | Decision | Rationale |
|---|---|---|
| 1 | **Phase 4b ships Resend, NOT SendGrid.** SendGrid is Phase 5+. | API-first programmatic provisioning is feasible for Resend without a Pro-plan cost barrier. SendGrid's API doesn't support our preferred shape; deferring it preserves Phase 1's "no API key paste" promise. |
| 2 | **API-first provisioning** (mirrors Phase 1 Postmark pattern). `provision/2` POSTs to Resend's `/api-keys` endpoint and persists the returned api_key on `EmailConnection`. | Resend's API supports programmatic key creation. Same architectural shape as Postmark — Phase 4b's adapter is mostly mechanical. |
| 3 | **Storage = new `Platform.EmailConnection` resource** (platform-tier, no multitenancy). One row per `(tenant, email_provider)`. Postmark stays on `Tenant` (Phase 1) — no data migration. | Same call as Phase 4's Square (PaymentConnection). New providers from Phase 4b onward use the connection-resource pattern. Asymmetry documented: Phase-1-shipped-first. |
| 4 | **Picker abstraction = `Onboarding.Steps.PickerStep` macro.** Steps.Payment + Steps.Email both `use` it. Phase 4's Steps.Payment refactors from inline picker code to ~10-line module. | Two callers proven (Payment + Email), structurally identical render + complete? semantics. Macro generates default impls; using-step overrides only what's unique (id, title, intro copy). Future category steps reuse mechanically. |
| 5 | **`Mailer.for_tenant/1` extends for routing** — checks active `EmailConnection{:resend}` first → `Swoosh.Adapters.Resend`; falls back to `Tenant.postmark_api_key` → `Swoosh.Adapters.Postmark`; falls back to `[]` (platform SMTP). | The "charge-side" for email. ALL 17 existing `Mailer.deliver(email, Mailer.for_tenant(tenant))` send sites stay byte-identical — the routing change is invisible to them. One-line change in the function body. |
| 6 | **Resend takes precedence over Postmark** when both are connected (hardcoded check order in `Mailer.for_tenant/1`). | Wizard's "any one provider connected = step done" semantics mean a tenant shouldn't have both, but if they do (seed data, support intervention), the second-shipped provider wins by hardcoded precedence. No `connected_at` comparison — just check-Resend-first / fall-back-to-Postmark. Phase 5+ providers append after Resend in the same chain. |
| 7 | **Welcome email is the deliverability probe** (matches Phase 1 Postmark + Phase 3 review fix). After provisioning, send a welcome email through the just-provisioned api_key. If it fails, surface the error in the wizard. | A bad api_key from Resend's response (e.g., quota issue, account lockout) is caught at provision time, not silently broken at the next booking confirmation. |
| 8 | **`affiliate_config/0` returns nil for Resend** in V1 (no URL to tag — API-first means no OAuth start URL). `tenant_perk/0` also nil until we enroll. | Consistent with Phase 1 Postmark — same API-first pattern, same nil affiliate config in V1. Easy to flip on later if Resend's affiliate program enrollment URL appears. |
| 9 | **Per-tenant custom sending domains** stay deferred to Phase 5+. V1 sends from `noreply@drivewayos.com` for both Postmark and Resend tenants. | Phase 1 deferred this; Phase 4b inherits the same posture. Custom domains are DNS UX work that doesn't fit Phase 4b's scope. |
| 10 | **Resend webhooks** (delivery events, bounces) NOT in scope. | Phase 4 shipped a webhook for Square because charging required it (mark_paid trigger). Email has no analogous trigger — Mailer.deliver returns synchronously. Bounce/complaint handling is observability work, Phase 5+. |
| 11 | **`/admin/integrations` extends to a third row category (Email).** Postmark stays absent (lives on Tenant; same asymmetry as Stripe). | Phase 4 already extended IntegrationsLive to merge two resource types. Adding a third (`EmailConnection`) is mechanical — `resource_module/1` gets `"email" -> EmailConnection`, `load_rows/1` queries one more resource. |

## Architecture

### Module layout

**New modules:**

| Path | Responsibility |
|---|---|
| `lib/driveway_os/onboarding/steps/picker_step.ex` | Macro. `defmacro __using__(opts)` generates `complete?/1`, `render/1`, `submit/2`, `providers_for_picker/1` from `category:` + `intro_copy:` args. Steps that need step-specific overrides use `defoverridable`. |
| `lib/driveway_os/platform/email_connection.ex` | Ash resource. Platform-tier (no multitenancy). Per-(tenant, email provider) api_key + lifecycle state. Mirrors PaymentConnection's shape with email-flavored field names (`auto_send_enabled`, `last_send_at`, `external_key_id`). |
| `lib/driveway_os/notifications/resend_client.ex` | `@behaviour` for Resend HTTP layer + concrete impl using Req. Two callbacks: `create_api_key/1`, `delete_api_key/1`. Mockable in tests via Mox. |
| `lib/driveway_os/notifications/resend_client/http.ex` | Concrete Req-based impl. Reads `RESEND_API_KEY` (master account token) from app env. |
| `lib/driveway_os/onboarding/providers/resend.ex` | `Onboarding.Provider` adapter. **API-first** — `provision/2` provisions via `ResendClient.create_api_key/1`, persists tokens on `EmailConnection`, sends welcome email through the new key as the deliverability probe. |
| `priv/repo/migrations/<ts>_create_platform_email_connections.exs` | Generated via `mix ash_postgres.generate_migrations`. |

**Modified modules:**

| Path | Change |
|---|---|
| `lib/driveway_os/platform.ex` | Register `EmailConnection` in domain. Add `Platform.get_email_connection/2` + `get_active_email_connection/2` helpers. |
| `lib/driveway_os/onboarding/registry.ex` | Add `Providers.Resend` to `@providers`. |
| `lib/driveway_os/onboarding/steps/payment.ex` | Refactor from inline picker code to `use Steps.PickerStep, category: :payment, intro_copy: "..."`. ~70 LOC → ~10 LOC. |
| `lib/driveway_os/onboarding/steps/email.ex` | Refactor from Phase 1 single-card render to `use Steps.PickerStep, category: :email, intro_copy: "..."`. ~50 LOC → ~10 LOC. |
| `lib/driveway_os/mailer.ex` | Extend `for_tenant/1` to dispatch on EmailConnection first, then Postmark, then default. ALL existing send-sites stay unchanged. |
| `lib/driveway_os_web/live/admin/integrations_live.ex` | Extend `load_rows/1` to query `EmailConnection` alongside Payment + Accounting. Add `row_from_email/1`. Extend `resource_module/1` and `provider_label/1`. |
| `config/runtime.exs` | Add `resend_api_key` (master account token), `resend_affiliate_ref_id` env reads. |
| `config/test.exs` | Test placeholders + Mox `:resend_client` config. |
| `config/config.exs` | Default `:resend_client` to `ResendClient.Http`. |
| `test/test_helper.exs` | `Mox.defmock(DrivewayOS.Notifications.ResendClient.Mock, for: ResendClient)`. |
| `DEPLOY.md` | Add `RESEND_API_KEY`, `RESEND_AFFILIATE_REF_ID` rows. |

### Data model

```elixir
defmodule DrivewayOS.Platform.EmailConnection do
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "platform_email_connections"
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
      constraints one_of: [:resend]   # extends in Phase 5+
    end

    attribute :external_key_id, :string, public?: true   # Resend's api_key id
    attribute :api_key, :string, sensitive?: true, public?: false

    attribute :auto_send_enabled, :boolean, default: true, allow_nil?: false, public?: true
    attribute :connected_at, :utc_datetime_usec
    attribute :disconnected_at, :utc_datetime_usec
    attribute :last_send_at, :utc_datetime_usec
    attribute :last_send_error, :string

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
      accept [:tenant_id, :provider, :external_key_id, :api_key]
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :reconnect do
      accept [:external_key_id, :api_key]
      change set_attribute(:disconnected_at, nil)
      change set_attribute(:auto_send_enabled, true)
      change set_attribute(:connected_at, &DateTime.utc_now/0)
    end

    update :record_send_success do
      change set_attribute(:last_send_at, &DateTime.utc_now/0)
      change set_attribute(:last_send_error, nil)
    end

    update :record_send_error do
      accept [:last_send_error]
    end

    update :disconnect do
      change set_attribute(:api_key, nil)
      change set_attribute(:external_key_id, nil)
      change set_attribute(:disconnected_at, &DateTime.utc_now/0)
      change set_attribute(:auto_send_enabled, false)
    end

    update :pause do
      change set_attribute(:auto_send_enabled, false)
    end

    update :resume do
      change set_attribute(:auto_send_enabled, true)
    end
  end
end
```

API-first means no `refresh_token` / `access_token_expires_at` (Resend api_keys
don't expire). Otherwise the resource shape is parallel to PaymentConnection
and AccountingConnection.

### `Steps.PickerStep` macro

```elixir
defmodule DrivewayOS.Onboarding.Steps.PickerStep do
  @moduledoc """
  Macro for wizard steps that render an N-card picker over a provider
  category. Generates `complete?/1`, `render/1`, `submit/2`, and
  `providers_for_picker/1` from one `category:` arg.

  Steps that need step-specific overrides (id/0, title/0) declare
  them after `use`-ing the macro. The macro's defaults are
  `defoverridable` for future divergence.

  Example:

      defmodule DrivewayOS.Onboarding.Steps.Payment do
        use DrivewayOS.Onboarding.Steps.PickerStep,
          category: :payment,
          intro_copy: "Pick the payment processor..."

        @impl true
        def id, do: :payment

        @impl true
        def title, do: "Take card payments"
      end
  """

  defmacro __using__(opts) do
    category = Keyword.fetch!(opts, :category)
    intro_copy = Keyword.fetch!(opts, :intro_copy)

    quote do
      @behaviour DrivewayOS.Onboarding.Step
      use Phoenix.Component

      alias DrivewayOS.Onboarding.{Affiliate, Registry}
      alias DrivewayOS.Platform.Tenant

      @category unquote(category)
      @intro_copy unquote(intro_copy)

      @impl true
      def complete?(%Tenant{} = tenant) do
        Registry.by_category(@category)
        |> Enum.any?(& &1.setup_complete?(tenant))
      end

      @impl true
      def render(assigns) do
        cards = providers_for_picker(assigns.current_tenant)
        assigns = assigns |> Map.put(:cards, cards) |> Map.put(:intro_copy, @intro_copy)

        ~H"""
        <div class="space-y-4">
          <p class="text-sm text-slate-600">{@intro_copy}</p>
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
        Registry.by_category(@category)
        |> Enum.filter(& &1.configured?())
        |> Enum.reject(& &1.setup_complete?(tenant))
        |> Enum.map(fn mod -> Map.put(mod.display(), :id, mod.id()) end)
      end

      defoverridable complete?: 1, render: 1, submit: 2
    end
  end
end
```

**Refactored Steps.Payment:**

```elixir
defmodule DrivewayOS.Onboarding.Steps.Payment do
  @moduledoc """
  Payment wizard step. Generic over N providers in the `:payment`
  category via `Steps.PickerStep`.
  """
  use DrivewayOS.Onboarding.Steps.PickerStep,
    category: :payment,
    intro_copy: "Pick the payment processor you want to use. " <>
                "You can change later by emailing support."

  @impl true
  def id, do: :payment

  @impl true
  def title, do: "Take card payments"
end
```

**New Steps.Email** (replaces Phase 1's single-card version):

```elixir
defmodule DrivewayOS.Onboarding.Steps.Email do
  @moduledoc """
  Email wizard step. Generic over N providers in the `:email`
  category via `Steps.PickerStep`. As of Phase 4b, both providers
  (Postmark and Resend) are API-first — picker cards route to each
  provider's `/onboarding/<provider>/start` page which submits a
  one-click "provision now" form (no OAuth redirect).
  """
  use DrivewayOS.Onboarding.Steps.PickerStep,
    category: :email,
    intro_copy: "Pick the email provider for booking confirmations and reminders. " <>
                "You can change later by emailing support."

  @impl true
  def id, do: :email

  @impl true
  def title, do: "Send booking emails"
end
```

### Resend integration (API-first)

```elixir
defmodule DrivewayOS.Notifications.ResendClient do
  @callback create_api_key(name :: String.t()) ::
              {:ok, %{key_id: String.t(), api_key: String.t()}}
              | {:error, term()}

  @callback delete_api_key(key_id :: String.t()) ::
              :ok | {:error, term()}

  def impl, do: Application.get_env(:driveway_os, :resend_client, __MODULE__.Http)
  defdelegate create_api_key(name), to: __MODULE__.Http
  defdelegate delete_api_key(key_id), to: __MODULE__.Http
end
```

`ResendClient.Http` POSTs to `https://api.resend.com/api-keys` with the master
account `RESEND_API_KEY` as the auth header. Returns the new key's `id` +
`token`.

`Onboarding.Providers.Resend.provision/2`:

```elixir
def provision(%Tenant{} = tenant, _params) do
  with {:ok, %{key_id: kid, api_key: key}} <-
         ResendClient.create_api_key("drivewayos-#{tenant.slug}"),
       {:ok, conn} <- save_connection(tenant, kid, key),
       :ok <- send_welcome_email(tenant, conn) do
    {:ok, conn}
  end
end
```

`send_welcome_email/2` mirrors Phase 1 Postmark — sends through the
just-provisioned key via `Mailer.for_tenant(reloaded_tenant)`, which now
routes to Resend (since the tenant has an active EmailConnection at this
point). Failure surfaces in the wizard.

### `Mailer.for_tenant/1` routing extension

```elixir
def for_tenant(%Tenant{} = tenant) do
  cond do
    not Application.get_env(:swoosh, :api_client) ->
      []

    conn = active_resend_connection(tenant) ->
      [adapter: Swoosh.Adapters.Resend, api_key: conn.api_key]

    is_binary(tenant.postmark_api_key) and tenant.postmark_api_key != "" ->
      [adapter: Swoosh.Adapters.Postmark, api_key: tenant.postmark_api_key]

    true ->
      []
  end
end

defp active_resend_connection(tenant) do
  case DrivewayOS.Platform.get_active_email_connection(tenant.id, :resend) do
    {:ok, conn} -> conn
    _ -> nil
  end
end
```

The test-mode override (`Application.get_env(:swoosh, :api_client)` returning
false) stays — Phase 1's Mailer test pattern preserved.

### IntegrationsLive third-category extension

`load_rows/1` queries one more resource. `row_from_email/1` mirrors
`row_from_payment/1` with email-flavored fields. `resource_module/1` adds
`"email" -> EmailConnection`. `provider_label/1` adds
`:resend -> "Resend"`.

The mobile card-stack + desktop table already handle multiple categories
(Payment + Accounting in Phase 4) — adding a third (Email) is purely
additive. UX rules from MASTER + ui-ux-pro-max (44px touch targets,
motion-reduce, slate-600, border-slate-200, aria-live, aria-label) inherit
unchanged.

### Affiliate ties

Phase 4b inherits Phase 1's Postmark API-first affiliate pattern unchanged:

- `Onboarding.Providers.Resend.affiliate_config/0` returns `nil` in V1
  (API-first means no OAuth start URL to tag).
- `tenant_perk/0` returns `nil`.
- `Affiliate.log_event/4` fires `:click` when the tenant clicks the
  picker card's CTA (handled in the provider's own controller path that
  the card links to), then `:provisioned` after the api_key lands.

No new affiliate event types; no taxonomy change.

## What "done" looks like

After Phase 4b ships:

1. A platform with `RESEND_API_KEY` (master account token) configured surfaces TWO email cards on the wizard's Email step for tenants who haven't connected an email provider yet: "Set up email via Postmark" + "Set up email via Resend."
2. New tenant clicks "Set up email via Resend" → API-first provisioning fires → Resend api_key created on our master account → `EmailConnection{provider: :resend, api_key: "..."}` row exists → welcome email arrives in admin's inbox via Resend → wizard advances.
3. `Steps.Email.complete?/1` returns true → wizard skips the step on subsequent visits.
4. Tenant who already connected Postmark (Phase 1) does NOT see Resend in the wizard (Steps.Email is already complete). To switch — same path as Square: support intervention.
5. `/admin/integrations` shows three categories of rows: Payment (Square), Accounting (Zoho), Email (Resend). Pause / Resume / Disconnect work for each.
6. Tenant takes a customer booking → confirmation email is sent → `Mailer.for_tenant(tenant)` returns `[adapter: Swoosh.Adapters.Resend, api_key: ...]` → email goes through Resend's backbone → arrives at the customer's inbox.
7. `Steps.Payment` (refactored) renders identically to Phase 4 — picker UI unchanged from the user's perspective. Module shrinks from ~70 LOC to ~10 LOC.
8. **Architectural validation:** `Steps.PickerStep` macro proves the picker generalizes. Phase 5+ category steps (e.g., Mailgun, SES) reuse it mechanically.

## Out of scope

- **SendGrid** — Phase 5+ via paste-a-key when there's real demand.
- **Resend webhooks** (delivery events, bounces, complaints). Phase 5+ if reconciliation/observability needs justify it.
- **Per-tenant custom sending domains.** V1 stays on `noreply@drivewayos.com` per Phase 1's deferred decision.
- **Per-message Mailer override** (force this email through provider X regardless of tenant connection state). V1 dispatches solely on tenant connection. Phase 5+ if needed.
- **Migrating existing Postmark data into EmailConnection.** Postmark stays on `Tenant`. New email providers from Phase 4b onward use the connection-resource pattern.
- **`api_key` encryption at rest.** Same posture as Phase 1's `postmark_api_key` plaintext storage. Cross-cutting hardening pass scheduled separately.
- **Provider switching UX** (a tenant who already chose Postmark wanting to switch to Resend). Same posture as Square — support-driven for V1.
- **Multi-active per category.** A tenant with Postmark connected cannot also connect Resend in V1. Same constraint as Phase 4 payment.

## Decisions deferred to plan-writing

- **Test layout for the macro.** Probably `test/driveway_os/onboarding/steps/picker_step_test.exs` exercising the macro directly via a synthetic step module, plus extending the existing Steps.Payment + Steps.Email tests to verify their outputs match the pre-refactor shape. Plan reads + confirms.
- **Whether to push the welcome-email send through `Mailer.for_tenant/1` (which now routes to Resend post-provisioning) or use a one-shot adapter override.** Phase 1 Postmark used the routing path; mirroring that for Resend is the obvious choice but plan verifies no edge case in test mode.
- **Phase 1 Steps.Email's existing test coverage** — existing tests assert single-card render. Need to update for the multi-card picker shape. Plan reads existing tests and adapts assertions.
- **Whether `Steps.PickerStep` macro generates an `id/0` + `title/0` default that the using-step overrides, or requires explicit declaration.** Plan picks based on macro hygiene.

## Next step

Implementation plan for Phase 4b — task-by-task breakdown of:

1. `Onboarding.Steps.PickerStep` macro
2. Refactor `Steps.Payment` to use the macro (verify Phase 4 tests still pass)
3. `Platform.EmailConnection` resource + migration + helpers
4. `Notifications.ResendClient` HTTP behaviour + Http impl + Mox + config wiring
5. `Onboarding.Providers.Resend` adapter + Registry registration
6. Refactor `Steps.Email` to use the macro (verify Phase 1 tests still pass / adapt to picker shape)
7. `Mailer.for_tenant/1` routing extension
8. `IntegrationsLive` third-category (Email) extension
9. Runtime config (`RESEND_*`) + DEPLOY.md
10. Final verification + push

Each task has its own tests and lands behind `mix test` green. The plan
follows the same TDD shape Phases 1-4 used.
