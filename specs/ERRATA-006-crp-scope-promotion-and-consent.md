# Errata 006 — CRP must promote DCR-prebound scopes to default, and suppress the built-in consent

**Date:** 2026-07-07
**Status:** Root cause confirmed in production (`smoke-mcp.sh`); SPI-side fix applied + tested (unit + IT). **No app-side change.**
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

2. **The CRP suppresses the built-in consent** — `client.setConsentRequired(false)` in `afterRegister`. This is safe against the `consent-required` executor because, per the 26.6.0 `AbstractClientRegistrationProvider` bytecode, the client-policy executors fire on `triggerOnEvent` (the `DynamicClientRegistered` event) **before** `triggerAfterRegister` (the CRP) — so the CRP runs last and its setter wins. The knobby `/mcp/consent` wizard remains the sole consent surface. (Chosen over removing the executor from the mcp-hardening profile, which would be per-environment admin config rather than code that travels with the deployment.)

3. **Still atomic.** Both mutations are in the same `afterRegister` transaction as the existing attribute/scope/flow marking; any throw still rolls back the whole registration.

---

## Changes by document

### `KEYCLOAK_MCP_SPI_DESIGN.md`
- **§5.8** — the CRP now (a) removes any pre-existing binding before assigning each scope so default/optional placement is authoritative, and (b) sets `consentRequired=false`. Note the DCR-pre-binds-requested-scopes-as-optional behavior and the executor-vs-afterRegister ordering.

### `KEYCLOAK_SETUP_GUIDE.md`
- **§D.6a** — note that for MCP (anonymous-DCR) clients the CRP deliberately overrides the `consent-required` executor back to `consentRequired=false`; the knobby wizard is the consent surface. (First-party clients are unaffected — they don't go through this CRP.)

### SPI code (applied)
- `McpClientRegistrationPolicy.assignScopes` — remove-then-add. `afterRegister` — `setConsentRequired(false)`; log line + marker updated. 2 new unit tests (promotion removes-before-adds; consent suppressed) + no-op test tightened. IT now sends `scope` (reproduces the prod condition, clears all default registration policies so the scoped anonymous DCR reaches the CRP) and asserts default-scope placement + `consentRequired=false`.

---

## One-line summary

Requested DCR scopes are pre-bound **optional** before the CRP runs and `addClientScope` won't promote them, so the CRP now **removes-then-adds** to force default placement; and the CRP sets **`consentRequired=false`** (it runs after the consent-required executor, so it wins) to leave the knobby `/mcp/consent` wizard as the sole consent surface.
