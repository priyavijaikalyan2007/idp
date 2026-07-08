# Errata 007 — `/mcp/consent` must authenticate from the signed handoff token, not an app session

**Date:** 2026-07-08
**Status:** Root cause confirmed in production (Keycloak log + app log + `chrome.har`). **The Keycloak / SPI side is complete and correct end-to-end. The remaining fix is entirely app-side (YourAppApi).**
**Applies to:** `YOURAPP_WEB_MCP_ENDPOINTS.md` (the `/mcp/consent` wizard) — the app-side companion to the SPI handoff.
**Companion to:** ERRATA-002 (the `/mcp/consent` split — this corrects a gap in it), ERRATA-003 (correlation claims), ERRATA-004 (resume re-entrancy), ERRATA-005 (post-broker picker). With 001–006 in place the whole chain works **except** the `/mcp/consent` page's own auth model.

---

## Why this errata

With the Keycloak side fully working — DCR marks the client (ERRATA-001/006), the tenant picker fires on **both** the Cookie path and the fresh/brokered path via the post-broker flow (ERRATA-005), and the callback resume is re-entrant (ERRATA-004) — the end-to-end flow **still fails for a user who is not already logged into the yourapp.com web app**, because the `/mcp/consent` wizard gates itself behind a **yourapp.com app session** instead of trusting the **signed handoff token** it is handed.

### The handoff token is self-sufficient (it already identifies the user)

The SPI redirects the browser to `https://<host>/mcp/consent?token=<picker-request JWT>`. The token has this representative shape:

```json
{ "iss": "keycloak-mcp-spi", "aud": "yourapp-web-mcp-consent",
  "sub": "6f3b7f23-148c-4865-ae17-178fe6d4bea7",
  "yourapp_sub": "6f3b7f23-148c-4865-ae17-178fe6d4bea7",
  "mcp_client_id": "846900a1-…", "iat": …, "exp": …, "jti": "…" }   // TTL 300s
```

It is HMAC-signed per-realm, `aud`-scoped to `yourapp-web-mcp-consent`, single-use (`jti`), and **carries the authenticated user** (`sub` / `yourapp_sub`). The app already validates it to read the user and requested scopes. **That token IS the authentication for this page.** Requiring a *separate* app session on top of it is the defect.

### What actually breaks (observed failure mode)

`chrome.har` + `idp.log` + `app.log`, fresh (cookieless) run:

1. `login-actions/post-broker-login` → **302 → `prod.yourapp.com/mcp/consent?token=…`** — picker fired correctly (Keycloak side ✅).
2. `GET /mcp/consent` (200) → `GET /api/v1/auth/me` — the app checks for an **app** session, finds none valid.
3. The app starts its **own** OIDC login (`client_id=yourapp-prod-web`). In `idp.log` this shows as a `REFRESH_TOKEN_ERROR` (`invalid_grant` / "Token is not active") on a stale session, then a `prompt=none` that fails and falls back to an **interactive second Google login**.
4. The app login **completes** (`/auth/callback`, `POST /api/v1/auth/exchange-code` 200) — but then lands on **`GET https://prod.yourapp.com/` (the app home page)**, having **lost the `return_url=/mcp/consent?token=…`**.
5. Consequences (measured in the HAR): `/mcp/consent` is requested **exactly once**; `mcp-picker-callback` is hit **zero times**. The suspended MCP auth flow is therefore never resumed, the throwaway client's loopback `/callback` never fires, and the flow hangs.

Two compounding layers, both app-side: (a) the page is gated behind an app session at all, and (b) the login it triggers doesn't return to the wizard. **Fixing (a) makes (b) moot.**

### Why the second login can't be silent (for context)

Even with SSO, the app's `prompt=none` can't reuse the Keycloak session, because **the MCP auth flow is *suspended* at the picker — it has not completed — so Keycloak has not created an SSO session yet** (that happens only when a flow finishes). So mid-suspension there is nothing to SSO against, forcing a full interactive login. This is inherent to the suspend-for-consent design and cannot be fixed Keycloak-side; the app must not depend on an app session here.

---

## The decision — the two flows the app-side fix MUST make correct

`/mcp/consent` authenticates the request **from the signed `?token=…`**, never from a yourapp.com app session. Both of these must work end-to-end:

