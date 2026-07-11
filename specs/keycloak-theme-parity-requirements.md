<!-- [agent:claude] [purpose:spec:keycloak-theme-parity-requirements] -->
<!-- ⚓ SPEC: KeycloakThemeParityRequirements -->
<!-- 📜 PURPOSE: Requirements the knobby UI team must satisfy so the Keycloak-hosted -->
<!--             pages on auth.knobby.io are visually identical to prod.knobby.io -->
<!--             /auth/login and /mcp/consent, including light/dark/system parity. -->
<!-- 🔗 RELATES: specs/keycloak-themeing-guide.md, ThemeManager (apps), enterprise-bootstrap-theme (CDN) -->

# Keycloak Theme Parity — Requirements for the UI Team

**Status:** Draft v1.0 (for UI-team handoff)
**Owner:** IDP / Keycloak team
**Audience:** knobby UI team (owners of `knobby/apps` frontend + the `enterprise-bootstrap-theme` / static.knobby.io CDN)
**Date:** 2026-07-11
**Companion to:** `specs/keycloak-themeing-guide.md` (which this supersedes on the delivery-mechanism decision — see §7)

---

## 1. Goal

The knobby web app on **prod.knobby.io** owns the primary auth surfaces:

- `GET /auth/login` — the IdP-picker sign-in page (`kc_idp_hint` hand-off to Keycloak).
- `GET /mcp/consent` — the MCP connect/consent wizard.

A few Keycloak-rendered pages on **auth.knobby.io** are unavoidable in edge cases — chiefly the **IdP-picker fallback login** (a bare hit on the auth endpoint without `kc_idp_hint`), plus error / logout / account-link pages. Per the "invisible Keycloak" architecture these are rare, but when a user does land on one it **must not look like a different product**.

**Requirement in one line:** an enterprise user who has chosen light, dark, or system mode in the knobby app must see the Keycloak pages on auth.knobby.io render in the **same theme, with the same card, colors, typography, and component styling** as prod.knobby.io — with **no flash of the wrong theme**.

Pixel-perfection is *not* required (the pages share a root domain and the same design system). **Visual identity** is: same tokens, same auth card, same buttons, same dark/light state.

---

## 2. How theming works today (as-built)

Grounded in the current code so the requirements below are concrete.

### 2.1 The design system is a CDN, not an npm package

`static.knobby.io` serves the `enterprise-bootstrap-theme` build (repo: `b2btheme`):

- `https://static.knobby.io/css/custom.css` — Bootstrap 5.3.8 + knobby tokens. Dark mode via `data-bs-theme="dark"` on `<html>`; semantic `--theme-*` and Bootstrap `--bs-*` custom properties flip between modes (`DARKMODE.md`).
- `https://static.knobby.io/components/<name>/<name>.{js,css}` — 116 **vanilla-TS** web components (factory functions, e.g. `createThemeToggle()`), consumed via plain `<link>` + `<script>`. **Not React.**

Both reference pages consume it exactly this way (`frontend/auth/login.html`, `frontend/mcp/consent.html`).

### 2.2 Theme preference model

`typescript/shared/theme/theme-manager.ts` is the single write authority:

| Fact | Value |
|---|---|
| Modes | `'light' \| 'dark' \| 'auto'` |
| Storage key | `localStorage['knobby-theme']` |
| Write path | `setTheme()` → localStorage + `data-bs-theme` + listeners |
| Backend sync | `UIStateService` namespace `theme`, key `mode` (cross-device, logged-in) |
| Pre-paint apply | `frontend/admin/admin-theme.js` in `<head>` — reads localStorage, resolves `auto` via `prefers-color-scheme`, sets `data-bs-theme` before first paint |
| Cross-tab/sub-app sync | shell `postMessage({type:'THEME_CHANGED'})` |
| `themetoggle` CDN component | **stateless** — takes `defaultTheme`, emits `onChange`; persistence is the app's job |

Every mechanism above is **same-origin** to prod.knobby.io. The code comments say so explicitly ("shared across same origin").

### 2.3 The auth-card styling is app-local

The login card's layout classes are defined in **app-local** CSS, not on the CDN:

- `frontend/static/app.css` → `.brand-logo(.lg/.img)`, `.auth-main`, `.auth-container`, `.auth-card`, `.idp-button`, `.idp-icon`, `.divider`, `.divider-text`, `.auth-step`.
- `frontend/css/shell.css` → `.app-container`, `.content-container` (site chrome).

