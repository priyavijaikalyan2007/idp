# Keycloak Theming Guide (knobby.io)

**Status:** Draft v1.0
**Owner:** PVSS
**Last Updated:** 2026-06-02
**Companion to:** `KEYCLOAK_AUTH_PRD.md` (§9 references this document)

---

## 1. Overview

Per Invariant 3 of the Authentication PRD, users never see Keycloak. Most of Keycloak's surfaces are either bypassed (`kc_idp_hint` skips the IdP picker), disabled (Account Console off), or never reached in the happy path. But a few Keycloak-rendered pages remain unavoidable for edge cases, and those need to look like knobby.io rather than like Keycloak. This guide covers how to build, customize, and deploy that theme.

The toolchain is **Keycloakify** — a React + TypeScript framework that compiles to Keycloak's expected FreeMarker theme format. Why Keycloakify rather than hand-writing FreeMarker templates:

- knobby.io's frontend is React + TypeScript + Bootstrap. Keycloakify lets the theme share design tokens, components, and tooling with the main app.
- FreeMarker is a dated templating language. Keycloakify abstracts it away; you write React, it transpiles.
- Component preview during development — you can iterate on a theme page in a Vite dev server, without redeploying Keycloak each time.
- Active maintenance and large community.

The theme JAR is built once per release, baked into the Keycloak Docker image, and selected per-realm in Realm Settings → Themes. All three realms (`knobby-prod`, `knobby-dev`, `knobby-test`) use the same `knobby` theme.

---

## 2. Scope — Which Pages Get Themed

### 2.1 Pages users may actually see (must theme)

These are the surfaces that survive the "invisible Keycloak" architecture. They're rare in the happy path but not impossible.

| Page | When users see it | Priority |
|------|------------------|----------|
| **Login (IdP picker fallback)** | Bare hit on `/auth` without `kc_idp_hint`. Stale bookmark, broken link, or first-time direct visit. | High |
| **Error page** | Unrecoverable errors: bad redirect URI, expired authorization code, IdP misconfiguration. | High |
| **Logout confirmation** | RP-initiated logout when `id_token_hint` is missing or invalid. | Medium |
| **Session expired** | Idle timeout while in mid-flow (rare). | Medium |
| **Account linking** | User signs in via a second IdP (e.g., already has a Google-federated account, now signs in with Microsoft using the same email). | Medium |
| **First Broker Login — Update Profile** | Should never appear in our config (Review Profile is disabled), but if a Required Action gets accidentally enabled, this is the page. | Low |

### 2.2 Pages explicitly NOT themed

| Page | Why not |
|------|---------|
| Account Console (`/realms/<r>/account`) | Disabled per §8.8 / §11.14 of the auth PRD. Returns 404. |
| Admin Console | Internal-only. Default `keycloak.v2` theme is acceptable for ops. |
| Registration | Self-registration disabled per Invariant 1. |
| Forgot password | Disabled per Invariant 1. |
| Update password | No local password users. |

### 2.3 Email templates (optional, low priority)

Keycloak can send emails (verify email, password reset, etc.). Per the PRD §11.2, the realm's Email tab is left unconfigured because no Keycloak-side emails are sent to federated users. Email theming is therefore unnecessary unless the realm starts sending emails (which would be a config change worth its own ADR).

If/when emails are added: Keycloakify supports email theming via `src/email/`. Out of scope for this guide.

---

## 3. Keycloakify Project Setup

### 3.1 Prerequisites

