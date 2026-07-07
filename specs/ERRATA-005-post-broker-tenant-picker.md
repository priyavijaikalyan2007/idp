# Errata 005 — Tenant picker must also run in the Post Broker Login Flow (fresh-session / IdP path)

**Date:** 2026-07-06
**Status:** Root cause confirmed + reproducible in production; fix direction settled; **implementation pending (needs a Claude Code spike against the 26.6.0 SDK).**
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

**Root cause — a known, longstanding Keycloak behavior (NOT a config error):** Keycloak issues [#10250](https://github.com/keycloak/keycloak/issues/10250) and discussion [#10251](https://github.com/keycloak/keycloak/discussions/10251) document it: **executions placed *after* an IdP-redirect step in a browser flow do not run for brokered logins.** After the IdP round-trip, Keycloak does **not** resume the browser flow at the point it left off. So the `Knobby MCP Tenant Picker` execution — which sits at the top level of `browser-mcp-tenant-pick` *after* the Authentication sub-flow — is **skipped** for any login that went out to an external IdP.

The already-logged-in case works only because the **Cookie** step satisfies authentication *without* an IdP redirect, leaving the browser flow intact so it reaches the picker. As soon as authentication requires a brokered IdP round-trip (every fresh session), the picker is bypassed.

This is architectural: the per-client browser-flow binding (ERRATA-001's routing mechanism) is correct and works for the Cookie path, but browser-flow executions after an IdP redirect are simply not reached for brokered logins.

---

## The decision (fix direction)

**Place the tenant picker in TWO flows, both guarded by MCP-client detection:**

1. **`browser-mcp-tenant-pick`** (browser flow, per-client bound by the CRP) — covers the **Cookie path** (already-logged-in). *Already works; unchanged.*
2. **Post Broker Login Flow** (per-IdP, on Google + Microsoft) — covers the **IdP path** (fresh session). *The fix.* This is Keycloak's sanctioned hook for "run an authenticator after brokered IdP login."

**⚠️ The critical constraint: Post Broker Login Flow is per-IdP, NOT per-client.** If the picker is added there naively, it fires for **web-app logins too** (the knobby.io web app uses the same Google/Microsoft IdPs) — reintroducing the exact "web login must not get the tenant picker" problem that per-client browser-flow binding was chosen to avoid.

**So the picker in the Post Broker Login Flow MUST be guarded by the MCP-client detection** — the same `knobby.mcp` attribute / `mcp-default` scope check as the browser-flow Authenticator's step-0 short-circuit (SPI §5.1). It runs the picker only for MCP clients and **no-ops for web-app logins**, even though the post-broker flow itself is per-IdP.

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
    → Knobby MCP Tenant Picker [Required]  ← tenant picker runs HERE
       → suspend → /mcp/consent → resume → tenant stamped
```

Both paths converge on the same Authenticator behavior (suspend → `/mcp/consent` → resume via the ERRATA-003 correlation-claim mechanism). The only difference is *which flow* hosts the picker execution for that path.

---

## Open questions for the implementation spike (verify against Keycloak 26.6.0 SDK)

These are why this errata is "fix direction settled, implementation pending" rather than a copy-paste:

1. **Does the existing `McpTenantPickerAuthenticator` run unmodified in the Post Broker Login Flow context?** The post-broker flow runs in a different context than the browser flow (post-first-broker-login, brokered-context session). Confirm the Authenticator's assumptions (auth session shape, `context.getUser()`, the client reference) hold there. **⚠️ Includes the re-entrancy guard from ERRATA-004:** `authenticate()` now reads the `knobby.mcp.picker.completed` auth note (via `authSession.getAuthNote(...)`) to detect callback-recorded completion and finish instead of re-challenging. Confirm that auth note is written/readable in the **post-broker** session context too — if the post-broker flow uses a different auth session than the one the callback wrote to, the guard won't see the note and the loop (ERRATA-004) could reappear on the IdP path. This is the single most important cross-check between 004 and 005.
2. **Is the CLIENT context available in the post-broker flow for the detection guard?** The MCP-detection short-circuit reads the client (`knobby.mcp` attribute / `mcp-default` scope). Confirm the client is resolvable in the post-broker context — if the post-broker flow doesn't carry the originating client cleanly, the guard needs a different signal.
3. **How does suspend/resume-to-`/mcp/consent` interact with the post-broker flow?** The ERRATA-003 resume (correlation claims → `getLastExecutionUrl`) was validated in the browser-flow context. Confirm the same suspend (challenge) + callback-resume works when the picker is hosted in the post-broker flow — the execution URL and auth-session correlation may differ.
4. **Config placement:** Post Broker Login Flow is set **per-IdP** (Identity providers → Google/Microsoft → Settings → *Post login flow*). Both Google and Microsoft need it. Confirm whether one shared post-broker flow (containing the guarded picker) can be reused across both IdPs (likely yes) or whether each needs its own.
5. **Interaction with `first-broker-login-no-prompt`:** the post-broker flow runs *after* first-broker-login. Confirm ordering and that the no-prompt first-broker flow (PRD §11.4) doesn't interfere.

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

1. **Claude Code spike** — resolve the five open questions above against the 26.6.0 SDK.
2. **Build/config** — create a Post Broker Login Flow containing the MCP-guarded tenant picker; set it as the Post Login Flow on Google + Microsoft IdPs.
3. **Update SPI §5.1** — short-circuit is load-bearing in the post-broker context.
4. **Re-run `mcp-e2e-interactive.sh` in a FRESH (incognito / cleared-cookie) session** — this is the case that reproduces the bug. The existing E2E may have been passing only because of a warm Cookie session; the acceptance test for this fix MUST start cookieless.
5. **Apply the doc edits** above once mechanics are confirmed.

---

## One-line summary

Browser-flow executions after an IdP redirect don't run for brokered logins (known Keycloak behavior), so the tenant picker is skipped for fresh sessions. Fix: also host the picker in the **Post Broker Login Flow** (per-IdP, on Google + Microsoft), **guarded by MCP-client detection** so it skips web-app logins — which makes the SPI short-circuit load-bearing again. Implementation needs a spike to confirm the Authenticator + suspend/resume work in the post-broker context.
