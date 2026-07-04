# knobby.io Auth — Deferred Items & Tech-Debt Register

**Purpose.** One place for everything consciously postponed during the Keycloak/MCP buildout. Scattered "TODO / defer / before GA" notes across four documents get forgotten — this register exists so nothing is lost, and so there is a single artifact to review before any milestone (especially public GA) and to hand anyone asking "what isn't done yet?"

**How to use it.**
- **Before public GA / before any untrusted third party can register clients:** review every row tagged `GA-BLOCKER` — none should still be open.
- **Before re-enabling refresh-token rotation:** the `ROTATION-GATE` rows must be done.
- **Each row has a *Trigger*** — the concrete condition that should un-defer it — and a ***Blast radius*** — what goes wrong if it's forgotten. The blast radius is deliberately blunt; a forgotten item with a named consequence is harder to drop than "TODO."
- This register is the **source of truth** for deferrals. Individual docs may describe *how*; this says *whether, why-deferred, when, and what-if-forgotten*. When you close an item, update it here.

**Category legend.**
- **GA-BLOCKER** — must be resolved before untrusted/public exposure. Forgetting = security exposure.
- **ROTATION-GATE** — must be done before refresh-token rotation is re-enabled.
- **CORRECTNESS** — a latent bug; not exposure per se, but breaks under load / transient failure.
- **ROADMAP** — sequenced feature work, not debt; here for visibility so it isn't conflated with debt.
- **ERGONOMICS** — improves errors/ops; not a security or correctness gap.

---

## A. Latent bugs (the incident-prone ones — highest attention)

