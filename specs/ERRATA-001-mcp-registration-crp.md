# Errata 001 — MCP client bootstrapping via registration-time CRP

**Date:** 2026-07-05
**Status:** Implemented 2026-07-06 (ADR-011); B1 grant-type guard folded in 2026-07-08 (ADR-017).
**Scope of this errata:** the decision to bind the MCP browser flow and assign MCP scopes **atomically at client registration** via a custom `ClientRegistrationPolicy` (CRP), replacing the earlier plan of doing it in the app at `/mcp/consent` first-use. This is a **focused, self-contained change** — read this instead of diffing the full PRD/SPI/guide.

---

## Why this change

The end-to-end interactive test (2026-07-05) exposed a **bootstrapping gap**. A freshly DCR'd MCP client has no `mcp-default` scope and no `browser-mcp-tenant-pick` flow binding. The earlier design bound the flow + assigned scopes in the app at `/mcp/consent`. But:

- To reach `/mcp/consent`, the SPI in `browser-mcp-tenant-pick` must run.
- The SPI only runs if the client is **bound** to that flow.
- Binding happened *at* `/mcp/consent`.

→ **Circular dependency.** A fresh client's first authorization falls through the realm-default `browser-federated-only` flow, shows Keycloak's own consent screen, and never provisions. (Observed exactly: E2E test showed `default scopes: [basic]; browser-flow override: none`, Keycloak's native consent page, and `FAIL token tenant` / `FAIL flow binding` / `FAIL default scopes`.)

**Resolution:** mark the client at **registration time** — before its first authorization — using a CRP whose `afterRegister(ClientRegistrationContext, ClientModel)` mutates the live client **in the registration transaction**. This is atomic (no partial states) and is the same hook Keycloak's own built-in CRPs use.

---

## The decision (what's true now)

1. **A new CRP — `McpClientRegistrationPolicy`** — assigns `mcp-default` + author-bundle scopes (default), `knobby:admin` (optional), sets a `knobby.mcp=true` client attribute, and binds `browser-mcp-tenant-pick`, **atomically at registration**. Deployed as an **anonymous** Client Registration Policy (Clients → Client registration → Anonymous Access Policies — same CRP system as Trusted Hosts).

2. **Atomicity removes partial-failure handling.** Because `afterRegister` mutates the `ClientModel` in-transaction, either the client registers fully-marked or registration rolls back. "Scope assigned but flow unbound" (and vice-versa) **cannot occur**. No recovery/reconciliation logic needed.

3. **Realm default stays `browser-federated-only`.** The MCP flow is **never** the realm default. Per-client binding via the CRP is the only routing into `browser-mcp-tenant-pick`.

4. **The SPI short-circuit (§5.1 step 0) is now a pure safety net**, not load-bearing. Correctness comes from atomic binding at registration. The short-circuit's detection was updated to prefer the `knobby.mcp` attribute.

5. **Provisioning splits into two phases:**
   - **At registration (CRP):** `mcp-default` + author bundle + flow binding + `knobby.mcp` attribute. The *bootstrap*.
   - **At `/mcp/consent` (app):** the tenant-picker wizard, tenant-specific scope-override/consent recording, and the `mcp_provisioned_clients` record. The *wizard/tenant work*.
   - Both are idempotent; both touching the client is safe.

6. **B1 allowed-grant-types enforcement folds into this CRP.** Both concerns are `ClientRegistrationPolicy` work — B1's grant-type rejection belongs in this CRP's `beforeRegister` / `beforeUpdate`. One SPI, not two. This was implemented on 2026-07-08 (ADR-017).

---

## Changes by document (focused edit list)

### `KEYCLOAK_MCP_SPI_DESIGN.md`
- **§5.1 step 0 (short-circuit guard)** — rewritten. Now labeled "SAFETY NET ONLY (not load-bearing)". Detection prefers `client.getAttribute("knobby.mcp") == "true"` over `mcp-default` scope. Explains correctness now comes from §5.8, not this guard.
- **§5.8 (NEW) — `McpClientRegistrationPolicy`** — full new component spec: purpose (closes bootstrapping gap), why a CRP + `afterRegister`, atomicity property, Java interface sketch (scope assignment + attribute + flow binding on the ClientModel), anonymous-CRP deployment, the "verify 26.6.0 model API signatures" caveat, interactions with §5.1 and web-spec §7.5, and the B1-folding note.

### `KEYCLOAK_AUTH_PRD.md`
- **§11.13 (`manage-clients` note)** — updated. Bootstrap writes now happen in the CRP (in-Keycloak), not app Admin API calls. App still needs `manage-clients` for the `/mcp/consent` tenant/wizard writes.
- **§16.x flow-override table row** ("Auth flow override to browser-mcp-tenant-pick") — replaced. Now: "bound atomically at registration by the CRP (§5.8)"; realm default stays federated-only; both earlier options (realm-wide binding; app-at-/mcp/consent) documented as rejected, with reasons.

### `KEYCLOAK_SETUP_GUIDE.md`
- **D.7 (Assign MCP scopes)** — rewritten. The CRP assigns scopes at registration; not realm-default; not app-at-/mcp/consent. Manual-testing fallback retained.
- **D.8 (Bind the browser flow)** — rewritten. The CRP binds at registration (atomic) is the recommended/settled mechanism. Explains why binding at `/mcp/consent` was too late (circular dependency). Realm-wide (Option A) still rejected. Manual-testing fallback retained.

### `DEFERRED_ITEMS.md`
- **C1** — reframed from "flow structure parked" to "bootstrapping gap, resolved by the CRP; build the CRP."
- **C2** — reframed to the provisioning split (CRP bootstrap vs `/mcp/consent` wizard) + the app-side implication.

---

## Current follow-up state

1. **CRP implementation is shipped.** `McpClientRegistrationPolicy` lives in the existing SPI Maven module and marks anonymous-DCR MCP clients atomically at registration.
2. **B1 is shipped in the same CRP.** `beforeRegister` and `beforeUpdate` reject non-authorization-code grants at DCR registration/update (ADR-017).
3. **Post-broker fresh-login routing is config-only and documented.** ERRATA-005 settled the fresh/cookieless path by placing the same picker authenticator in a per-IdP Post Broker Login Flow.
4. **The remaining launch blocker is app-side.** ERRATA-007 supersedes the old `/mcp/consent` follow-up: the app must authenticate the consent route from the signed handoff token, not from a Knobby app session.
5. **The environment still needs the consent-forcer removed.** Per ERRATA-006/ADR-016, remove the `consent-required` executor and CRP from the MCP hardening profile so Keycloak's built-in consent screen does not double-up the Knobby wizard.

---

## One-line summary

Mark MCP clients (scopes + flow binding + attribute) **atomically at registration via a CRP**, not in the app at first `/mcp/consent` — closing the circular bootstrapping gap and making the first authorization route correctly.
