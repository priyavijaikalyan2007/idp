# Errata 006 — CRP must promote DCR-prebound scopes to default, and suppress the built-in consent

**Date:** 2026-07-07
**Status:** Scope-promotion SPI fix shipped and tested; built-in-consent suppression corrected to a Keycloak config fix (remove `consent-required` executor/CRP). B1 grant-type guard shipped 2026-07-08 (ADR-017). **No app-side change.**
**Applies to:** `KEYCLOAK_MCP_SPI_DESIGN.md` (§5.8) and `KEYCLOAK_SETUP_GUIDE.md` (§D.6a, §D.7).
**Companion to:** ERRATA-001 (the CRP itself) and ERRATA-004 (the resume loop). With ERRATA-004 the flow completes end-to-end; this errata fixes the two client-shape defects that surfaced once it did. Independent of **ERRATA-005** (post-broker tenant-picker hosting / fresh-session gap, still open) — that is about *which auth path reaches the picker*; this is about the *client shape* the CRP produces.

---

## Why this errata

After ERRATA-004, `smoke-mcp.sh` finally ran the whole chain — real login, tenant picker, `/mcp/consent`, resume, token — and exposed two independent defects, both in `McpClientRegistrationPolicy`:

### Defect 1 — MCP default scopes never become *default* client scopes

`smoke-mcp.sh` step 8 fails: the DCR'd client's **default-client-scopes** are missing `mcp-default` + the author bundle, even though the token's `aud` correctly includes `knobby-mcp-api` (so `mcp-default` *is* effective) and `knobby:admin` *is* correctly assigned as optional.

**Root cause.** Keycloak's OIDC DCR maps the registration request's `scope` field (`openid mcp-default knobby:read …`, which real MCP clients and the smoke test send) to the new client's **optional** client scopes — *before* the CRP's `afterRegister` runs. `ClientModel.addClientScope(scope, true)` is a **no-op when a binding already exists**, so it never promotes those already-optional scopes to default. The tell: `knobby:admin` is **not** in the request `scope`, so nothing pre-binds it, so the CRP's add works and it lands correctly as optional. Every scope the client *requests* is stuck wherever the DCR put it (optional); every scope it *doesn't* request is placed correctly by the CRP.

Why it matters: `mcp-default` carries the audience + tenant + scope-override mappers. As a **default** scope they fire on every authorization even if a client forgets to request `mcp-default`; as merely optional they fire only when requested. Default is the robust, intended placement.

Why the IT missed it: the IT's DCR request sent **no `scope` field**, so nothing was pre-bound and the no-op path never triggered. The IT now sends `scope` (mirroring prod) and asserts the scopes end up **default** — a real regression guard.

### Defect 2 — Keycloak's built-in consent screen double-ups the knobby wizard

After the `/mcp/consent` wizard, Keycloak still shows its own `OAUTH_GRANT` "Grant Access" screen. Cause: the `mcp-hardening` **consent-required** client-policy executor sets `consentRequired=true` on DCR clients (setup guide §D.6a). The knobby wizard is the authoritative consent surface, so Keycloak's screen is redundant double-consent.

---

## The decision (what's true now)

1. **Scope placement is authoritative via remove-then-add.** For every configured scope the CRP does `client.removeClientScope(scope)` then `client.addClientScope(scope, asDefault)`, so the default/optional placement is correct regardless of what the DCR request pre-bound. Both `removeClientScope(ClientScopeModel)` and `addClientScope(ClientScopeModel, boolean)` are verified present in 26.6.0.

2. **The CRP sets `consentRequired=false`** in `afterRegister` — but see the correction below: this alone does **not** win, so the real fix is a config change.

> **⚠️ CORRECTION (2026-07-08, verified in production via `smoke-mcp.sh`): the CRP override does NOT win — `consentRequired` reads `true` on the DCR'd client.** The original claim here (that because `triggerOnEvent` fires before `triggerAfterRegister`, the CRP's setter is last and wins) was wrong: the `consent-required` executor's `autoConfigure()` mutates the client **representation**, which is applied to the model *after* the CRP's `afterRegister`, re-setting `consentRequired=true`. (The IT passes only because it strips all registration policies, so no consent-forcer runs there — which is exactly why the IT was green while prod showed the consent screen.) **The authoritative fix is a config change: remove the `consent-required` executor from the `mcp-hardening` profile AND the `consent-required` Client Registration Policy if present.** The CRP's `setConsentRequired(false)` is retained as belt-and-suspenders (it becomes effective once the forcers are gone). Crucially, dropping Keycloak's consent does **not** weaken enforcement: the tenant picker + `/mcp/consent` wizard are gated by the auth flow (the picker is `REQUIRED` and suspends; no token issues until the app returns a valid HMAC-signed picker-result), which is stronger and non-redundant. The one control that *does* matter is grant-type restriction (no Direct Grant / ROPC) — now asserted by `smoke-mcp.sh` (`directAccessGrantsEnabled=false`).

3. **Still atomic.** Both mutations are in the same `afterRegister` transaction as the existing attribute/scope/flow marking; any throw still rolls back the whole registration.

---

## Changes by document

### `KEYCLOAK_MCP_SPI_DESIGN.md`
- **§5.8** — the CRP now (a) removes any pre-existing binding before assigning each scope so default/optional placement is authoritative, and (b) sets `consentRequired=false`. Note the DCR-pre-binds-requested-scopes-as-optional behavior and the executor-vs-afterRegister ordering.

### `KEYCLOAK_SETUP_GUIDE.md`
- **§D.5 / §D.6a** — remove `consent-required` from the anonymous Client Registration Policies and from the `mcp-hardening` Client Policy profile. The Knobby wizard is the consent surface; Keycloak's generic consent screen is redundant and the CRP cannot reliably override the executor.

### SPI code (applied)
- `McpClientRegistrationPolicy.assignScopes` — remove-then-add. `afterRegister` still calls `setConsentRequired(false)` as belt-and-suspenders once the config forcers are removed; the production correction proved that call alone does not win against the `consent-required` executor. The B1 grant-type guard now lives in `beforeRegister` / `beforeUpdate` so non-browser grants cannot bypass the picker/wizard. Tests cover scope promotion, local consent suppression in the stripped-policy IT harness, and password-grant DCR rejection.

---

## One-line summary

Requested DCR scopes are pre-bound **optional** before the CRP runs and `addClientScope` won't promote them, so the CRP now **removes-then-adds** to force default placement. On consent: the CRP's `setConsentRequired(false)` does **not** win against the `consent-required` executor (its `autoConfigure` re-applies `true` after the CRP) — so the real fix is **removing the `consent-required` executor + CRP** from the profile (the picker/wizard stay flow-enforced; the bypass control that matters is grant-type restriction).
