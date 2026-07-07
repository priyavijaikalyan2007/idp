# Errata 005 — Tenant picker must also run in the Post Broker Login Flow (fresh-session / IdP path)

**Date:** 2026-07-06 (spike completed 2026-07-07)
**Status:** Root cause confirmed + reproducible in production; **spike done against the 26.6.0 SDK — all five open questions resolved (see below). The existing `McpTenantPickerAuthenticator` works UNMODIFIED in the Post Broker Login Flow; the fix is CONFIGURATION-ONLY (create the post-broker flow + bind per-IdP). No code change to the authenticator logic and NO app-side change.** Remaining work: apply the admin-console config in each environment and run the fresh-session acceptance test.
**Applies to:** `KEYCLOAK_MCP_SPI_DESIGN.md` (the tenant-picker Authenticator, §5.1) and `KEYCLOAK_SETUP_GUIDE.md` (flow config, D.2/D.8) and the per-IdP config in `KEYCLOAK_AUTH_PRD.md` (§11.x IdP setup).
**Companion to:** ERRATA-001 (CRP bootstrap), ERRATA-002 (`/mcp/consent` split), ERRATA-003 (correlation claims), and ERRATA-004 (Claude Code's — separate topic). This (005) is a *distinct* gap from all of those — it's about *which authentication path* reaches the picker, not registration, the consent split, or the callback.

---

## Why this errata

With ERRATA-001/002/003 in place, the full MCP chain works end-to-end **for an already-logged-in session** — but **fails for a fresh (cookieless) session**, which is the common case for real pilot users (they won't already hold a Keycloak cookie).

**Reproducible difference:**

| Case | Auth path taken | Tenant picker runs? | Result |
|---|---|---|---|
| Already logged in | **Cookie** step (no IdP redirect) | ✅ Yes | Reaches `/mcp/consent`, works |
| Fresh / no cookie | **IdP redirect** (Google/Microsoft) | ❌ No | Keycloak's own consent shows; never hits `/mcp/consent` |

**Root cause — a known, longstanding Keycloak behavior (NOT a config error):** Keycloak issues [#10250](https://github.com/keycloak/keycloak/issues/10250) and discussion [#10251](https://github.com/keycloak/keycloak/discussions/10251) document it: **executions placed *after* an IdP-redirect step in a browser flow do not run for brokered logins.** After the IdP round-trip, Keycloak does **not** resume the browser flow at the point it left off. So the `YourApp MCP Tenant Picker` execution — which sits at the top level of `browser-mcp-tenant-pick` *after* the Authentication sub-flow — is **skipped** for any login that went out to an external IdP.

The already-logged-in case works only because the **Cookie** step satisfies authentication *without* an IdP redirect, leaving the browser flow intact so it reaches the picker. As soon as authentication requires a brokered IdP round-trip (every fresh session), the picker is bypassed.

This is architectural: the per-client browser-flow binding (ERRATA-001's routing mechanism) is correct and works for the Cookie path, but browser-flow executions after an IdP redirect are simply not reached for brokered logins.

---

## The decision (fix direction)

**Place the tenant picker in TWO flows, both guarded by MCP-client detection:**

1. **`browser-mcp-tenant-pick`** (browser flow, per-client bound by the CRP) — covers the **Cookie path** (already-logged-in). *Already works; unchanged.*
2. **Post Broker Login Flow** (per-IdP, on Google + Microsoft) — covers the **IdP path** (fresh session). *The fix.* This is Keycloak's sanctioned hook for "run an authenticator after brokered IdP login."

**⚠️ The critical constraint: Post Broker Login Flow is per-IdP, NOT per-client.** If the picker is added there naively, it fires for **web-app logins too** (the yourapp.com web app uses the same Google/Microsoft IdPs) — reintroducing the exact "web login must not get the tenant picker" problem that per-client browser-flow binding was chosen to avoid.

**So the picker in the Post Broker Login Flow MUST be guarded by the MCP-client detection** — the same `yourapp.mcp` attribute / `mcp-default` scope check as the browser-flow Authenticator's step-0 short-circuit (SPI §5.1). It runs the picker only for MCP clients and **no-ops for web-app logins**, even though the post-broker flow itself is per-IdP.

**Consequence — the SPI short-circuit is now LOAD-BEARING again.** Through ERRATA-001 it was downgraded to a "pure safety net" (because per-client browser-flow binding meant only MCP clients ever entered `browser-mcp-tenant-pick`). That reasoning does NOT hold for the Post Broker Login Flow, which is per-IdP and shared with web logins. So the detection guard is essential there, not decorative. **Do not remove it.** (SPI §5.1 should be updated to say: safety-net in the browser flow, load-bearing in the post-broker flow.)

---

## Design summary

```
Fresh session (no cookie):
  authorize → browser-mcp-tenant-pick
    Cookie [Alt]                 → fails (no cookie)
    IdP Redirector / IdP buttons → user picks Google/Microsoft → OUT to IdP
      ↩ returns → First Broker Login (first-broker-login-no-prompt)
      ↩ then → POST BROKER LOGIN FLOW  ← tenant picker runs HERE (MCP-guarded)
                 → suspend → /mcp/consent → resume → tenant stamped
  [browser flow's own picker step is NEVER reached on this path — expected]

Already-logged-in session:
  authorize → browser-mcp-tenant-pick
    Cookie [Alt] → succeeds (no IdP redirect)
    → YourApp MCP Tenant Picker [Required]  ← tenant picker runs HERE
       → suspend → /mcp/consent → resume → tenant stamped
```

Both paths converge on the same Authenticator behavior (suspend → `/mcp/consent` → resume via the ERRATA-003 correlation-claim mechanism). The only difference is *which flow* hosts the picker execution for that path.

---

## Spike results — all five questions resolved (Keycloak 26.6.0 SDK, 2026-07-07)

Verified by decompiling `LoginActionsService`, `AuthenticationProcessor`, `AuthenticationFlowURLHelper`, and `IdentityBrokerService` from the pinned 26.6.0 JARs. **Bottom line: the existing authenticator works unmodified; the fix is config-only.**

1. **Does the authenticator run unmodified in the Post Broker Login Flow? — YES.** The brokered login preserves a single `AuthenticationSessionModel` throughout (authorize → IdP round-trip → first-broker-login → post-broker-login), keyed by `(rootAuthSessionId, client, tabId)`. `LoginActionsService.postBrokerLoginGet/Post(authSessionId, code, execution, clientId, tabId, clientData)` recovers **that same** session, so `authSession.getClient()` is the original MCP client, `context.getUser()` is the brokered user (set before post-broker runs), and `authSession.getClientNote(state)` / `getClientScopes()` persist. **The ERRATA-004 re-entrancy note lives on that same session** — the callback recovers it by the identical correlation tuple and writes `yourapp.mcp.picker.completed` to it, and the post-broker resume re-enters `authenticate()` on that session and reads the note. So the loop does NOT reappear on the IdP path. (This was the critical 004↔005 cross-check.)
2. **Is the client available for the detection guard? — YES.** Same session ⇒ `authSession.getClient()` is the originating MCP client (post-broker resume is keyed on `clientId`). `isMcpClient` works and is **load-bearing** here: the post-broker flow is per-IdP and shared with web logins, so the guard is the only thing that no-ops the picker for non-MCP clients.
3. **Does suspend/resume-to-`/mcp/consent` work? — YES, unchanged.** `AuthenticationFlowURLHelper.getLastExecutionUrl(authSession)` is **flow-path-agnostic**: it rebuilds the resume URL from the `current.flow.path` auth note (falling back to `authenticate`) plus `current.authentication.execution`. When the picker challenges inside the post-broker flow, `LoginActionsService.brokerLoginFlow(...)` runs the `AuthenticationProcessor` with `setFlowPath("post-broker-login")`, so `current.flow.path = post-broker-login` is written. The callback's existing `getLastExecutionUrl` redirect therefore rebuilds `/login-actions/post-broker-login?execution=…` and resumes the **post-broker** flow correctly. No change to `McpPickerCallbackResourceProvider`.
4. **Config placement — ONE shared post-broker flow, bound on both IdPs.** A Post Login Flow is a realm-level `AuthenticationFlowModel` referenced by `IdentityProviderModel.getPostBrokerLoginFlowId()`; multiple IdPs may reference the same flow. Create one flow (e.g. `post-broker-mcp-tenant-pick`) with a single **Required** `YourApp MCP Tenant Picker` execution, and set it as the *Post login flow* on both Google and Microsoft. **Each execution needs its own `yourapp.web.host` AuthenticatorConfig** (config is per-execution) — set it on the post-broker execution just as on the browser-flow one.
5. **Interaction with `first-broker-login-no-prompt` — none.** `brokerLoginFlow` runs first-broker-login and post-broker-login as separate, sequential flows; post-broker runs *after* first-broker-login and on **every** brokered login (not just first link). No ordering conflict.

**Net: no code change to the authenticator's logic, no `McpPickerCallbackResourceProvider` change, no app change.** Only doc-in-code touch-ups (the §5.1 guard is now load-bearing in post-broker; marker/help text mention both flows) plus the admin-console config below.

---

## Changes by document (to apply once the spike confirms mechanics)

### `KEYCLOAK_MCP_SPI_DESIGN.md`
- **§5.1 (short-circuit guard)** — update the "safety net only" framing: the guard is a safety-net in `browser-mcp-tenant-pick` (per-client bound) but **LOAD-BEARING in the Post Broker Login Flow** (per-IdP, shared with web logins). Detection must work in both contexts.
- **New subsection (§5.1a or similar)** — document the two-flows design: picker in browser flow (Cookie path) AND post-broker flow (IdP path), both MCP-guarded, converging on the same suspend/resume behavior.

### `KEYCLOAK_SETUP_GUIDE.md`
- **D.2 / D.8 area** — add: the picker execution must also be added to a Post Broker Login Flow, set per-IdP on Google + Microsoft, guarded by MCP detection. Note the "browser flow executions don't run after IdP redirect" behavior as the reason.

### `KEYCLOAK_AUTH_PRD.md`
- **IdP setup sections (§11.x)** — add "Post Login Flow = <the guarded-picker post-broker flow>" to the per-IdP config checklist for Google and Microsoft, alongside the existing "First Login Flow = first-broker-login-no-prompt".

### `DEFERRED_ITEMS.md`
- **C5** — already logged (this errata is its detailed companion).

---

## What still needs doing

1. ~~**Claude Code spike**~~ — DONE (2026-07-07); all five questions resolved above.
2. ~~**Update SPI §5.1 + code docs**~~ — DONE: guard reworded as load-bearing-in-post-broker (`McpTenantPickerAuthenticator` comment + factory help text + marker), and SPI design §5.1 updated with the two-flows design.
3. **Build/config (admin console — per environment, OPERATOR ACTION):**
   - Create a top-level auth flow `post-broker-mcp-tenant-pick` with one **Required** execution: **YourApp MCP Tenant Picker**.
   - On that execution, set the config `yourapp.web.host` = the env's web host (e.g. `prod.yourapp.com`) — **same value as the browser-flow picker's config; it is per-execution, so it must be set here too.**
   - Identity providers → **Google** → *Post login flow* = `post-broker-mcp-tenant-pick`. Repeat for **Microsoft**. (One flow, both IdPs.)
   - Setup guide D.2/D.8 updated with these steps.
4. **Re-run `smoke-mcp.sh` in a FRESH (incognito / cleared-cookie) session** — this is the case that reproduces the bug; the acceptance test for this fix MUST start cookieless. (A warm Cookie session exercises only the browser-flow path, which already worked.)

---

## One-line summary

Browser-flow executions after an IdP redirect don't run for brokered logins (known Keycloak behavior), so the tenant picker is skipped for fresh sessions. Fix: also host the picker in the **Post Broker Login Flow** (per-IdP, on Google + Microsoft), **guarded by MCP-client detection** so it skips web-app logins — which makes the SPI short-circuit load-bearing again. Implementation needs a spike to confirm the Authenticator + suspend/resume work in the post-broker context.