- **Node.js** 20 LTS or later.
- **Java** 21 (required by Keycloakify's build step to package the JAR).
- **Maven** (Keycloakify uses Maven under the hood for the JAR build; comes with most Java distributions or installable separately).
- Access to the knobby.io frontend monorepo (where the theme will live as a sub-package).

### 3.2 Repository Layout Decision

Two options:

**Option A — Subdirectory of the main knobby.io frontend monorepo** (recommended). The theme is a sibling package to the main React app. Pros: shared design tokens, shared component library, single repo to clone and version. Cons: theme builds happen alongside frontend builds.

**Option B — Separate `knobby-keycloak-theme` repo.** Pros: independent versioning, smaller blast radius for builds. Cons: requires copying or NPM-publishing design tokens.

Going with **Option A** to keep the design system integration cheap.

Proposed layout within the knobby.io frontend monorepo:

```
knobby-frontend/
├── packages/
│   ├── app/                         # Main knobby.io React app
│   ├── design-system/               # Shared tokens, components, styles
│   └── keycloak-theme/              # ← This is the theme package
│       ├── src/
│       ├── public/
│       ├── package.json
│       ├── vite.config.ts
│       └── README.md
├── package.json                     # Workspace root
└── pnpm-workspace.yaml              # (or yarn/npm equivalent)
```

### 3.3 Initialize the Keycloakify Project

In the `packages/keycloak-theme/` directory:

```bash
# Use the Keycloakify starter template (latest stable)
pnpm create keycloakify@latest

# When prompted:
#   - Project name: keycloak-theme
#   - Bundler: vite
#   - Template: account-multi-page (we'll prune account pages later since they're disabled)
#                  OR: login (lighter; only login-related pages)
#   - TypeScript: yes
```

For knobby.io, the `login` template is the right fit since account pages are disabled. The starter command for that:

```bash
pnpm create keycloakify@latest -- --template login --typescript --bundler vite
```

After init, the directory contains:

```
keycloak-theme/
├── src/
│   ├── login/
│   │   ├── KcContext.ts            # TypeScript types for the FreeMarker context
│   │   ├── KcPage.tsx              # Page router (dispatches to per-page components)
│   │   ├── i18n.ts                 # Localization
│   │   ├── pages/
│   │   │   ├── Login.tsx           # Login page (the IdP picker fallback)
│   │   │   ├── Error.tsx           # Error page
│   │   │   ├── LoginIdpLinkConfirmOverride.tsx
│   │   │   ├── LogoutConfirm.tsx
│   │   │   └── ... (one file per Keycloak page)
│   │   ├── components/             # Shared components (header, footer, layout)
│   │   └── assets/                 # Logos, fonts
│   ├── main.tsx                    # Entry point
│   └── kc.gen.ts                   # Generated bindings (do not edit)
├── public/
├── package.json
├── tsconfig.json
└── vite.config.ts
```

### 3.4 Configure the Theme Identity

In `package.json`, set the theme identity:

```json
{
  "name": "knobby-keycloak-theme",
  "version": "1.0.0",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "build-keycloak-theme": "npm run build && keycloakify build",
    "storybook": "storybook dev -p 6006"
  },
  "keycloakify": {
    "themeName": "knobby",
    "extraThemeProperties": [
      "parent=keycloak.v2"
    ],
    "groupId": "io.knobby.keycloak.theme",
    "artifactId": "knobby-keycloak-theme",
    "keycloakVersionTargets": {
      "26-and-above": "knobby-theme.jar"
    }
  }
}
```

The `themeName: "knobby"` is what gets selected in Realm Settings → Themes (per PRD §10.8 and §11.16).

The `parent=keycloak.v2` ensures that for any pages we don't override, Keycloak falls back to the modern default theme — important since we explicitly choose not to override every page (per §2.1, only the user-visible ones).

---

## 4. Design System Integration

### 4.1 Sharing Tokens with the Main App

The knobby.io design system package exports design tokens (colors, typography, spacing, etc.). The theme should import these directly so a change in the main app's brand colors flows through to the Keycloak theme.

In `packages/keycloak-theme/package.json`:

```json
{
  "dependencies": {
    "@knobby/design-system": "workspace:*",
    "react": "^18.3.0",
    "react-dom": "^18.3.0"
  },
  "devDependencies": {
    "keycloakify": "^11.0.0",
    "vite": "^5.4.0",
    "typescript": "^5.5.0",
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0"
  }
}
```

(Pin versions to whatever the rest of the monorepo uses.)

### 4.2 Bootstrap Setup

Since knobby.io uses Bootstrap, import it globally in the theme's entry point. In `src/login/main.tsx`:

```tsx
import { createRoot } from "react-dom/client";
import { StrictMode, lazy, Suspense } from "react";
import { KcPage, type KcContext } from "./KcPage";

// Bootstrap styles. Order matters: knobby tokens last so they override Bootstrap defaults.
import "bootstrap/dist/css/bootstrap.min.css";
import "@knobby/design-system/tokens.css";
import "./global.css";  // theme-specific overrides

declare global {
    interface Window {
        kcContext?: KcContext;
    }
}

createRoot(document.getElementById("root")!).render(
    <StrictMode>
        {!window.kcContext ? (
            <h1>No kcContext defined — running in dev mode?</h1>
        ) : (
            <KcPage kcContext={window.kcContext} />
        )}
    </StrictMode>
);
```

### 4.3 CSS Variables for Theming

In `src/login/global.css`:

```css
:root {
    /* Pull from knobby.io design tokens */
    --knobby-color-primary: var(--ds-color-primary, #4f46e5);
    --knobby-color-primary-hover: var(--ds-color-primary-hover, #4338ca);
    --knobby-color-text: var(--ds-color-text, #111827);
    --knobby-color-text-muted: var(--ds-color-text-muted, #6b7280);
    --knobby-color-bg: var(--ds-color-bg, #ffffff);
    --knobby-color-bg-subtle: var(--ds-color-bg-subtle, #f9fafb);
    --knobby-color-border: var(--ds-color-border, #e5e7eb);
    --knobby-color-error: var(--ds-color-error, #dc2626);

    --knobby-font-family: var(--ds-font-family, "Inter", system-ui, sans-serif);
    --knobby-radius-sm: 0.375rem;
    --knobby-radius-md: 0.5rem;
    --knobby-shadow-card: 0 1px 3px rgba(0, 0, 0, 0.05), 0 1px 2px rgba(0, 0, 0, 0.1);
}

body {
    font-family: var(--knobby-font-family);
    color: var(--knobby-color-text);
    background: var(--knobby-color-bg-subtle);
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
}

/* Override Bootstrap btn-primary with knobby tokens */
.btn-primary {
    background-color: var(--knobby-color-primary);
    border-color: var(--knobby-color-primary);
}
.btn-primary:hover {
    background-color: var(--knobby-color-primary-hover);
    border-color: var(--knobby-color-primary-hover);
}
```

### 4.4 Shared Components from @knobby/design-system

Reusable components from the design system can be imported and used directly:

```tsx
import { Card, Button, Logo, Stack } from "@knobby/design-system";
```

The catch: anything imported must not depend on browser APIs that Keycloak's iframe contexts might restrict (e.g., `localStorage` works, but `IndexedDB` may not always). Components that fetch from the knobby.io API also won't work — Keycloak pages have no API access to knobby.io.

Safe imports: pure presentational components (buttons, cards, layouts, icons).
Avoid: any component that fetches data, persists state to a backend, or depends on knobby.io's auth context.

---

## 5. Customizing Pages

Keycloakify dispatches to per-page components via `KcPage.tsx`. The starter template provides default implementations for every page; we override only the ones from §2.1.

### 5.1 The Page Router

`src/login/KcPage.tsx` (lightly modified from the starter):

```tsx
import { Suspense, lazy } from "react";
import type { ClassKey } from "keycloakify/login";
import type { KcContext } from "./KcContext";
import { useI18n } from "./i18n";
import DefaultPage from "keycloakify/login/DefaultPage";
import Template from "./Template";

const KnobbyLogin = lazy(() => import("./pages/Login"));
const KnobbyError = lazy(() => import("./pages/Error"));
const KnobbyLogoutConfirm = lazy(() => import("./pages/LogoutConfirm"));
const KnobbyLoginIdpLinkConfirmOverride = lazy(() => import("./pages/LoginIdpLinkConfirmOverride"));

export default function KcPage(props: { kcContext: KcContext })
{
    const { kcContext } = props;
    const { i18n } = useI18n({ kcContext });

    return (
        <Suspense>
            {(() =>
            {
                switch (kcContext.pageId)
                {
                    case "login.ftl":
                        return <KnobbyLogin {...{ kcContext, i18n, Template, classes: {} }} />;
                    case "error.ftl":
                        return <KnobbyError {...{ kcContext, i18n, Template, classes: {} }} />;
                    case "logout-confirm.ftl":
                        return <KnobbyLogoutConfirm {...{ kcContext, i18n, Template, classes: {} }} />;
                    case "login-idp-link-confirm-override.ftl":
                        return <KnobbyLoginIdpLinkConfirmOverride {...{ kcContext, i18n, Template, classes: {} }} />;
                    default:
                        // Fall through to Keycloakify default rendering (themed via Template)
                        return <DefaultPage {...{ kcContext, i18n, Template, classes: {} }} />;
                }
            })()}
        </Suspense>
    );
}
```

The `Template` is the shared layout used across pages (knobby.io chrome — logo, footer). All custom pages get it for free.

### 5.2 The Shared Template

`src/login/Template.tsx`:

```tsx
import type { TemplateProps } from "keycloakify/login/TemplateProps";
import type { KcContext } from "./KcContext";

export default function Template(props: TemplateProps<KcContext, any>)
{
    const { displayMessage = true, headerNode, infoNode = null, children, kcContext } = props;

    return (
        <div className="knobby-auth-container">
            <div className="knobby-auth-card">
                <header className="knobby-auth-header">
                    <img src="/logo.svg" alt="knobby.io" className="knobby-logo" />
                </header>

                {headerNode && (
                    <h1 className="knobby-auth-title">{headerNode}</h1>
                )}

                {displayMessage && kcContext.message && (
                    <div className={`knobby-alert knobby-alert-${kcContext.message.type}`}>
                        {kcContext.message.summary}
                    </div>
                )}

                <main className="knobby-auth-content">
                    {children}
                </main>

                {infoNode && (
                    <footer className="knobby-auth-info">
                        {infoNode}
                    </footer>
                )}
            </div>

            <footer className="knobby-app-footer">
                <a href="https://knobby.io/terms" target="_blank" rel="noopener">Terms</a>
                <a href="https://knobby.io/privacy" target="_blank" rel="noopener">Privacy</a>
            </footer>
        </div>
    );
}
```

### 5.3 Login Page (IdP Picker Fallback)

`src/login/pages/Login.tsx` — this is what users see if they hit the auth endpoint without `kc_idp_hint`. Should look like knobby.io's main login screen, not Keycloak's default.

```tsx
import type { PageProps } from "keycloakify/login/pages/PageProps";
import type { KcContext } from "../KcContext";
import type { I18n } from "../i18n";

const KNOBBY_IDP_DISPLAY_ORDER = ["google", "microsoft", "github"];

export default function Login(props: PageProps<Extract<KcContext, { pageId: "login.ftl" }>, I18n>)
{
    const { kcContext, i18n, Template } = props;
    const { social, url } = kcContext;
    const { msg } = i18n;

    const providers = social?.providers ?? [];

    // Sort providers per the knobby.io display order; fall back to alphabetical.
    const sortedProviders = [...providers].sort((a, b) =>
    {
        const ai = KNOBBY_IDP_DISPLAY_ORDER.indexOf(a.alias);
        const bi = KNOBBY_IDP_DISPLAY_ORDER.indexOf(b.alias);
        if (ai === -1 && bi === -1) return a.alias.localeCompare(b.alias);
        if (ai === -1) return 1;
        if (bi === -1) return -1;
        return ai - bi;
    });

    return (
        <Template {...{ kcContext, i18n }} headerNode={msg("doLogIn")}>
            <p className="knobby-auth-subtitle">
                Sign in to continue to knobby.io.
            </p>

            <div className="knobby-idp-buttons">
                {sortedProviders.map(p => (
                    <a
                        key={p.alias}
                        href={p.loginUrl}
                        className={`knobby-idp-btn knobby-idp-btn-${p.alias}`}
                    >
                        <img
                            src={`/idp-icons/${p.alias}.svg`}
                            alt=""
                            className="knobby-idp-icon"
                        />
                        <span>Continue with {p.displayName}</span>
                    </a>
                ))}
            </div>

            <p className="knobby-auth-hint">
                Need help? Contact your administrator or{" "}
                <a href="https://knobby.io/support">visit support</a>.
            </p>
        </Template>
    );
}
```

The icon files live in `public/idp-icons/` and the theme bundles them into the JAR.

### 5.4 Error Page

`src/login/pages/Error.tsx`:

```tsx
import type { PageProps } from "keycloakify/login/pages/PageProps";
import type { KcContext } from "../KcContext";
import type { I18n } from "../i18n";

export default function Error(props: PageProps<Extract<KcContext, { pageId: "error.ftl" }>, I18n>)
{
    const { kcContext, i18n, Template } = props;
    const { message, client } = kcContext;

    // Map Keycloak's error keys to user-friendly knobby.io messaging.
    const friendlyMessage = (() =>
    {
        switch (message?.summary)
        {
            case "invalid_redirect_uri":
            case "invalid redirect uri":
                return "The application requesting sign-in is not properly registered.";
            case "Cookies are required":
                return "Please enable cookies in your browser and try again.";
            case "expired_code":
            case "Code is expired":
                return "Your sign-in link expired. Please try signing in again.";
            default:
                return message?.summary ?? "Something went wrong during sign-in.";
        }
    })();

    return (
        <Template {...{ kcContext, i18n, displayMessage: false }} headerNode="Sign-in error">
            <p className="knobby-auth-subtitle">{friendlyMessage}</p>

            <div className="knobby-error-actions">
                {client?.baseUrl && (
                    <a href={client.baseUrl} className="btn btn-primary">
                        Back to {client.name ?? "knobby.io"}
                    </a>
                )}
                <a href="https://knobby.io/support" className="btn btn-outline-secondary">
                    Get help
                </a>
            </div>

            {message?.summary && (
                <details className="knobby-error-details">
                    <summary>Technical details</summary>
                    <code>{message.summary}</code>
                </details>
            )}
        </Template>
    );
}
```

### 5.5 Logout Confirmation

`src/login/pages/LogoutConfirm.tsx`:

```tsx
import type { PageProps } from "keycloakify/login/pages/PageProps";
import type { KcContext } from "../KcContext";
import type { I18n } from "../i18n";

export default function LogoutConfirm(props: PageProps<Extract<KcContext, { pageId: "logout-confirm.ftl" }>, I18n>)
{
    const { kcContext, i18n, Template } = props;
    const { url, client, logoutConfirm } = kcContext;
    const { msg, msgStr } = i18n;

    return (
        <Template {...{ kcContext, i18n }} headerNode="Sign out">
            <p className="knobby-auth-subtitle">
                Are you sure you want to sign out of {client?.name ?? "knobby.io"}?
            </p>

            <form action={url.logoutConfirmAction} method="POST" className="knobby-form">
                <input type="hidden" name="session_code" value={logoutConfirm.code} />

                <div className="knobby-form-actions">
                    <button type="submit" name="confirmLogout" value="true" className="btn btn-primary">
                        Sign out
                    </button>
                    <a href={client?.baseUrl ?? "https://knobby.io/"} className="btn btn-outline-secondary">
                        Stay signed in
                    </a>
                </div>
            </form>
        </Template>
    );
}
```

### 5.6 Account Linking (Second IdP)

When a user signs in via a second IdP using the same email as an existing account, Keycloak shows a confirmation page. Custom version:

```tsx
// src/login/pages/LoginIdpLinkConfirmOverride.tsx
import type { PageProps } from "keycloakify/login/pages/PageProps";

export default function LoginIdpLinkConfirmOverride(props: PageProps<any, any>)
{
    const { kcContext, i18n, Template } = props;
    const { url, idpDisplayName } = kcContext;

    return (
        <Template {...{ kcContext, i18n }} headerNode="Link your account">
            <p className="knobby-auth-subtitle">
                You already have a knobby.io account using a different sign-in method.
                Would you like to link {idpDisplayName} to your existing account?
            </p>

            <form action={url.loginAction} method="POST" className="knobby-form">
                <div className="knobby-form-actions">
                    <button type="submit" name="submitAction" value="confirmOverride" className="btn btn-primary">
                        Yes, link my accounts
                    </button>
                    <button type="submit" name="submitAction" value="cancel" className="btn btn-outline-secondary">
                        Cancel
                    </button>
                </div>
            </form>
        </Template>
    );
}
```

---

## 6. Internationalization

Keycloakify supports per-language message overrides. For knobby.io's English-first audience, this is low priority but worth setting up the scaffold so it's there when needed.

`src/login/i18n.ts`:

```tsx
import { i18nBuilder } from "keycloakify/login";
import type { ThemeName } from "../kc.gen";

export const { useI18n, ofTypeI18n } = i18nBuilder
    .withThemeName<ThemeName>()
    .withCustomTranslations({
        en: {
            doLogIn: "Sign in",
            doLogOut: "Sign out",
            // Override built-in keys with knobby.io's voice
            errorTitle: "Sign-in problem",
        }
        // Future: add 'es', 'fr', etc.
    })
    .build();

export type I18n = typeof ofTypeI18n;
```

To use a translated key in a component: `i18n.msg("doLogIn")`.

---

## 7. Building the Theme JAR

### 7.1 Build Command

From `packages/keycloak-theme/`:

```bash
pnpm run build-keycloak-theme
```

This:
1. Compiles TypeScript and bundles via Vite.
2. Keycloakify post-processes the bundle into Keycloak's expected `theme/<themeName>/` directory structure.
3. Maven packages it as a JAR.

### 7.2 Output

The JAR appears at:

```
packages/keycloak-theme/dist_keycloak/keycloak-theme-for-kc-26-and-above.jar
```

(Filename depends on `keycloakVersionTargets` in `package.json`.)

### 7.3 Verify the Build

```bash
unzip -l dist_keycloak/keycloak-theme-for-kc-26-and-above.jar | head -30
```

Should show files under `theme/knobby/login/` including `theme.properties` and the bundled JavaScript.

---

## 8. Deploying to Keycloak

### 8.1 The Recommended Path: Bake into the Keycloak Docker Image

The theme JAR is built once per theme release and baked into a custom Keycloak Docker image. This ensures consistency across all environments and eliminates the runtime-deploy risk of dropping a JAR into a running container.

The Dockerfile (already referenced in PRD §11.17, expanded here):

```dockerfile
FROM quay.io/keycloak/keycloak:26.0 AS builder

# Copy the pre-built theme JAR into the providers directory.
# The JAR is built in the frontend repo CI and made available here as a build context file.
COPY --chown=keycloak:keycloak ./themes/knobby-theme.jar /opt/keycloak/providers/

# Keycloak's build step compiles providers into an optimized server image.
RUN /opt/keycloak/bin/kc.sh build --features=organization

FROM quay.io/keycloak/keycloak:26.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
EXPOSE 8080
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

### 8.2 Selecting the Theme per Realm

After the new Keycloak image is deployed, the theme appears in each realm's theme dropdown.

For each realm (`knobby-prod`, `knobby-dev`, `knobby-test`):

1. Realm settings → Themes tab.
2. Login Theme: `knobby`.
3. Email Theme: leave as `keycloak` (no custom email theme).
4. Save.

Per Invariant 7, this selection is owned by the OpenTofu IaC once that's in place; in the meantime, set it manually.

### 8.3 Clearing the Theme Cache

Keycloak caches theme resources aggressively. When deploying a new version of the theme JAR (same name, new content), users may see the old version due to browser caching plus Keycloak's internal cache.

Mitigations:
- Keycloakify-generated assets include content hashes in filenames. New theme version = new asset filenames = no stale browser cache.
- Keycloak server-side cache: set `KC_SPI_THEME_STATIC_MAX_AGE=-1` and `KC_SPI_THEME_CACHE_THEMES=false` in dev/test environments. For prod, leave caching on for performance; rely on the content-hash invalidation.
- After a JAR replacement in prod, a Keycloak restart guarantees a clean cache state. If a restart is undesirable, Keycloak Admin Console → Realm Settings → Themes → uncheck and re-check the theme selection to force a reload (varies by version).

### 8.4 Theme Versioning

The theme JAR version is tracked in `package.json` and tagged in the frontend repo on release (e.g., `keycloak-theme-v1.4.0`). The corresponding JAR is built in CI and uploaded as a release artifact. The Keycloak Dockerfile pulls a pinned version of the theme JAR at image build time.

---

## 9. Local Development Workflow

### 9.1 Storybook-Style Preview Without Keycloak

Keycloakify has a built-in dev server that simulates Keycloak's FreeMarker context. To iterate on a page without running Keycloak:

```bash
cd packages/keycloak-theme
pnpm run dev
```

Open `http://localhost:5173`. The dev server shows a navigation page to preview each Keycloak page with mocked `kcContext` data. Edit a component → hot reload.

The mock context is configured in `src/login/KcPageStory.tsx` (or per-page `*.stories.tsx` if Storybook is added).

### 9.2 Testing Against a Real Keycloak

For end-to-end verification, deploy the theme to the local Docker Compose Keycloak (per PRD §11.17):

```bash
# Build the JAR
pnpm run build-keycloak-theme

# Copy into the Keycloak Dockerfile build context
cp dist_keycloak/keycloak-theme-for-kc-26-and-above.jar ../../infra/keycloak/themes/knobby-theme.jar

# Rebuild and restart the local Keycloak
cd ../../infra
docker-compose -f docker-compose.test.yml up -d --build keycloak

# Wait ~30s for Keycloak to restart, then verify in the admin console.
```

For a tight iteration loop, the theme JAR can be mounted as a volume directly into the providers directory (bypasses the image rebuild) — useful for `test`, never for `prod`:

```yaml
# In docker-compose.test.yml, override the keycloak service:
keycloak:
  volumes:
    - ../packages/keycloak-theme/dist_keycloak:/opt/keycloak/providers
  command: start-dev --features=organization --spi-theme-cache-themes=false --spi-theme-static-max-age=-1
```

With this setup, rebuilding the theme JAR (without Docker rebuild) and refreshing the browser shows the new theme. Keycloak picks it up from the volume.

### 9.3 Triggering the Fallback Login Page for Testing

The themed login is the IdP picker fallback. To trigger it, hit the auth endpoint without `kc_idp_hint`:

```
http://localhost:8080/realms/knobby-test/protocol/openid-connect/auth
  ?client_id=knobby-test-web
  &response_type=code
  &redirect_uri=http://localhost:3000/auth/callback
  &scope=openid
  &state=test123
```

To trigger the error page: change `client_id` to a non-existent client.

To trigger logout confirmation: navigate to the logout endpoint without `id_token_hint`:

```
http://localhost:8080/realms/knobby-test/protocol/openid-connect/logout
```

---

## 10. Testing Strategy

### 10.1 Visual Regression

Optional but useful: add Storybook with the Keycloakify story integration, capture screenshots of each themed page in CI, compare against baseline. Tools: Chromatic, Percy, or Playwright with screenshot testing.

### 10.2 Functional E2E

Playwright tests against the `knobby-test` realm:

```typescript
import { test, expect } from "@playwright/test";

test("fallback login page renders with knobby branding", async ({ page }) =>
{
    await page.goto("http://localhost:8080/realms/knobby-test/protocol/openid-connect/auth?client_id=knobby-test-web&response_type=code&redirect_uri=http://localhost:3000/auth/callback&scope=openid&state=test");

    await expect(page.locator(".knobby-logo")).toBeVisible();
    await expect(page.locator(".knobby-idp-buttons a")).toHaveCount(3);  // Google, Microsoft, GitHub
    await expect(page.locator(".knobby-idp-btn-google")).toContainText("Continue with Google");
});

test("error page shows friendly message for invalid redirect URI", async ({ page }) =>
{
    await page.goto("http://localhost:8080/realms/knobby-test/protocol/openid-connect/auth?client_id=knobby-test-web&response_type=code&redirect_uri=https://evil.example/callback&scope=openid&state=test");

    await expect(page.locator(".knobby-auth-title")).toContainText("Sign-in error");
    await expect(page.locator(".knobby-auth-subtitle")).toContainText("not properly registered");
});
```

### 10.3 Accessibility

Lighthouse / axe-core checks on each themed page. The themed pages should at minimum meet WCAG 2.1 AA. Common issues to catch:
- Insufficient color contrast (especially error states).
- Missing form labels (Keycloakify provides defaults but custom forms need attention).
- Focus indicators on buttons and links.

---

## 11. CI/CD Integration

### 11.1 Build Pipeline

In the knobby.io frontend repo's CI config (e.g., GitHub Actions, GitLab CI):

```yaml
# .github/workflows/build-keycloak-theme.yml
name: Build Keycloak Theme

on:
  push:
    branches: [main]
    paths:
      - 'packages/keycloak-theme/**'
      - 'packages/design-system/**'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '21'
      - run: corepack enable
      - run: pnpm install --frozen-lockfile
      - run: pnpm --filter keycloak-theme run build-keycloak-theme
      - uses: actions/upload-artifact@v4
        with:
          name: knobby-keycloak-theme
          path: packages/keycloak-theme/dist_keycloak/*.jar
```

### 11.2 Theme Release Process

1. Bump version in `packages/keycloak-theme/package.json`.
2. PR merged to `main`.
3. CI builds the theme JAR and uploads as a release artifact.
4. Tag the release: `git tag keycloak-theme-v1.4.0`.
5. The infra repo (`knobby-infra-keycloak` per PRD §13) pins the theme version in its Keycloak Dockerfile.
6. Rebuild and redeploy the Keycloak image.

### 11.3 Coordination with Keycloak Version Upgrades

When upgrading the Keycloak version (e.g., 26.0 → 26.2):
1. Update the base image in the Keycloak Dockerfile.
2. Verify the theme's `keycloakVersionTargets` in `package.json` still covers the new version (`26-and-above` covers minor bumps).
3. Test in dev realm before promoting to prod.

Major Keycloak version jumps (26 → 27 in future) may break theme compatibility; Keycloakify typically releases a new major version in parallel with breaking-change support. Pin Keycloakify version accordingly.

---

## 12. Common Gotchas

### 12.1 FreeMarker Fallback for Pages Not Customized

If you don't override a particular page (e.g., `webauthn-register.ftl`), Keycloak falls back to the parent theme (`keycloak.v2` per our config). This page will look unbranded. For the pages in §2.1, ensure all are customized. For pages we'll never legitimately render (Registration, Forgot Password), accept the default — they're disabled at the realm level anyway.

### 12.2 Resource Paths

Static assets in Keycloakify themes are served from `${url.resourcesPath}/`. In React components, use the absolute import:

```tsx
<img src={`${kcContext.url.resourcesPath}/dist/assets/logo.svg`} alt="knobby.io" />
```

Or rely on Vite's static asset imports:

```tsx
import logoUrl from "../assets/logo.svg";
// ...
<img src={logoUrl} alt="knobby.io" />
```

The latter is preferred because Vite content-hashes the URL.

### 12.3 Inline Scripts and CSP

Keycloak ships with a strict Content Security Policy by default. Inline `<script>` tags and inline event handlers (`onclick="..."`) will be blocked. Stick to imported components and event listeners attached via React. Keycloakify-generated code is CSP-compatible.

### 12.4 Multi-Realm Theme Configuration

All three realms (`knobby-prod`, `knobby-dev`, `knobby-test`) use the same theme JAR. There's no realm-specific theme override needed; differences (e.g., "dev" badge in the UI) can be conditional in React based on `kcContext.realm.name`:

```tsx
{kcContext.realm.name !== "knobby-prod" && (
    <div className="knobby-env-badge">{kcContext.realm.name}</div>
)}
```

This shows a "dev" or "test" badge on the login page for non-prod realms — useful for catching when developers accidentally land on prod from a test session.

### 12.5 Account Linking Behavior

The account linking page (`login-idp-link-confirm-override.ftl`) only renders if the First Broker Login flow has it enabled. With our config (`first-broker-login-no-prompt`), it should never render because auto-linking by verified email happens silently. If it does render, it likely means a federation event with an unverified email — investigate as a possible misconfiguration or account takeover attempt.

### 12.6 Keycloakify Version Pinning

Keycloakify is actively maintained but occasionally introduces breaking changes (typically with major version bumps). Pin the version in `package.json` and update deliberately with theme regression testing.

### 12.7 The "Cookies Required" Page

If a user has third-party cookies blocked or has cookies disabled entirely, they see a "Cookies are required" error from Keycloak. This is one of the harder pages to test because reproducing it requires browser configuration. Worth at least one manual smoke test per release.

### 12.8 Theme Caching on JAR Replacement

Already covered in §8.3, but worth restating: replacing a JAR doesn't always immediately propagate. Some safe patterns:
- For prod: deploy a new image, restart Keycloak as part of the deploy.
- For dev: ditto, or use the volume-mount pattern for tight iteration (§9.2).
- For test: volume-mount + cache disabled.

---

## 13. References

- Keycloakify documentation: https://keycloakify.dev
- Keycloakify GitHub: https://github.com/keycloakify/keycloakify
- Keycloak theme documentation: https://www.keycloak.org/docs/latest/server_development/#_themes
- Bootstrap 5: https://getbootstrap.com/docs/5.3/
- knobby.io Authentication PRD: `KEYCLOAK_AUTH_PRD.md` (especially §9 and Invariant 3)
- knobby.io Design System package: `packages/design-system/README.md`

---

## 14. Maintenance Checklist

When making theme changes:

- [ ] Run `pnpm run dev` and visually verify the change locally.
- [ ] Run `pnpm run build-keycloak-theme` and confirm the JAR builds without errors.
- [ ] Deploy to local `knobby-test` Keycloak via volume mount (§9.2) and exercise the fallback URLs (§9.3).
- [ ] Run Playwright tests against `knobby-test` (§10.2).
- [ ] Bump theme version in `package.json` if releasing.
- [ ] Open a PR; CI builds and uploads the artifact.
- [ ] Pin the new theme version in the infra Dockerfile.
- [ ] Deploy to `knobby-dev` first; verify; then `knobby-prod`.
- [ ] Manually verify themed login renders correctly in `knobby-prod` post-deploy.
