# DrivewayOS Design System

> **Single coherent system across customer-facing, tenant-admin, and platform-admin surfaces.**
> Built off the [`ui-ux-pro-max`](https://github.com/wenrich85/MobileCarWash/) skill's "Minimalism & Swiss Style" anchor + "Trust & Authority" component vocabulary.
> Companion file: `design-system/MASTER.md` (machine-readable Master record).

## 1. Visual style

**Style anchor:** Minimalism & Swiss Style (rejected the skill's default 3D suggestion — wrong product type).

- Grid-based, mathematical spacing (8px base unit)
- Generous whitespace
- Sharp shadows when used; never decorative shadow stacking
- Single accent per surface (tenant brand color on customer surfaces; platform indigo on admin)
- WCAG AAA contrast across all text
- No emoji icons (Heroicons SVG only — see § 6)

**What this is NOT:**
- ❌ Glassmorphism (poor light-mode contrast)
- ❌ Brutalism (wrong vibe for a service business)
- ❌ AI purple/pink gradients
- ❌ 3D / hyperrealism (perf + a11y both poor)

## 2. Color palette

### 2.1 Platform palette (DrivewayOS-branded admin + marketing surfaces)

```
role        | hex      | tailwind name        | usage
------------|----------|----------------------|-----------------------------------
primary     | #2563EB  | blue-600             | platform admin, marketing CTAs
primary-soft| #3B82F6  | blue-500             | hover, secondary actions
accent      | #F97316  | orange-500           | primary CTA on marketing
success     | #16A34A  | green-600            | paid/confirmed/active states
warning     | #F59E0B  | amber-500            | pending/onboarding states
danger      | #DC2626  | red-600              | destructive actions, suspended
ink         | #0F172A  | slate-900            | body text, headings
ink-muted   | #475569  | slate-600            | secondary text
ink-faint   | #94A3B8  | slate-400            | tertiary, placeholders
border      | #E2E8F0  | slate-200            | dividers, card borders
surface     | #FFFFFF  | white                | cards
surface-alt | #F8FAFC  | slate-50             | page background
```

### 2.2 Tenant brand layer (customer-facing only)

Each tenant ships with `primary_color_hex` (default `#0d9488` if unset). On any surface that reads `@current_tenant`, expose it as a CSS variable:

```css
:root {
  --tenant-primary: #0d9488;
}
```

The root layout already sets this via inline `<style>` from `@current_tenant.primary_color_hex`. Components reference it as `style="background-color: var(--tenant-primary)"` (avoid raw Tailwind classes for tenant-tinted elements — Tailwind's JIT can't resolve runtime hex).

**Tenant-branded:** primary CTA on customer landing, "Book a wash" button, accent borders on confirmation pages.
**Always platform-blue (NOT tenant-tinted):** error/success states, status badges, anything in `/admin`.

### 2.3 Stripe Connect status colors

| `stripe_account_status` | Badge class |
|---|---|
| `:none` / `:pending` | `badge-warning` |
| `:enabled` | `badge-success` |
| `:restricted` | `badge-error` |

## 3. Typography

**Single font: Inter.** One font keeps the bundle small and the hierarchy lives in weight + size.

```html
<link rel="stylesheet" href="https://rsms.me/inter/inter.css" />
```

```css
/* assets/css/app.css */
@layer base {
  html { font-family: 'Inter', system-ui, -apple-system, sans-serif; }
}
```

### 3.1 Type scale

```
role          | size      | weight | line-height | tailwind
--------------|-----------|--------|-------------|------------------
display       | 36-60px   | 700    | 1.1         | text-4xl/5xl/6xl font-bold
h1            | 30px      | 700    | 1.2         | text-3xl font-bold
h2            | 24px      | 600    | 1.3         | text-2xl font-semibold
h3            | 18px      | 600    | 1.4         | text-lg font-semibold
body          | 16px      | 400    | 1.6         | text-base
body-sm       | 14px      | 400    | 1.5         | text-sm
caption       | 12px      | 500    | 1.4         | text-xs font-medium uppercase tracking-wide
mono          | 14px      | 400    | 1.5         | text-sm font-mono   (for hostnames, IDs, tokens)
```

### 3.2 Mobile minimums

- Body text never below 16px on mobile (`text-base`)
- Touch targets minimum 44×44 px → `btn-sm` is the floor for tappable items, never `btn-xs`
- Line length capped at 65–75ch in prose blocks (use `max-w-prose`)

## 4. Spacing, radii, shadows

```
spacing scale: 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64 / 96  (px)
                ^ tailwind 1, 2, 3, 4, 6, 8, 12, 16, 24

radii:
  rounded-md     6px   inputs, badges
  rounded-lg     8px   buttons
  rounded-xl     12px  cards
  rounded-2xl    16px  hero / featured cards
  rounded-full   999px avatars, pill badges

shadows (use sparingly):
  shadow-sm      cards at rest
  shadow-md      cards on hover
  shadow-lg      modals, dropdowns
  (NO custom shadow stacks — the three above only)
```

## 5. Tailwind v4 + DaisyUI 5 theme override

Drop into `assets/css/app.css` (replace any existing `@plugin "../vendor/daisyui"` theme block):

```css
@plugin "../vendor/daisyui-theme" {
  name: "drivewayos";
  default: true;
  prefersdark: false;
  color-scheme: light;

  --color-primary: #2563EB;
  --color-primary-content: #FFFFFF;
  --color-secondary: #3B82F6;
  --color-secondary-content: #FFFFFF;
  --color-accent: #F97316;
  --color-accent-content: #FFFFFF;
  --color-neutral: #0F172A;
  --color-neutral-content: #F8FAFC;
  --color-base-100: #FFFFFF;
  --color-base-200: #F8FAFC;
  --color-base-300: #E2E8F0;
  --color-base-content: #0F172A;
  --color-info: #3B82F6;
  --color-info-content: #FFFFFF;
  --color-success: #16A34A;
  --color-success-content: #FFFFFF;
  --color-warning: #F59E0B;
  --color-warning-content: #0F172A;
  --color-error: #DC2626;
  --color-error-content: #FFFFFF;

  --radius-selector: 0.5rem;
  --radius-field: 0.5rem;
  --radius-box: 0.75rem;

  --size-selector: 0.25rem;
  --size-field: 0.25rem;

  --border: 1px;
  --depth: 1;
  --noise: 0;
}
```

## 6. Component vocabulary

Below is the **one canonical implementation** for each recurring component. When you build a new page, copy these — never improvise variants.

### 6.1 Page shell (every page wraps in this)

```heex
<main class="min-h-screen bg-base-200 px-4 py-8 sm:px-6">
  <div class="max-w-{X}xl mx-auto space-y-6">
    {/* page content */}
  </div>
</main>
```

`max-w-3xl` for forms / detail pages. `max-w-5xl` for table pages. `max-w-7xl` for dashboards.

### 6.2 Page header

```heex
<header class="flex items-start justify-between flex-wrap gap-3">
  <div>
    <h1 class="text-3xl font-bold tracking-tight">{title}</h1>
    <p class="text-sm text-base-content/70 mt-1">{subtitle}</p>
  </div>
  <nav class="flex gap-2 flex-wrap">
    {/* nav buttons */}
  </nav>
</header>
```

### 6.3 Card

```heex
<section class="card bg-base-100 shadow-sm border border-base-300">
  <div class="card-body p-6 space-y-4">
    <h2 class="card-title text-lg">{section title}</h2>
    {/* body */}
  </div>
</section>
```

**Hover-card (clickable):** add `hover:shadow-md transition-shadow cursor-pointer`.

### 6.4 Stat tile (used on dashboards)

```heex
<div class="stat bg-base-100 rounded-xl shadow-sm border border-base-300">
  <div class="stat-title text-xs font-medium uppercase tracking-wide text-base-content/60">
    {label}
  </div>
  <div class={"stat-value text-3xl font-bold " <> color_class}>{value}</div>
  <div class="stat-desc text-xs text-base-content/60">{caption}</div>
</div>
```

`color_class` matrix:
- Pending → `text-warning`
- Active / Success → `text-success`
- Total / neutral → no class (defaults to `base-content`)
- Revenue / GMV → `text-success`

### 6.5 Button hierarchy

```
btn btn-primary           — single primary action per view (Stripe Connect, Book it, Save)
btn btn-success           — affirmative dest. (Confirm, Verify, Activate)
btn btn-error             — destructive (Suspend, Refund, Cancel acct)
btn btn-ghost             — tertiary nav links in headers
btn btn-outline           — secondary actions
btn-sm                    — inside tables / inline rows
btn (default)             — primary CTA
```

**Never use** `btn-warning` for buttons — reserve warning hue for badges / banners only.

### 6.6 Form field

```heex
<div>
  <label class="label" for={id}>
    <span class="label-text font-medium">{label}</span>
    <span :if={optional?} class="label-text-alt text-base-content/50">Optional</span>
  </label>
  <input
    id={id}
    type={type}
    name={name}
    value={value}
    placeholder={placeholder}
    class="input input-bordered w-full"
    required={required}
  />
  <p :if={@errors[field]} class="text-error text-xs mt-1">{@errors[field]}</p>
</div>
```

For multi-column forms: wrap in `grid grid-cols-1 md:grid-cols-2 gap-4`.

### 6.7 Badge

```heex
<span class={"badge badge-sm " <> badge_class(status)}>{status}</span>
```

```
status              | class
--------------------|---------------
:active             | badge-success
:pending            | badge-warning
:confirmed          | badge-info
:in_progress        | badge-primary
:completed          | badge-success
:cancelled / :archived | badge-ghost
:suspended / :error | badge-error
```

### 6.8 Banner / alert

```heex
<div role="alert" class={"alert " <> level_class}>
  <Heroicons.LiveView.icon name={icon_name} class="w-5 h-5 shrink-0" />
  <div class="flex-1">
    <div class="font-semibold">{title}</div>
    <div class="text-sm opacity-80">{body}</div>
  </div>
  <a :if={cta} href={cta_href} class="btn btn-sm">{cta}</a>
</div>
```

`alert-info | alert-success | alert-warning | alert-error`. Use **once per page maximum** at the top of the content stack.

### 6.9 Empty state

```heex
<div class="text-center py-12 px-4">
  <Heroicons.LiveView.icon name="document-text" class="w-12 h-12 mx-auto text-base-content/30" />
  <h3 class="mt-4 text-lg font-semibold">{title}</h3>
  <p class="mt-1 text-sm text-base-content/60 max-w-sm mx-auto">{description}</p>
  <a :if={cta} href={cta_href} class="btn btn-primary btn-sm mt-4">{cta}</a>
</div>
```

### 6.10 Table (admin views)

```heex
<div class="overflow-x-auto">
  <table class="table table-zebra">
    <thead>
      <tr>
        <th class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Column</th>
      </tr>
    </thead>
    <tbody>
      <tr :for={row <- @rows} class="hover:bg-base-200/50 cursor-pointer">
        <td>{...}</td>
      </tr>
    </tbody>
  </table>
</div>
```

Wrap whole row in `<.link navigate={...}>` only when the entire row is one click target. Otherwise put `<.link>` on the first cell value.

### 6.11 Onboarding-checklist row (already shipped — keep this canonical)

```heex
<li class="flex gap-3 items-start">
  <span class="text-warning text-xl leading-none mt-0.5">○</span>
  <div class="flex-1">
    <div class="font-semibold">{title}</div>
    <div class="text-sm text-base-content/70">{blurb}</div>
  </div>
  <a href={href} class="btn btn-primary btn-sm">Do it</a>
</li>
```

## 7. Icons

**Heroicons only** (already a project dep).

```heex
<Heroicons.LiveView.icon name="check-circle" class="w-5 h-5" />
```

| Concept | Icon name |
|---|---|
| Success / Verified | `check-circle` |
| Warning / Pending | `exclamation-triangle` |
| Info | `information-circle` |
| Error / Suspend | `x-circle` |
| Schedule | `calendar` |
| Customer | `user-circle` |
| Vehicle | `truck` |
| Address | `map-pin` |
| Payment | `credit-card` |
| Refund | `arrow-uturn-left` |
| Domain / Web | `globe-alt` |
| Branding | `paint-brush` |
| Sign in | `arrow-right-on-rectangle` |
| Sign out | `arrow-left-on-rectangle` |

**Never use emojis** in UI strings. (The seeds output uses ✓ for terminal — that's fine; it's not UI.)

## 8. Motion

```css
transition-colors  duration-150  ease-out      /* color hovers */
transition-shadow  duration-200  ease-out      /* card lifts */
transition-transform  duration-200  ease-out   /* button presses */
```

Every animated element checks `prefers-reduced-motion`:

```css
@media (prefers-reduced-motion: reduce) {
  * { transition: none !important; animation: none !important; }
}
```

## 9. Accessibility floor

Non-negotiable on every PR:

- [ ] All `<input>` have a paired `<label for=...>`
- [ ] All icon-only buttons have `aria-label`
- [ ] All clickable non-buttons have `cursor-pointer`
- [ ] Focus rings visible: never `outline-none` without a replacement ring
- [ ] Color is never the sole signal — pair with icon or text
- [ ] Tab order matches visual order
- [ ] Body text contrast vs background ≥ 4.5:1 (slate-600 on white = 7.4:1 ✓)

## 10. Refactor order — biggest visual ROI first

| # | Page | Why first | Effort |
|---|---|---|---|
| 1 | **`assets/css/app.css` theme block** | Unblocks every other refactor — without DaisyUI tokens applied, the rest is wasted | XS |
| 2 | **`LandingLive` tenant view** | First impression for every customer; tenant brand color shines here | S |
| 3 | **`BookingLive`** | The conversion page; weakness here = no revenue | M |
| 4 | **`Auth.SignInLive` + `Auth.RegisterLive` + `Auth.MagicLinkLive`** | Three pages, one shared layout — refactor as a set | M |
| 5 | **`AppointmentDetailLive`** | Customer's "did the booking work?" moment | S |
| 6 | **`AppointmentsLive`** (customer) | List counterpart to #5 | S |
| 7 | **`Admin.DashboardLive`** | Operator's daily home — already has the onboarding checklist; tighten typography + stat tiles | S |
| 8 | **`Admin.AppointmentsLive` table** | Highest-volume admin surface | S |
| 9 | **`Admin.{Customers,CustomerDetail,Services,Schedule,Branding,Domains}Live`** | Same patterns; refactor in one sweep | M |
| 10 | **`Platform.{SignIn,Tenants,Metrics}Live`** | We're the only ones who see it; lowest priority | S |
| 11 | **`StripeOnboardingController` callback page + `503` suspended page** | Edge cases but visible to real users | XS |

**Recommendation:** ship #1 first (the CSS file change) and verify everything still renders, then ship #2–#6 as a single "customer-facing polish pass" PR (one logical unit), then #7–#9 as a "tenant admin polish pass" PR, then #10 as a final cleanup.

## 11. What stays out of scope

- **Dark mode.** V1 is light-only. Adding dark mode means doubling the contrast audit and we don't have customers asking yet.
- **Custom illustrations.** Heroicons until we have a designer.
- **Mobile app native styling.** Web only for now.
- **Tenant-uploaded fonts.** Inter only — tenants pick a color, that's it.

---

## Appendix: machine-readable record

The `ui-ux-pro-max` skill's full output for this design system lives at
[`design-system/MASTER.md`](../design-system/MASTER.md). When building a new
page, check for a `design-system/pages/<page>.md` override first; otherwise
this spec is the source of truth.