### Flow 1 — user ALREADY logged into the web app (warm / Cookie path)
- Today this *happens* to work only because a valid app session is already present — but it is **fragile**: if that session's IdP token is near expiry, the wizard triggers a refresh, and a failed refresh (`"Token is not active"`, seen in the log) breaks even this path.
- **Required:** render the wizard from the token regardless of app-session state. Do **not** trigger a token refresh or a re-login as a side effect of opening `/mcp/consent`. A pre-existing app session may be used for convenience, but the token is the source of truth for *who* this consent is for.

### Flow 2 — user NOT logged into the web app (cold / fresh / incognito)
- This is the common real-pilot case and is currently **fully broken** (the dead-end above).
- **Required:** `/mcp/consent?token=…` renders the wizard directly from the token, with **no app-login redirect**. No `/api/v1/auth/me` gate that bounces to `login.html`; no dependence on `return_url` surviving a login round-trip (there is no login).

Both flows converge on the same behavior: **validate token → render wizard for `token.sub` with `token.mcp_requested_scopes` → on submit, sign the picker-result and POST it to `/realms/{realm}/mcp-picker-callback`** (unchanged; ERRATA-003/004 already handle the resume).

### Token validation the app must (still) do — this is the auth
- HMAC signature against the per-realm key; `iss == keycloak-mcp-spi`; `aud == yourapp-web-mcp-consent`; `exp` not passed; `jti` single-use (replay-guard). These already exist for reading the token — they simply become the **authentication gate** for the page, replacing the app-session check.
- ⚠️ **TTL is 300s.** With the login gate removed there is no second-login delay to eat into it, but the wizard is human-facing — keep the request path from the picker to the rendered wizard free of extra redirects, and surface a clean "link expired, restart from your MCP client" page if `exp` has passed rather than falling through to a login.

### If the app genuinely needs a user access token afterward
- Any backend calls the wizard/provisioning makes on the user's behalf should be derived from the **validated handoff** (the user is cryptographically proven by the token) — e.g. mint a scoped session from it, or use a service credential — **not** by forcing the user through an interactive login first.

---

## Changes by document

### `YOURAPP_WEB_MCP_ENDPOINTS.md` (app spec — the change to apply)
- `/mcp/consent` (GET): authenticate from the `?token=` handoff JWT; remove the app-session/`auth/me` gate and any login redirect. Document both Flow 1 and Flow 2 above as acceptance requirements.
- Add the expired-token UX (`exp` passed → "restart from your MCP client", not a login).

### App code (YourAppApi — separate repo)
- `/mcp/consent` handler: drop `GetCurrentUserAsync`/session-refresh as the entry gate; validate + trust the handoff token; render for `token.sub`.
- Remove the OIDC login round-trip that currently loses `return_url`.

### NOT changing (verified complete — do not touch)
- SPI: `McpTenantPickerAuthenticator` (browser + post-broker), `McpPickerCallbackResourceProvider`, `McpClientRegistrationPolicy`; the picker-request/result contract; `mcp-picker-callback`. All correct per ERRATA-001/003/004/005/006.

---

## What still needs doing

1. **App-side (YourAppApi):** implement token-authenticated `/mcp/consent` per above; verify **both** flows.
2. **Acceptance test — run `smoke-mcp.sh` in BOTH states:**
   - **Cold:** incognito / cleared cookies → complete Keycloak login + wizard → token issued, no second login, no app-home dead-end.
   - **Warm:** already logged into yourapp.com → complete wizard → token issued, and confirm a near-expiry app session does not break it.
3. **Separate, still open (Keycloak side):** Issue 1 — whether Keycloak's built-in "Grant Access" consent still appears (the `mcp-hardening` `consent-required` executor re-applies `consentRequired=true` on the post-register update, defeating the CRP's `afterRegister` override — ERRATA-006). Fix is to drop that executor from the profile. Could not be verified in the last run because the flow dead-ended before reaching it; test after this app-side fix lands.

---

## One-line summary

`/mcp/consent` is a **signed-token handoff target**, not an app page — it must render the wizard from the HMAC-signed `?token=` (which already carries the user) and must **not** gate on a yourapp.com app session. Doing so is currently the only thing blocking the fresh-session MCP flow (the app-login round-trip loses the `return_url` and dead-ends on the app home page); it also de-fragilizes the already-logged-in path. Keycloak/SPI side is done.
