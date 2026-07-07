# ERRATA-005 — Spike results & change log (handoff for setup-guide / PRD updates)

**Date:** 2026-07-07
**Author:** Claude Code (IdP repo spike)
**Purpose:** Self-contained summary of the ERRATA-005 spike and the changes shipped, so the setup guide, PRD, and any per-IdP runbooks can be updated. Companion to `specs/ERRATA-005-post-broker-tenant-picker.md` (the errata itself, now status-flipped to "spike done").

---

## TL;DR

- **Bug:** fresh (cookieless) MCP logins never reach `/mcp/consent`. Already-logged-in (Cookie) logins work.
- **Root cause (not a config error):** Keycloak does **not** run browser-flow executions placed *after* an IdP-redirect step for **brokered** logins ([issue #10250](https://github.com/keycloak/keycloak/issues/10250)). The tenant picker sits after the auth sub-flow in `browser-mcp-tenant-pick`, so it's skipped whenever login goes out to Google/Microsoft.
- **Fix:** host the **same** `YourApp MCP Tenant Picker` authenticator in a **Post Broker Login Flow** bound per-IdP. Verified against the 26.6.0 SDK that it works **unmodified** there.
- **Nature of the fix:** **CONFIGURATION-ONLY.** No change to the SPI authenticator logic, no change to the callback, and **no app-side change**.
- **Verdict for the app team:** **nothing to do.**

---

## What the spike verified (Keycloak 26.6.0 SDK)

Method: decompiled `LoginActionsService`, `AuthenticationProcessor`, `AuthenticationFlowURLHelper`, and `IdentityBrokerService` from the pinned `26.6.0` jars (`~/.m2/.../keycloak-services-26.6.0.jar`, `keycloak-server-spi-private-26.6.0.jar`).

| # | Open question | Result | Evidence in the SDK |
|---|---|---|---|
| 1 | Does `McpTenantPickerAuthenticator` run **unmodified** in the Post Broker Login Flow (auth session, `getUser()`, client ref, **ERRATA-004 re-entrancy note**)? | **YES** | Brokered login keeps a single `AuthenticationSessionModel` for the whole journey. `LoginActionsService.postBrokerLoginGet/Post(authSessionId, code, execution, clientId, tabId, clientData)` recover **that same** session by `clientId`+`tabId`. So `authSession.getClient()` = original MCP client, `context.getUser()` = brokered user, and the `yourapp.mcp.picker.completed` note the callback writes is on that same session → the ERRATA-004 loop does **not** reappear on the IdP path. |
| 2 | Is the **client** resolvable for the MCP-detection guard? | **YES** (and the guard is now **load-bearing**) | Same session ⇒ original client. The post-broker flow is **per-IdP** and shared with regular web-app logins (they use the same Google/Microsoft), so `isMcpClient` is the only thing that no-ops the picker for non-MCP clients. |
| 3 | Does suspend/resume-to-`/mcp/consent` work in post-broker? | **YES, unchanged** | `AuthenticationFlowURLHelper.getLastExecutionUrl(authSession)` is **flow-path-agnostic**: it rebuilds the resume URL from the `current.flow.path` auth note (default `authenticate`) + `current.authentication.execution`. `LoginActionsService.brokerLoginFlow(...)` runs the `AuthenticationProcessor` with `setFlowPath("post-broker-login")`, so `current.flow.path = post-broker-login`. The callback's existing `getLastExecutionUrl` redirect therefore rebuilds `/login-actions/post-broker-login?execution=…` and resumes the post-broker flow. **No change to `McpPickerCallbackResourceProvider`.** |
| 4 | Config placement — one shared flow or one per IdP? | **One shared flow, bound on both IdPs** | A Post Login Flow is a realm-level `AuthenticationFlowModel` referenced by `IdentityProviderModel.getPostBrokerLoginFlowId()`; multiple IdPs may reference the same flow. |
| 5 | Interaction with `first-broker-login-no-prompt`? | **None** | `brokerLoginFlow` runs first-broker-login and post-broker-login as separate sequential flows; post-broker runs *after* first-broker-login and on **every** brokered login (not just first link). |

### The single most important cross-check (004 ↔ 005)
The ERRATA-004 re-entrancy guard reads `authSession.getAuthNote("yourapp.mcp.picker.completed")`. Because the brokered login uses **one** auth session end-to-end (keyed by `root/client/tab`), the note the callback writes is the note the resumed post-broker `authenticate()` reads. **The loop cannot reappear on the IdP path.** This was the key risk and it's clear.

---

## The fix (operator configuration — this is what needs a runbook)

Per environment (`yourapp-prod`, `yourapp-dev`, …), in the Keycloak admin console:

1. **Authentication → Flows → Create flow** → name `post-broker-mcp-tenant-pick`, type **Basic flow**.
2. **Add step → YourApp MCP Tenant Picker**, requirement **Required**. (No sub-flows — authentication already happened upstream; this flow is *just* the picker.)
3. On that execution → **⚙ Config** → set **YourApp web host** (`yourapp.web.host`) = the env web host (e.g. `prod.yourapp.com`).
   - ⚠️ **Per-execution gotcha:** this config object is **separate** from the browser-flow picker's config. It must be set here too, or the step fails with `INTERNAL_ERROR` ("Authenticator config missing yourapp.web.host").
4. **Identity providers → Google → Post login flow** = `post-broker-mcp-tenant-pick`. Save.
5. **Repeat step 4 for Microsoft** (and any other brokered IdP an MCP user might use). One flow, multiple IdPs.
6. Leave **First login flow** as the existing `first-broker-login-no-prompt` — the two are separate and sequential.

### Acceptance test (must be cookieless)
- In an **incognito / cleared-cookie** browser, run `./smoke-mcp.sh` and complete Google/Microsoft login. Expect: `/mcp/consent` appears and the token carries a `tenant` claim.
- ⚠️ A warm Cookie session only exercises the already-working `browser-mcp-tenant-pick` path and will pass even if this config is missing — so the test MUST start cookieless.
- Confirm a **non-MCP web-app login** via the same IdP is unaffected (picker no-ops for it).

---

## Two-flows design (the mental model)

```
FRESH session (no cookie):
  authorize → browser-mcp-tenant-pick
      Cookie [Alt]        → fails
      IdP Redirector [Alt]→ OUT to Google/MS
        ↩ first-broker-login-no-prompt
        ↩ POST BROKER LOGIN FLOW  ← picker runs HERE (MCP-guarded), suspend→/mcp/consent→resume
      (browser-flow picker step is NEVER reached on this path — expected, #10250)

ALREADY-LOGGED-IN session (cookie):
  authorize → browser-mcp-tenant-pick
      Cookie [Alt] → succeeds (no IdP redirect)
      → YourApp MCP Tenant Picker [Required] ← picker runs HERE, suspend→/mcp/consent→resume
```

Exactly **one** picker firing per login: browser-flow on the Cookie path, post-broker on the IdP path. Both converge on identical suspend/resume behavior.

---

## Changes shipped in this repo (commit `4fed853`)

**Code — documentation-only (no behavior change):**
- `McpTenantPickerAuthenticator.java` — reworded the MCP-detection guard comment: **safety-net** in `browser-mcp-tenant-pick`, **load-bearing** in the Post Broker Login Flow (per-IdP, shared with web logins). Marker `📜 PURPOSE` now states the step is hosted in both flows.
- `McpTenantPickerAuthenticatorFactory.java` — `HELP_TEXT` now says: add as Required in **both** the browser flow and a per-IdP Post Broker Login Flow; set `yourapp.web.host` on **each** execution.

**Specs / knowledge:**
- `specs/ERRATA-005-post-broker-tenant-picker.md` — status flipped to "spike done"; the five open questions replaced with the resolved findings; "what still needs doing" reduced to the config steps + cookieless acceptance test.
- `specs/keycloak.spi.mcp.md` §5.1 — the ERRATA-005 note updated from "open spike question" to the confirmed result (config-only, load-bearing guard, resume mechanics).
- `specs/keycloak-setup-guide.md` — **new §D.2a** with the full config runbook above.
- `agentknowledge/decisions.yaml` — **ADR-015** (host picker in per-IdP post-broker flow; config-only; guard load-bearing; rejected the RequiredActionProvider alternative).
- `TECH_DEBT.md` — **TD-010** marked *superseded by ERRATA-005* (the earlier "bind realm-wide / Option A" idea is no longer the plan).
- `AGENT_INSIGHTS.md` §1.7, `agentknowledge/concepts.yaml`, `CHANGELOG.md`, `specs/keycloak.spi.mcp.status.md`, `CONVERSATION.md` — updated.

**No change to:** `McpTenantPickerAuthenticator` logic, `McpPickerCallbackResourceProvider`, `McpClientRegistrationPolicy`, the picker-request/result JWT contract, or any test. 135 unit + 2 IT still green.

---

## Suggested edits for Claude Desktop to make elsewhere

1. **`KEYCLOAK_AUTH_PRD.md` (per-IdP setup §11.x):** add "**Post login flow** = `post-broker-mcp-tenant-pick`" to the Google and Microsoft IdP config checklists, next to the existing "First login flow = `first-broker-login-no-prompt`".
2. **`DEFERRED_ITEMS.md` C5:** mark resolved / point at ERRATA-005 + this results doc.
3. **Any web-app / yourapp.com consent docs:** no change needed — the app side is unaffected (call this out explicitly so no one goes looking).
4. **Release/runbook checklist:** add "post-broker flow bound on all brokered IdPs" and "cookieless MCP acceptance test" as pre-GA gates.

---

## One-line summary

Fresh MCP logins skipped the tenant picker because Keycloak doesn't run post-IdP-redirect browser-flow steps for brokered logins (#10250); the fix is to also host the same picker in a per-IdP **Post Broker Login Flow**, which — per a 26.6.0 SDK spike — works **unmodified** (same auth session, flow-path-agnostic resume). It's **config-only**, the detection guard is now **load-bearing**, and there is **nothing to do on the app side**.
