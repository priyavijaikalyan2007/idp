# Errata 002 — App-side `/mcp/consent` after the registration-time CRP

**Date:** 2026-07-05
**Status:** Design settled; app-side implementation pending.
**Applies to:** `YOURAPP_WEB_MCP_ENDPOINTS.md` (the app spec), primarily §7.5 and §7.2.
**Companion to:** ERRATA-001 (the Keycloak-side CRP). Read that first.

---

## Why this errata

ERRATA-001 moved the MCP client **bootstrap** (assigning `mcp-default` + author-bundle scopes, binding `browser-mcp-tenant-pick`) out of the app and into a Keycloak CRP (`McpClientRegistrationPolicy`, SPI design §5.8) that runs **atomically at registration**. As a result, **web spec §7.5 is now stale and actively contradicts SPI §5.8**: it still instructs the app team to perform `assignMcpScopes` + `bindBrowserFlow` via the Admin API at `/mcp/consent`. This errata corrects the app-side contract.

**This is a doc-consistency fix (paying down a landmine), not new scope.** Left unfixed, §7.5 would send the app implementer to build the very thing the CRP now owns.

---

## What changes for the app

### Before (stale §7.5)
`/mcp/consent`, on first use of a DCR'd client, did the **full** provisioning:
1. `assignMcpScopes(clientId)` — Admin API PUT of default/optional scopes.
2. `bindBrowserFlow(clientId)` — Admin API set of `authenticationFlowBindingOverrides.browser`.
3. Persist `mcp_provisioned_clients` sub-step timestamps.

### After (CRP owns the bootstrap)
The **CRP** does steps 1–2 atomically at registration, before the client's first authorization. So `/mcp/consent` no longer needs to — and must not depend on being the thing that does — the scope/flow bootstrap.

`/mcp/consent` now does only the **wizard / tenant work**:
1. The tenant-picker wizard (§2.2–2.6) — user selects tenant + confirms scope bundle.
2. The **scope-override** for the user's actual consent choice (the SPI session-note → protocol-mapper mechanism, §16.7/§16.8) — this is per-authorization, not client bootstrap, and stays app-side.
3. Persist the `mcp_provisioned_clients` record (now a record of *consent/wizard completion*, not of scope/flow bootstrap).

### Idempotent re-assert (optional, belt-and-suspenders)
The app **may** still call `assignMcpScopes` / `bindBrowserFlow` idempotently as a safety net (e.g. if a client somehow reaches `/mcp/consent` without CRP marking — which shouldn't happen). If it does, these must be **idempotent** (adding an already-present scope / setting an already-correct binding = no-op) and **not the source of truth**. This is optional; the CRP is authoritative.

### `manage-clients` role — still required
Because the app still does the scope-override writes (step 2 above) and may idempotently re-assert, the `yourapp-{env}-admin-api` service account **still needs `manage-clients`** (PRD §11.13). The CRP does not remove that requirement.

---

## Spec edits needed in `YOURAPP_WEB_MCP_ENDPOINTS.md` (for the app team to apply)

> These are NOT yet applied — this errata is the instruction. Apply in the app-side implementation pass.

1. **§7.5.1 (trigger/sequence)** — add up top: "The scope + flow **bootstrap** is done by the Keycloak CRP at registration (SPI §5.8); this section covers the wizard/tenant work only. Do not rely on `/mcp/consent` to bootstrap scopes/flow."
2. **§7.5.3 (sequence pseudocode)** — remove `assignMcpScopes` + `bindBrowserFlow` as *required* steps; if kept, mark them "idempotent re-assert, optional safety-net, not source of truth."
3. **§7.5.2 (`mcp_provisioned_clients` table)** — reframe: `provisioned_at` now marks *wizard/consent completion*, not scope/flow bootstrap. The `scopes_assigned_at` / `flow_bound_at` sub-step timestamps become optional (the CRP guarantees those at registration); keep only if the app does the idempotent re-assert.
4. **§7.2.1 / §7.2.2 (`bindBrowserFlow` / `assignMcpScopes`)** — annotate: "Bootstrap now done by the CRP at registration (SPI §5.8). These remain available for optional idempotent re-assert but are no longer the primary mechanism."
5. **§7.5.4 (`manage-clients`)** — keep; still needed for the scope-override writes and optional re-assert.

---

## Verification (unchanged, still valid)

Smoke Test 25/25b and `mcp-e2e-interactive.sh` verify the resulting client shape regardless of *which* component (CRP vs app) set it. After the CRP is deployed:
- A raw DCR client (never through `/mcp/consent`) should **already** have `mcp-default` + author bundle + flow binding — because the CRP set them at registration. (This is a *new* expected state — previously the raw client was unprovisioned; now it's bootstrap-provisioned but not wizard-completed.)
- The interactive E2E should route through the picker (flow bound at registration) → `/mcp/consent` wizard → tenant claim present.

> **Note for smoke Test 25:** its "raw DCR client is unprovisioned — EXPECTED" skip logic (from the earlier design) may now be **wrong** — with the CRP, a raw client IS bootstrap-provisioned. Revisit Test 25's expectation when the CRP ships: a raw client should now show scopes + flow binding (from the CRP), but NOT wizard completion. Adjust the test to distinguish "CRP-bootstrapped" from "wizard-completed."

---

## One-line summary

The CRP now owns the scope/flow **bootstrap** at registration; `/mcp/consent` keeps only the **wizard/tenant/consent-override** work. Update web spec §7.5/§7.2 accordingly (this errata is the instruction); `manage-clients` is still required for the app's remaining writes.
