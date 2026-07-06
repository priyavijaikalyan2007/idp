# yourapp.com Auth — Deferred Items & Tech-Debt Register

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
| B2 | **Trusted Hosts CRP** (setup guide §F.1) — **verified viable to KEEP ON** (2026-07-05 test). | GA-BLOCKER → **now: keep ON with `localhost`+`127.0.0.1` in list** | Re-add / keep before untrusted DCR. | ✅ **Empirically characterized 2026-07-05:** with `localhost` in the trusted list and "Client URIs Must Match" ON, Trusted Hosts **accepts `localhost:<any-port>`** — the arbitrary-loopback-port concern that originally motivated removal was unfounded. So Trusted Hosts is a *viable* GA control: it constrains redirect hosts (real token-redirection protection) while still permitting legitimate loopback MCP desktop clients. **Keep it ON**; include both `localhost` and `127.0.0.1` in the list (subsystems spell loopback differently). Config: Host-Sending-Request OFF, Client-URIs-Must-Match ON. This *supersedes* the earlier "may be the wrong control" concern. If forgotten (turned off) → DCR clients can register arbitrary redirect hosts (token-redirection risk). |
| B2a | **Redirect-URI executor swap** (setup guide D.6a): `secure-client-uris` → `secure-redirect-uris-enforcer` with loopback flags. | **DONE / verify** (was a live blocker) | N/A — must be correct for MCP to work at all. | ⚠️ **This blocked ALL MCP DCR in production (2026-07-05)** with `Invalid redirectUris`, misattributed first to Trusted Hosts, then to executor config. **Actual cause:** the profile had `secure-client-uris` (a FAPI-2.0 HTTPS-only enforcer with NO config and NO loopback exception — confirmed in Keycloak upgrade notes + javadoc). It cannot be configured to allow loopback; it must be **replaced** with `secure-redirect-uris-enforcer`, which has `allow-ipv4-loopback-address`/`allow-http-scheme` flags. Then use `127.0.0.1` (and/or `localhost` — subsystems disagree; register both). If forgotten/reverted, MCP desktop clients cannot register — total MCP outage. |
| B3 | **Re-add Allowed Protocol Mapper Types CRP** (setup guide §F.2) — currently deleted. | GA-BLOCKER (defense-in-depth) | Before untrusted DCR. | Forgotten → a malicious DCR client can self-attach protocol mappers. Mitigated by server-side claim validation (the primary defense), so this is belt-and-suspenders — but it's the belt you want before untrusted exposure. |
| B4 | **Neuter the Direct Grant flow** (setup guide D.10) — Layer 3 ROPC backstop. | GA-BLOCKER — **verify done** | Now (it's a ROPC control the CVE can't bypass). Verify via smoke Test 23. | If NOT done: with CVE-2026-9792, a DCR client could obtain tokens via `grant_type=password` even with reject-ropc configured. Federated-only realm has no local passwords, so ROPC should never succeed — confirm smoke Test 23 ("Password grant unusable (DCR)") is green. |
| B5 | **`reject-ropc` executor + CVE-2026-9792 patch** (setup guide D.10). | GA-BLOCKER (security) | Verify Keycloak patch level now; add executor via `any-client` policy. | 🔴 **CVE-2026-9792:** `reject-ropc` is silently bypassed when its policy uses `client-type`/`client-roles`/`client-attributes`/`client-scopes` conditions → attacker obtains ROPC tokens despite the block. **Mitigate:** (1) confirm 26.6.x includes the fix / upgrade; (2) bind reject-ropc via `any-client`, not the affected conditions; (3) keep the layered controls (B4 + per-client toggle). Test 23 catches a live bypass by testing the *effect* (no token issued), not the config. |

## C. MCP flow / Option B app-side work (feature completion, not debt)

| # | Item | Category | Trigger | Blast radius if forgotten |
|---|------|----------|---------|---------------------------|
| C1 | **`browser-mcp-tenant-pick` flow reached on first authorization** — resolved by the `McpClientRegistrationPolicy` CRP. | ROADMAP → **design settled, CRP to build** | When bringing up real MCP clients. | Was a real bootstrapping gap: a fresh DCR client had no `mcp-default`/flow-binding, so its first login fell through `browser-federated-only`, showed Keycloak's own consent, and never provisioned (observed in E2E 2026-07-05). **Resolved:** the CRP (SPI design §5.8) binds the flow + assigns scopes atomically at registration. Realm default stays `browser-federated-only`. Build the CRP; do NOT make the MCP flow the realm default. |
| C2 | **Provisioning split: bootstrap at registration (CRP) vs wizard at `/mcp/consent`** (SPI §5.8, web spec §7.5). | ROADMAP | When implementing the MCP consent slice + the CRP. | The CRP now does the scope+flow *bootstrap* atomically at registration. The app's `/mcp/consent` does the *rest* (tenant-picker wizard, `mcp_provisioned_clients` record). App-side change needed: `/mcp/consent` no longer must do the scope/flow bootstrap (may do so idempotently). Smoke Test 25/25b verify the resulting shape. No security exposure; sequenced feature work. |
| C3 | **HMAC handoff key** (`yourapp-mcp-handoff-hmac-key-prod`) created + mounted (setup guide D.11). | ROADMAP | Before the MCP consent handoff goes live. | Handoff JWT signing/verification unavailable → MCP consent flow can't complete. No exposure pre-launch. |

## D. Rotation & token posture