| # | Item | Category | Trigger to fix | Blast radius if forgotten |
|---|------|----------|----------------|---------------------------|
| A1 | **App single-flight token refresh** (PRD §8.6.1 bug #1). App refreshes on nearly every request (~9×/21s observed); concurrent refreshes race. | CORRECTNESS / ROTATION-GATE | Before re-enabling refresh-token rotation; ideally now for resilience. | With rotation ON: concurrent requests hit "reuse exceeded" → session revoked → mass logout. With rotation OFF (current): a transient IdP blip still triggers refresh storms and wasted load. **This is the classic "fine until it isn't" bug.** |
| A2 | **Session-row update concurrency** (PRD §8.6.1 bug #2). `UpdateSessionAccessAsync` writes the session row under optimistic concurrency on every request; a failed advisory write invalidates a valid session. | CORRECTNESS | Now — independent of rotation; already caused logouts. | Concurrent requests collide on the session row → `DbUpdateConcurrencyException` → session invalidated → 401 cascade. Re-triggers on any load spike. Root cause: advisory last-access write treated as auth-critical. |
| A3 | **Cross-IdP claim gating** in the app (PRD §8.3.1). `microsoftTenantId`/`googleHd` must be gated on the matching `idp`. | GA-BLOCKER (authz correctness) | Before any multi-IdP tenant-authorization logic ships. | A Google session carrying a persisted `microsoftTenantId` (confirmed in prod) could be granted Microsoft-tenant-scoped authority if the app reads the claim without the `idp` guard. Privilege confusion across identity providers. |

## B. DCR / MCP hardening (deferred until untrusted third-party clients)

| # | Item | Category | Trigger to fix | Blast radius if forgotten |
|---|------|----------|----------------|---------------------------|
| B1 | **Custom `AllowedGrantTypesPolicy` CRP SPI** — reject disallowed grant types (password/implicit/client_credentials on public clients) *at registration*. See SPI design §"Planned providers". | ERGONOMICS + defense-in-depth | DCR-hardening phase / before untrusted DCR. | **Note:** ROPC is *already* blocked by the disabled Direct Grant flow (setup guide D.10) — this is not currently unprotected. Forgetting means DCR clients can *register* with odd grants (they just can't use ROPC); cleaner rejection and broader grant/auth-method enforcement is what's missing. |
| B2 | **Re-add Trusted Hosts CRP** (setup guide §F.1) — currently deleted to unblock dev. | GA-BLOCKER | Before untrusted parties can register against prod. | Forgotten → DCR clients can register redirect URIs on any host, enabling a class of token-redirection attacks. Real exposure at public GA. |
| B3 | **Re-add Allowed Protocol Mapper Types CRP** (setup guide §F.2) — currently deleted. | GA-BLOCKER (defense-in-depth) | Before untrusted DCR. | Forgotten → a malicious DCR client can self-attach protocol mappers. Mitigated by server-side claim validation (the primary defense), so this is belt-and-suspenders — but it's the belt you want before untrusted exposure. |
| B4 | **Neuter the Direct Grant flow** (setup guide D.10) — the enforceable ROPC control. | GA-BLOCKER — **verify done** | Now (it's the real ROPC control). Verify via smoke Test 23. | If NOT done: a DCR client can obtain tokens via `grant_type=password`. Federated-only realm has no local passwords, so ROPC should never succeed — confirm smoke Test 23 ("Password grant unusable (DCR)") is green. |

## C. MCP flow / Option B app-side work (feature completion, not debt)

| # | Item | Category | Trigger | Blast radius if forgotten |
|---|------|----------|---------|---------------------------|
| C1 | **`browser-mcp-tenant-pick` flow structure** — parked; needs the correct Required-subflow + IdP-selection step in 26.6.0 (nested-subflow-can't-be-Alternative constraint). | ROADMAP | When bringing up real MCP clients. | Not in use under Option B; binds per-client only. No current blast radius (governs zero traffic). Must be correct before first real MCP client, or MCP login fails. |
| C2 | **Knobby web post-DCR processing** — `assignMcpScopes` + `bindBrowserFlow` (web spec §7.2.1–7.2.3). | ROADMAP | When implementing the MCP consent slice. | Until built, DCR'd MCP clients lack scopes + flow binding (smoke Tests 23/25 stay red — expected). No security exposure; it's unbuilt feature work. |
| C3 | **HMAC handoff key** (`knobby-mcp-handoff-hmac-key-prod`) created + mounted (setup guide D.11). | ROADMAP | Before the MCP consent handoff goes live. | Handoff JWT signing/verification unavailable → MCP consent flow can't complete. No exposure pre-launch. |

## D. Rotation & token posture

| # | Item | Category | Trigger | Blast radius if forgotten |
|---|------|----------|---------|---------------------------|
| D1 | **Re-enable refresh-token rotation** (`Revoke Refresh Token` On, `Max Reuse` 0) — currently OFF. | ROTATION-GATE | After A1 (single-flight refresh) ships and is verified. | Rotation matters most for MCP public clients (tokens on user machines). Forgetting to re-enable = weaker theft-detection for those clients once they're live. Do NOT re-enable before A1 or it re-breaks logins. |

## E. Infrastructure / operational

| # | Item | Category | Trigger | Blast radius if forgotten |
|---|------|----------|---------|---------------------------|
| E1 | **Observability wiring** (setup guide §A.12) — Grafana Cloud OTLP push; event metrics + alerts. | ERGONOMICS (high value) | Any time; low effort, high payoff. | Not a security gap, but its absence is why the pooler/prepared-statement incidents took multiple debugging sessions instead of a glance at a graph. The pool-exhaustion alert alone pays for itself. |
| E2 | **Cloudflare posture for `auth.knobby.io`** (setup guide §A.11) — currently DNS-only after the 429 incident. | ROADMAP | When you want CDN/WAF in front of the IdP. | Re-proxying without the fixes (Rocket Loader off, rate-limits scoped off `/admin/*` `/resources/*`) re-breaks the admin console and smoke tests. Documented; just don't re-enable blindly. |
| E3 | **Keycloak → Hetzner migration** — cut always-on JVM cost; also fixes the DB connection-mode constraints (direct connection becomes viable, IPv6 available). | ROADMAP | Cost-driven, when Cloud Run JVM cost bites. | None if not done. When done: re-verify pooler config (§A.2.3), pool sizing (§A.2.3.1), and observability scrape model change to private/localhost. |
| E4 | **Dev/staging realms** (`knobby-dev`, `knobby-staging`) — topology planned, not created. | ROADMAP | Before you need a non-prod test surface. | Apply ALL learnings when created: pooler session-mode + `prepareThreshold=0`, pool caps, `ByAnonymous`-only condition, per-client Option B, all §11.7a IdP settings. Easy to reintroduce solved bugs on a fresh realm — this register is the checklist. |

## F. Enterprise / future auth surface (roadmap, from PRD §17)

| # | Item | Category | Trigger | Notes |
|---|------|----------|---------|-------|
| F1 | Audience taxonomy — shared `knobby-api` resource audience for the regular API (PRD §17.5 #1). | ROADMAP | When CLI/mobile/plugin clients arrive. | Today's per-client-id audience validation is correct for single-client; generalize before multi-client. |
| F2 | Service-context credential model (OAuth M2M vs native KM key vs federated) (PRD §17.4/§17.5). | ROADMAP | When first SDK/integration client is built. | Reuses existing agent KM/federated planes; needs provisioning UX. |
| F3 | Enterprise SSO (SAML/OIDC brokering, SCIM) (PRD §17.4). | ROADMAP | First enterprise customer. | Extends federated model; alias convention already reserved. |
| F4 | Directory-binding tenancy model (PRD §15). | ROADMAP | When multi-tenant directory binding is needed. | Depends on A3 (cross-IdP gating) being correct first. |

---

## Pre-GA review checklist (the "don't get breached" pass)

Before exposing MCP DCR to any untrusted third party or going public, confirm every **GA-BLOCKER** is closed:
- [ ] **B4** — Direct Grant flow neutered; smoke Test 23 green (ROPC unusable).
- [ ] **B2** — Trusted Hosts CRP re-added and scoped (§F.1).
- [ ] **B3** — Allowed Protocol Mapper Types CRP re-added (§F.2), or explicitly accepted as covered by server-side claim validation.
- [ ] **A3** — Cross-IdP claim gating implemented and tested in the app (§8.3.1).
- [ ] Consider **B1** — custom grant-types registration policy for cleaner rejection + broader enforcement.
- [ ] Rate-limiting back in front of DCR/token endpoints (if Cloudflare/WAF re-enabled per E2).

## Rotation re-enable checklist
- [ ] **A1** — single-flight refresh shipped and verified (concurrent-request test).
- [ ] **A2** — session-row write no longer invalidates valid sessions.
- [ ] Then **D1** — set `Revoke Refresh Token` On, `Max Reuse` 0; verify smoke Test 19 + no logout under concurrent load.

---

*This register should be reviewed at every milestone and kept in sync as items close. Consider referencing it from `CLAUDE.md` so the coding agent surfaces open items during related work. A register that is never reviewed is the same landmine with better formatting — the value is in the review discipline, not the document.*