Confirmed: **0 occurrences** of `.auth-card` / `.idp-button` / `.brand-logo` in `static.knobby.io/css/custom.css`. These rules already use `--bs-*` tokens (`--bs-body-bg`, `--bs-border-color`, `--bs-box-shadow`, `--bs-primary`), so they are dark-mode-ready — they are simply **not reachable from auth.knobby.io**.

---

## 3. The three gaps blocking parity

Because Keycloak is on **auth.knobby.io** (a different origin from prod.knobby.io, sharing only the `.knobby.io` parent domain):

1. **Preference is invisible cross-origin.** localStorage on prod.knobby.io is not readable by auth.knobby.io, and `THEME_CHANGED` postMessages do not reach a top-level Keycloak navigation. → A dark-mode user gets a light Keycloak page.
2. **The pre-paint script cannot be reused.** `admin-theme.js` is app-origin and localStorage-only; the Keycloak theme cannot load it and it cannot read a cross-subdomain cookie.
3. **The auth-card look is not on the CDN.** Linking `custom.css` alone does not reproduce the card/buttons/divider.

All three are resolved by UI-team deliverables below. (The Keycloak FreeMarker templates, CSP allowlist, and Docker packaging are the IDP team's — see §6.)

---

## 4. Requirements

> Each requirement is testable and owned. IDs are stable for cross-referencing.

### R1 — Mirror the theme preference to a `.knobby.io` cookie  *(app / ThemeManager)*

The preference must be readable by any `*.knobby.io` origin, so it must live in a cookie scoped to the parent domain, written wherever localStorage is written today.

- **R1.1** On every theme write, in addition to `localStorage['knobby-theme']`, set a cookie per the contract in **R3**. The single choke point is `setTheme()` in `theme-manager.ts`; the legacy `'system' → 'auto'` migration in `initTheme()` must write it too.
- **R1.2** The cookie value is the **mode** (`light` / `dark` / `auto`), never the resolved value. Resolution of `auto` happens at read time (R2) so OS changes are honored on the Keycloak page.
- **R1.3** No regression to existing same-origin behavior (localStorage + backend `UIStateService` sync remain the source of truth for the app; the cookie is an additive mirror).
- **R1.4** On app load, if the cookie and localStorage disagree (e.g. changed in another subapp), localStorage/backend remains authoritative for the app; the cookie is refreshed to match on the next `setTheme()`.

### R2 — Publish a cookie-aware pre-paint theme-init script on the CDN  *(theme repo / CDN)*

A single, framework-agnostic, dependency-free script that both the app pages and the Keycloak FreeMarker templates can include in `<head>` to set the theme before first paint.

- **R2.1** Publish at a stable, versioned URL, e.g. `https://static.knobby.io/js/theme-init.js` (see R4 on versioning).
- **R2.2** Resolution order: read the **cookie** (R3) → fall back to `localStorage['knobby-theme']` (same-origin app case) → fall back to `prefers-color-scheme` → default `light`.
- **R2.3** Resolve `auto` via `window.matchMedia('(prefers-color-scheme: dark)')` and set `document.documentElement.setAttribute('data-bs-theme', resolved)` **synchronously** (blocking, in `<head>`, before body) so there is no flash.
- **R2.4** Must run with **no inline script** required by the consumer (it is an external `<script src>`), so it is compatible with Keycloak's strict CSP without a nonce/hash.
- **R2.5** Must be self-contained (no imports, no `window.*` app globals) so it runs identically on auth.knobby.io where none of the app's JS exists.
- **R2.6** Recommended: converge the app's `admin-theme.js` onto this shared script so there is one implementation, not two. (Nice-to-have, not blocking.)

### R3 — Theme cookie contract  *(app writes, theme-init reads)*

| Attribute | Value | Rationale |
|---|---|---|
| Name | `knobby-theme` | Matches the existing localStorage key for clarity |
| Value | `light` \| `dark` \| `auto` | Mode, not resolved (R1.2) |
| `Domain` | `.knobby.io` | Readable by prod.knobby.io **and** auth.knobby.io |
| `Path` | `/` | All routes |
| `SameSite` | `Lax` | Sent on top-level cross-subdomain navigations (the Keycloak redirect is a top-level GET); not a CSRF vector (non-secret UI pref) |
| `Secure` | yes | HTTPS only |
| `HttpOnly` | **no** | Must be readable by client JS (theme-init runs in the browser) |
| `Max-Age` | ~1 year, refreshed on write | Durable preference |

- **R3.1** The cookie is a **non-sensitive UI preference only**. It must never carry identity, tokens, or anything security-relevant. (`SECRET_HANDLING.md`.)
- **R3.2** Value is strictly validated on read; any unexpected value falls through to `prefers-color-scheme` (R2.2).

### R4 — Make the CDN assets safely consumable cross-origin  *(theme repo / CDN infra)*

The Keycloak theme will load CSS/JS (and transitively fonts) from static.knobby.io from the auth.knobby.io origin.

- **R4.1** **Fonts / CORS — verified 2026-07-11, not a blocker as currently structured.** `custom.css` and all 116 component CSS files contain **zero `@font-face`** (system font stack via `--bs-font-sans-serif`); the CDN serves no web font in the parity path. The only fonts on the CDN are `dist/icons/fonts/bootstrap-icons.woff2/.woff`, and both reference pages load icons from **public CDNs** (bootstrap-icons via jsdelivr, font-awesome via cdnjs) which are already CORS-enabled — not from static.knobby.io. **Action:** the Keycloak theme MUST source icon fonts from those same public CDNs (mirroring the app). It MUST NOT self-host icons from `static.knobby.io/icons/…`, because the CDN (bare `wrangler.jsonc` static assets, no `_headers`, no worker) sets **no CORS headers**, so cross-origin `@font-face` from auth.knobby.io would be blocked. If self-hosting icons ever becomes desirable, first add `Access-Control-Allow-Origin` for `/icons/fonts/*` at the Worker. (Cross-origin `<link>`/`<script>` need no CORS and already work app→CDN.)
- **R4.2** **Versioning / pinning:** provide a way for the Keycloak theme to pin a known-good version of `custom.css`, the components, and `theme-init.js` (e.g. immutable, hash- or version-pathed URLs such as `…/v1.4.0/css/custom.css`, or documented long-cache + content-hash filenames). The Keycloak image is rebuilt on a release cadence and must not break when the CDN advances. State the contract explicitly.
- **R4.3** **Cache headers:** long-lived, immutable caching for versioned assets; short/validated caching for any unversioned "latest" alias.

### R5 — Promote the shared auth surface to the CDN as a documented pattern  *(theme repo / CDN)*

So one source of truth drives both the app login and the Keycloak fallback login. Choose one:

- **R5.a (preferred):** Publish the auth-card pattern as a CDN component or a documented section of `custom.css` — the rules currently in `frontend/static/app.css` for `.auth-card`, `.auth-container`, `.auth-main`, `.idp-button`, `.idp-icon`, `.divider`, `.divider-text`, `.brand-logo(.lg/.img)`, `.auth-step`. They already use `--bs-*` tokens, so they dark-mode automatically once loaded alongside `custom.css`. The app then consumes them from the CDN instead of app-local CSS (removing the duplication).
- **R5.b (fallback):** If promotion is not feasible now, treat the CSS in **Appendix B** as a frozen, versioned contract that the IDP team may vendor into the Keycloak theme, and **notify the IDP team on any change** to these classes so the vendored copy stays in sync.
- **R5.1** Publish the canonical login-card **markup** (Appendix A) and the IdP-button structure as documentation so the FreeMarker template can mirror it exactly. Any change to class names or structure is a breaking change and must be versioned + communicated.
- **R5.2** **Resolved (2026-07-11): the IDP team bundles the logo into the theme JAR** — no UI-team action. Source of truth is `apps/frontend/logo.png` (221 KB). The IDP team copies it into the theme's static resources and serves it via `${url.resourcesPath}`; the UI team notifies the IDP team if the brand logo changes so the bundled copy is refreshed.

---

## 5. Acceptance criteria

Verified on auth.knobby.io by triggering the fallback login (bare auth endpoint, no `kc_idp_hint`), for a user coming from prod.knobby.io:

1. **Dark chosen in app → Keycloak page is dark.** No flash of light at any point during load.
2. **Light chosen in app → Keycloak page is light.** No flash.
3. **Auto chosen + OS dark → Keycloak page is dark;** toggling OS appearance while on the page updates it (auto path honors `prefers-color-scheme`).
4. **No prior preference (fresh browser) → Keycloak page follows `prefers-color-scheme`,** matching what the app would show.
5. **Visual identity:** the Keycloak fallback login card, IdP buttons, divider, brand, spacing, and typography are indistinguishable from `/auth/login` in both modes (side-by-side screenshots).
6. **CSP clean:** no CSP violations in the console; no inline script required.
7. **Fonts render** (no CORS-blocked `@font-face`, no fallback-font flash) on auth.knobby.io.
8. **No regression** to the app's own same-origin theme behavior or cross-tab sync.

---

## 6. Out of scope for the UI team (IDP team owns)

- The Keycloak **FreeMarker theme** itself (templates that link the CDN assets and mirror Appendix A markup) — see §7.
- Keycloak realm **CSP allowlist** (`script-src`/`style-src`/`font-src` → add `static.knobby.io`) in Security Defenses.
- Baking the theme into the Keycloak **Docker image** and per-realm theme selection.
- Keycloak's own **consent/grant** screen — bypassed by the SPI; not themed.

---

## 7. Delivery-mechanism note (supersedes the themeing guide)

`specs/keycloak-themeing-guide.md` recommends **Keycloakify** (React → FreeMarker) on the assumption that the design system is a React `@knobby/design-system` package whose components/tokens can be imported. That assumption does not hold: the design system is a **CDN of Bootstrap CSS + vanilla-TS web components** (§2.1). Keycloakify would therefore re-bundle a second copy of Bootstrap and re-implement the look in JSX, guaranteeing drift from static.knobby.io.

The IDP team will instead use a **plain FreeMarker theme that links the live CDN assets** (Keycloak's native templating; Apache-2.0; the substrate Keycloakify itself compiles to). This makes these UI-team requirements — CDN-served preference cookie, pre-paint init script, and promoted auth-card pattern — the load-bearing pieces of parity. The themeing guide will be revised to match.

---

## Appendix A — Canonical login-card markup (from `frontend/auth/login.html`)

The FreeMarker fallback login mirrors this structure (IdP buttons rendered from Keycloak's `social.providers` instead of hard-coded):

```html
<div class="auth-container">
  <div class="auth-card card shadow-lg p-4">
    <div class="text-center mb-4">
      <img src="<LOGO_URL>" alt="knobby.io" class="brand-logo lg mx-auto mb-3 brand-logo-img">
      <h1 class="h3 fw-bold mb-1">knobby.io</h1>
      <p class="text-muted small">Engineering &amp; Organizational Productivity</p>
    </div>
    <div id="error-alert" class="alert alert-danger d-none"></div>
    <div class="auth-step active">
      <h2 class="h5 fw-semibold mb-1 text-center">Welcome back</h2>
      <p class="text-muted text-center mb-4">Continue with your account</p>
      <!-- One .idp-button per provider (SVG icon + "Continue with <name>") -->
      <button class="btn btn-outline-secondary w-100 idp-button mb-2"> … </button>
      <div class="divider mt-3"><span class="divider-text">New to knobby.io?</span></div>
      <a href="/auth/signup.html" class="link-primary text-decoration-none fw-semibold small d-block text-center">Create an account</a>
    </div>
  </div>
</div>
```

CDN assets both reference pages load (the parity contract):

```
CSS : https://static.knobby.io/css/custom.css
      https://static.knobby.io/components/{usermenu,applauncher,themetoggle,confirmdialog}/*.css
JS  : https://static.knobby.io/components/{usermenu,applauncher,themetoggle,confirmdialog}/*.js
Head: <script src="theme-init.js"></script>   ← R2 (replaces app-local admin-theme.js)
```

## Appendix B — Auth-card CSS to promote/freeze (from `frontend/static/app.css`)

`.brand-logo`, `.brand-logo.lg`, `.brand-logo-img`, `.auth-main`, `.auth-container` (`max-width:450px`), `.auth-card` (`background:var(--bs-body-bg)`, `border:1px solid var(--bs-border-color)`, `box-shadow:var(--bs-box-shadow)`), `.idp-button` (flex, `gap:.75rem`), `.idp-button .idp-icon` (`20×20`), `.divider` + `.divider::before` + `.divider-text`, `.auth-step(.active)` + `slideUp`/`fadeIn` keyframes. All use `--bs-*` tokens → dark-mode-ready once served with `custom.css`.