| # | Item | Category | Trigger | Blast radius if forgotten |
|---|------|----------|---------|---------------------------|
| D1 | **Re-enable refresh-token rotation** (`Revoke Refresh Token` On, `Max Reuse` 0) — currently OFF. | ROTATION-GATE | After A1 (single-flight refresh) ships and is verified. | Rotation matters most for MCP public clients (tokens on user machines). Forgetting to re-enable = weaker theft-detection for those clients once they're live. Do NOT re-enable before A1 or it re-breaks logins. |

## E. Infrastructure / operational

| # | Item | Category | Trigger | Blast radius if forgotten |
|---|------|----------|---------|---------------------------|
| E1 | **Observability wiring** (setup guide §A.12) — Grafana Cloud OTLP push; event metrics + alerts. | ERGONOMICS (high value) | Any time; low effort, high payoff. | Not a security gap, but its absence is why the pooler/prepared-statement incidents took multiple debugging sessions instead of a glance at a graph. The pool-exhaustion alert alone pays for itself. |
| E2 | **Cloudflare posture for `auth.yourapp.com`** (setup guide §A.11) — currently DNS-only after the 429 incident. | ROADMAP | When you want CDN/WAF in front of the IdP. | Re-proxying without the fixes (Rocket Loader off, rate-limits scoped off `/admin/*` `/resources/*`) re-breaks the admin console and smoke tests. Documented; just don't re-enable blindly. |
| E3 | **Keycloak → Hetzner migration** — cut always-on JVM cost; also fixes the DB connection-mode constraints (direct connection becomes viable, IPv6 available) and Cloud Run's JVM-hostile CPU/memory model. | ROADMAP (case strengthened 2026-07) | Cost-driven, and when Cloud Run JVM tuning (A.9a) is only holding perf together by running an always-on VM-equivalent. Plan: after current MCP work is E2E-green. | None if not done. Perf data (2026-07: CPU/mem pinned, latency spikes) showed Cloud Run fights the JVM; tuning (A.9a: `--no-cpu-throttling`, ≥1Gi, min-instances=1) is a stopgap. When done: re-verify pooler config (§A.2.3), pool sizing (§A.2.3.1), observability scrape model change to private/localhost, and DB direct-connection option (§A.2.3). |
| E4 | **Dev/staging realms** (`yourapp-dev`, `yourapp-staging`) — topology planned, not created. | ROADMAP | Before you need a non-prod test surface. | Apply ALL learnings when created: pooler session-mode + `prepareThreshold=0`, pool caps, `ByAnonymous`-only condition, per-client Option B, all §11.7a IdP settings. Easy to reintroduce solved bugs on a fresh realm — this register is the checklist. |
| E5 | **Interactive E2E acceptance test** (`mcp-e2e-interactive.sh`) — human-in-the-loop full-flow validation (DCR → real login → consent → provisioning → token). | ERGONOMICS (named GA gate) | Run before auth/MCP releases, after SPI/consent/flow changes, on new-env bring-up; a **pre-GA acceptance gate**. | Not a security gap in itself, but it's the only test that validates the *whole* real handoff. Its value depends on the discipline of running it at the right moments — a human test that isn't run is worthless. Lives in the infra repo (see note below). Three-tier model in web spec §9.3. |

## F. Enterprise / future auth surface (roadmap, from PRD §17)

| # | Item | Category | Trigger | Notes |
|---|------|----------|---------|-------|
| F1 | Audience taxonomy — shared `yourapp-api` resource audience for the regular API (PRD §17.5 #1). | ROADMAP | When CLI/mobile/plugin clients arrive. | Today's per-client-id audience validation is correct for single-client; generalize before multi-client. |
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
- [ ] **E5** — Interactive E2E test (`mcp-e2e-interactive.sh`) run and green against the target environment (full real handoff validated).
- [ ] Consider **B1** — custom grant-types registration policy for cleaner rejection + broader enforcement.
- [ ] Rate-limiting back in front of DCR/token endpoints (if Cloudflare/WAF re-enabled per E2).

## Repo placement (where these test artifacts live)

The auth test artifacts are **operator/infra tools** — they validate the deployed Keycloak realm over HTTP and assert external state — so they live in the **Keycloak/infra repo** alongside the setup guide, PRD, SPI, and Dockerfile, **not** in the yourapp.com app repo:
- `keycloak-smoke-test.sh` (tiers 1 + 1b, automated/browserless)
- `mcp-e2e-interactive.sh` (tier 2, human-in-the-loop)

yourapp.com's own unit/integration tests (`McpConsentService`, `assignMcpScopes`, the `mcp_provisioned_clients` state table, single-flight refresh) live in the **app repo** (web spec §9.1/§9.2). Rule of thumb: *talks to the deployed system over HTTP and asserts external state → infra repo; imports app modules and mocks dependencies → app repo.* Full three-tier model in web spec §9.3.

## Rotation re-enable checklist
- [ ] **A1** — single-flight refresh shipped and verified (concurrent-request test).
- [ ] **A2** — session-row write no longer invalidates valid sessions.
- [ ] Then **D1** — set `Revoke Refresh Token` On, `Max Reuse` 0; verify smoke Test 19 + no logout under concurrent load.

---

*This register should be reviewed at every milestone and kept in sync as items close. Consider referencing it from `CLAUDE.md` so the coding agent surfaces open items during related work. A register that is never reviewed is the same landmine with better formatting — the value is in the review discipline, not the document.*
