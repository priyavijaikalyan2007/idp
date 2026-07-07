# Errata 003 — Picker-result must echo the `kc_*` session-correlation claims

**Date:** 2026-07-06
**Status:** Root cause confirmed in production; SPI-side + spec fixes applied; **app-side echo implemented 2026-07-06** (YourAppApi echoes all three claims from the server-held picker-request; awaiting e2e re-run).
**Applies to:** `YOURAPP_WEB_MCP_ENDPOINTS.md` (app spec, §2.2 + §3.3) and `KEYCLOAK_MCP_SPI_DESIGN.md` (§5.3, reconciled).
**Companion to:** ERRATA-001 (Keycloak-side CRP) and ERRATA-002 (app-side `/mcp/consent` split). Independent of both — this is the *final* handoff hop, not the registration bootstrap.

---

## Why this errata

With ERRATA-001/002 in place the whole MCP chain works **except the last hop**: when the app posts the `picker_result` back to `/realms/{realm}/mcp-picker-callback`, Keycloak returns **HTTP 400** and the SPI logs:

```
WARN McpPickerCallbackResourceProvider: Picker callback realm=yourapp-prod client=null not found
```

`client=null` is not a lookup miss — it is a **missing claim**. The SPI callback recovers the suspended authentication session (and its client) from three correlation claims carried **inside the signed picker-result**:

- `kc_client_id` — the Keycloak client id, used for `realm.getClientByClientId(...)`
- `kc_tab_id` — the auth-session tab id
- `auth_session_id` — the root auth-session id (cookie-drop fallback)

The SPI has expected these since the callback was built. **But the app never sends them**, because the app spec (`§2.2` step 5 / `§3.3`) defines the picker-result claim set **without** them. The app was built correctly to a spec that was out of sync with the SPI. Decoding the production `picker_result` confirms it: `iss, aud, jti, nonce, picker_request_jti, user_sub_echo, chosen_tenant_id, granted_scopes, oauth_state` — and **no `kc_*` claims**.

**This is a contract desync, not a resume-mechanics defect.** The correlation values already exist: the SPI's *picker-request* carries `kc_client_id` / `kc_tab_id` / `auth_session_id` (verified), and the app holds the full picker-request in server-side session state for the wizard's duration (§2.1). The app simply needs to copy three fields into the result. The SPI already resumes via Keycloak's own action URL (`AuthenticationFlowURLHelper.getLastExecutionUrl`) — no resume rework is needed.

---

## The decision (what's true now)

1. **The picker-result MUST echo `kc_client_id`, `kc_tab_id`, and `auth_session_id`** from the picker-request. These are part of the picker-result contract, full stop.

2. **They must be sourced from the SERVER-HELD picker-request, never from the client's `/authorize` POST body.** The app validated and stored the picker-request server-side at `§2.1`; echo the `kc_*` values from *that* held token — the same way `oauth_state` is already echoed. Trusting client-supplied `kc_*` would let a caller point the resume at a different client/session (session-fixation surface). This is a defense-in-depth requirement, not a convenience.

3. **The SPI now fails loud and precise.** A picker-result missing any of the three correlation claims returns a distinct `missing_correlation` error (not the misleading `client_not_found`), with a WARN that names the contract and points at this errata. `client_not_found` now means only what it says: a well-formed `kc_client_id` that resolves to no client.

4. **No SPI resume re-architecture.** The alternative (re-route suspend/resume through `context.getActionUrl()` / `session_code` and resume in `action()`) was considered and rejected as unnecessary: it discards tested code and swaps tamper-proof signed-claim correlation for URL-param correlation, to solve a problem that is really a missing echo.

---

## Changes by document

### `KEYCLOAK_MCP_SPI_DESIGN.md`
- **§5.3 (callback resume)** — reconciled with the shipped implementation. The old pseudocode (`findAuthSessionByJti(pickerRequestJti)` + `AuthenticationProcessor.continueAuthentication()`) never matched reality and implied jti-based correlation we do not do. It now documents: recover client via `kc_client_id`, recover the auth session via `AuthenticationSessionManager.getCurrentAuthenticationSession` (cookie) with `getAuthenticationSessionByIdAndClient(auth_session_id, …)` fallback, resume via `getLastExecutionUrl`, and the new `missing_correlation` guard + the correlation-claim contract.

### `YOURAPP_WEB_MCP_ENDPOINTS.md` (app spec — **echo change still to apply in the app**)
- **§2.2 step 5 (picker-result claim set)** — add `kc_client_id`, `kc_tab_id`, `auth_session_id`, each **echoed from the server-held picker-request** (not the POST body).
- **§3.3 (picker-result generation)** — call out the echo + the server-side-sourcing security requirement.

### SPI code (applied)
- `McpPickerCallbackResourceProvider` — `missing_correlation` guard before the client lookup; marker/JavaDoc note the contract. 1 new unit test signs the app's exact (correlation-less) claim set and asserts `missing_correlation`.

---

## What still needs doing (app side — NOT in this errata's SPI/spec edits)

1. **App change (YourAppApi `/api/mcp/consent/authorize`)** — include `kc_client_id`, `kc_tab_id`, `auth_session_id` in the signed picker-result, copied from the server-held picker-request. This is the change that actually clears the 400.
2. **Re-run `mcp-e2e-interactive.sh`** — with the app echoing the claims, the callback resolves the client, resumes the flow, and the token carries the `tenant` claim + granted scopes. The `client=null` 400 clears.

---

## One-line summary

The `client=null` 400 is a **missing echo**, not a resume bug: the app must copy `kc_client_id` / `kc_tab_id` / `auth_session_id` from the server-held picker-request into the signed picker-result. The SPI now reports their absence as `missing_correlation`, and §5.3 is reconciled to reality.
