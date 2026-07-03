<!-- AGENT: Human-readable conversation log for this repository. Each session adds a chronological summary of work done, decisions made, files touched. Detailed code archaeology lives in agentknowledge/ and the spec docs; this file is the running narrative. -->

# Conversation Log — Knobby Keycloak IdP

The repository hosts a customised Keycloak 26.6.0 deployment that acts as the identity broker for Outcrop Inc. web properties. The MCP SPI work, which dominates the session log below, implements the OAuth + MCP tenant-picker handoff specified in `specs/keycloak.spi.mcp.md`.

---

## Session: 2026-06-07 → 2026-06-09 — MCP SPI implementation

### Scope of the session

Build, test, and ship the Keycloak MCP SPI end to end. Bring the repo from "specs and instructions only" to "deployable Docker image with full unit + IT coverage."

### Major decisions and shape changes

1. **Per-realm HMAC contract** (2026-06-07). The original spec assumed a single global `KNOBBY_MCP_HANDOFF_HMAC_KEY` env var and a single `KNOBBY_WEB_HOST`. The user pointed out we run one Keycloak instance hosting `knobby-prod`, `knobby-dev`, and (future) `knobby-test` realms — sharing one HMAC key across them would defeat env isolation. Restructured the entire contract to per-realm env vars `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` (and rotation-overlap `_PREVIOUS__<R>`) and moved `knobby.web.host` to per-realm Authenticator configuration in the Keycloak admin console. Touched `specs/keycloak.spi.mcp.md`, `specs/keycloak.prd.md`, `specs/keycloak.mcp.md`, `specs/keycloak.web.mcp.md`. Authored `specs/keycloak-hmac-operations-guide.md`. Recorded as ADR-001 and ADR-002.

2. **Implementation plan and slicing** (2026-06-08). Wrote `specs/keycloak.spi.mcp.status.md` per AGENTS.md V-V-P-T-I-R-V-C. Six slices: scaffolding → JWT primitives → scope mapper → Authenticator (suspend) → ResourceProvider (resume) → Testcontainers IT. Surfaced six open questions; user resolved all six (JBoss Logging, snake_case wire, seed agentknowledge now, SPDX author from CLAUDE.md, MIT licence, keep the IT slice).

3. **Slice execution** (2026-06-08). All six slices landed in TDD order. Final state: 108 unit tests + 1 IT, all green. Six concrete artefacts emerged:
   - `McpSpiConfig` / `McpSpiConfigException` — per-realm env-var resolver.
   - `ReplayCache` — bounded LRU.
   - `PickerRequestToken` / `PickerResultToken` — immutable JWT payload POJOs with Builder pattern, snake_case wire format via Jackson `@JsonProperty`.
   - `HandoffTokenSigner` / `HandoffTokenValidator` — per-realm key caches, current + previous key support for rotation overlap.
   - `McpScopeOverrideMapper` — implements only `OIDCAccessTokenMapper` (scope is access-token-only per OIDC; deviated from spec's three-interface pattern). Documented in code.
   - `McpTenantPickerAuthenticator` + `McpPickerCallbackResourceProvider` + their factories — suspend via `context.challenge(Response.seeOther(...))`, resume via `AuthenticationFlowURLHelper.getLastExecutionUrl(authSession)` + `AuthenticationSessionManager.getCurrentAuthenticationSession(realm, client, tabId)` with `getAuthenticationSessionByIdAndClient` fallback when the AUTH_SESSION_ID cookie is dropped.
   - The Testcontainers IT (`McpSpiLoadingIT`) boots real Keycloak 26.6.0 with the JAR and asserts the resource endpoint mounts correctly.

4. **Build pipeline and deployment glue** (2026-06-09). `build.sh` patched to compile the SPI, stage the JAR to `/target/providers/`, and pass build-args. `test.sh` created. `Dockerfile` env-var comments updated to per-realm contract. `cloudrun.yaml` updated with commented per-realm HMAC env stanza; spotted and fixed a pre-existing `KC_BOOTSTRAP_ADMIN_PASSWORD=` typo (trailing `=` had made the env-var name invalid — see TD-003).

5. **Image tagging rework** (2026-06-09). User asked for sortable unique tags. `build.sh` now produces three tags per build: `keycloak:local` (for `run.sh`), `<registry>:YYYYMMDDhhmmss-<commit>` (versioned, pushed, what Cloud Run revisions pin to), and `<registry>:latest` (moving tag for convenience pulls). `push.sh` pushes both remote tags. `build.json` records `build_timestamp` and `latest_tag` alongside the existing fields.

6. **JVM-noise cleanup** (2026-06-09). User flagged three categories of warnings/errors in test output. Two of them were legitimate (JBoss LogManager init order, JDK 21 dynamic-agent deprecation, CDS sharing). One was misidentified — the visible `ERROR/WARN` log lines from `McpPickerCallbackResourceProvider`, `McpTenantPickerAuthenticator`, etc. are the SPI's own log statements firing during tests that deliberately exercise error paths. Patched Surefire/Failsafe `<argLine>` with `-Xshare:off`, `-Djava.util.logging.manager=org.jboss.logmanager.LogManager`, and `-javaagent:${net.bytebuddy:byte-buddy-agent:jar}`. Added the `maven-dependency-plugin:properties` execution to resolve the byte-buddy-agent path. Build is now warning-free.

7. **Author-side script inventory completion** (2026-06-09). AGENTS.md lists ten expected scripts. Six pre-existed; four were missing. Added `clean.sh`, `run.sh`, `deploy.sh`, `prune.sh`. All bash-syntax validated; `clean.sh` tested end-to-end.

8. **End-of-session docs** (2026-06-09). Created `AGENT_INSIGHTS.md` and `TECH_DEBT.md` (modelled on `~/work/knobby/apps/` patterns). Updated `CHANGELOG.md`. Marker block check across all 27 Java files and all 6 shell scripts: production .java files all have SPDX + marker block; test .java files have SPDX (marker block omitted per MARKERS.md §9 exception for non-workflow utility files); shell scripts have both. Updated `agentknowledge/history.jsonl` after each meaningful unit.

### Files net new this session

| Category | Files |
|---|---|
| Java production | 13 files in `src/providers/src/main/java/io/knobby/keycloak/mcp/` |
| Java tests | 14 files in `src/providers/src/test/java/io/knobby/keycloak/mcp/` |
| Maven | `src/providers/pom.xml`, `src/providers/src/main/resources/META-INF/services/{AuthenticatorFactory,ProtocolMapper,RealmResourceProviderFactory}` |
| Specs | `specs/keycloak.spi.mcp.status.md`, `specs/keycloak-hmac-operations-guide.md` |
| Repo docs | `LICENSE.md` (MIT, Outcrop Inc.), `CHANGELOG.md`, `AGENT_INSIGHTS.md`, `TECH_DEBT.md`, `CONVERSATION.md` |
| Knowledge base | `agentknowledge/{concepts,decisions,entities,history}.yaml`/`.jsonl` |
| Scripts | `test.sh`, `clean.sh`, `run.sh`, `deploy.sh`, `prune.sh` |

### Files updated

`Dockerfile`, `build.sh`, `push.sh`, `cloudrun.yaml`, `.gitignore`, `specs/keycloak.spi.mcp.md` (bumped to v0.4), `specs/keycloak.prd.md`, `specs/keycloak.mcp.md`, `specs/keycloak.web.mcp.md`.

### Status at session end

- `./test.sh` → 108 unit + 1 IT green, ~ 46s, zero JVM warnings.
- `./build.sh` → produces `keycloak:local` plus two remote tags, OCI labels stamped, the SPI JAR baked into `/opt/keycloak/providers/`.
- All AGENTS.md scripts present.
- Eight ADRs recorded; ten history entries appended.
- Outstanding work tracked in `TECH_DEBT.md`: TD-001 (full OAuth-flow IT, deferred), TD-002 (Knobby web `/mcp/consent` — separate repo, blocking for launch), TD-003 (verify bootstrap admin still works after typo fix on next deploy), TD-005 (Keycloakify theme, parked), TD-006 (concepts.yaml gaps, low priority).

### What the next session should know

1. Read `agentknowledge/decisions.yaml` first — ADRs 001 through 008 record the load-bearing design choices.
2. Then `specs/keycloak.spi.mcp.status.md` for the slice-by-slice state.
3. If touching the JWT shape, both tokens currently use Jackson `@JsonProperty` for snake_case wire format. The test fixtures (`validBuilder()` helpers in each test class) need to add the field to be updated in lockstep.
4. The IT only proves SPI registration; for full flow verification, see TD-001 or run `./smoke.sh` against a deployed Keycloak.
5. If the cloudrun.yaml env block needs new HMAC entries, see `specs/keycloak-hmac-operations-guide.md` §3.6 for the structure.

---

## Session: 2026-06-10 — Production deploy incident and exoneration of the SPI image

### What happened

The first Cloud Run deploy of the SPI image (`20260610050525-b0a2d5e`) appeared to break production: admin-console login worked, but switching realms raised `relation "offline_user_session" does not exist` (SQLState 42P01) on the session-persist commit path, and the background `user-session-purge-expired` task raised `relation "realm" does not exist` on plain stock-Keycloak SQL (`select re1_0.ID from REALM re1_0`). All tables verifiably existed (lower-case, public schema, correct database). A rollback to the previous day's known-good image *also* failed during the same window; the May 26 image and a freshly-built vanilla image (empty providers dir) later started fine, which initially pointed the finger at the SPI JAR.

### How it was debugged

1. **Exact-artifact reproduction.** The literal failed image ID (`561570e70d17`) was still present locally. It was run with the production entrypoint (`start --optimized`) against a Postgres 16 sidecar whose schema had been pre-initialised by the *vanilla* image — mirroring production, where older images created the schema.
2. **Result: fully healthy.** Clean startup with the SPI loaded, admin token grants, realm creation and listing (the failing "switch realms" path), four rows written to `offline_user_session` (the table production claimed was missing), `mcp-picker-callback` answering `{"error":"missing_token"}`, and a 6+ hour soak with zero errors — including silent clean runs of the purge task that had failed in production.
3. **Config diff.** `kc.sh show-config` between the vanilla and SPI images differs by exactly one line: the provider-JAR registration entry. No datasource, Hibernate, or Agroal configuration is touched by the augmentation.

### Conclusion

The image is innocent. The failures cluster by *time window*, not by image content (the rollback image failed in the window too), and "some connections see the tables, others don't" is a connection-routing symptom consistent with a transient on the Neon pooler/compute side — not something a JAR baked at `kc.sh build` time can cause. Speculative edits to `McpPickerCallbackResourceProvider` (removing `final` and the method-level `@Path("/")`) made while the JAX-RS theory was live were reverted: the Testcontainers IT and the soak prove the original code correct, and the comments justifying the edits asserted a causal mechanism the evidence disproved. The operator redeployed the SPI image after the window cleared.

### Artefacts from the session

- `check_image.sh` — image-forensics helper (labels, baked providers, Quarkus artifacts) for diffing a suspect image against a known-good one.
- `build.json` untracked and gitignored — it is volatile build output (regenerated by every `./build.sh`, deleted by `./clean.sh`).
- `cloudrun.yaml` refreshed to the live revision shape: per-realm HMAC secret binding (`KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD` from Secret Manager) and `KC_DB_PASSWORD`/`KC_BOOTSTRAP_ADMIN_PASSWORD` from secrets.
- New insights in `AGENT_INSIGHTS.md` §5 (incident debugging); `TECH_DEBT.md` TD-003 resolved, TD-007 (base-image SHA pinning) and TD-008 (`run.sh` does not exercise the optimized entrypoint) added.

### What the next session should know

1. The MCP SPI is deployed to production. The Knobby web `/mcp/consent` companion (TD-002) remains the launch blocker.
2. If 42P01-style "relation does not exist" errors recur on tables that exist, suspect the Neon pooler/compute first; `check_image.sh` plus the §"How it was debugged" recipe above is the fast falsification path for image theories.
3. `run.sh` boots `start-dev`, which re-augments and therefore cannot reproduce optimized-build issues — use the TD-008 recipe (production entrypoint against the sidecar) for incident reproduction.

---

## Session: 2026-07-01 — Non-MCP client short-circuit

The user updated spec §5.1 with a step-0 short-circuit guard and asked for it to be implemented before configuring the MCP flows. Problem being solved: when `browser-mcp-tenant-pick` is bound realm-wide as the default browser flow (setup guide D.8 Option A), the Authenticator's `authenticate()` runs for *every* client — including regular `knobby-{env}-web` logins and service clients — and without a guard it would 302 all of them to Knobby web's `/mcp/consent`, breaking normal login.

Implemented via TDD (V-V-P-T-I-R-V-C): verified `ClientModel.getClientScopes(boolean) -> Map<String,ClientScopeModel>` and `AbstractAuthenticationFlowContext.success()` against the 26.6.0 JARs first (per AGENT_INSIGHTS §1.1), wrote 5 failing tests, then added the guard. An MCP client is one carrying the `mcp-default` client scope as a default or optional scope; non-MCP clients get `context.success()` (a pass-through — `success()` not `attempted()`, since `attempted()` would fail a REQUIRED execution) and the flow finishes as a normal login. Extracted `MCP_CLIENT_SCOPE` constant + `isMcpClient(ClientModel)` helper. 113 unit + 1 IT green. Recorded ADR-009.

**Configuration implication surfaced for the user:** `mcp-default` is now the single on/off switch for the whole handoff. The flow can be bound realm-wide safely, but MCP clients must have the `mcp-default` scope assigned (default or optional) for the picker to fire.

Documentation swept (concepts, decisions ADR-009, history, status log, changelog), committed, and a new image built + pushed for the user to redeploy after finishing realm configuration.

---

## Session: 2026-07-03 — Reconcile SPI with post-July-1 spec updates

The user asked to double-check all SPI-spec updates since the July-1 implementation and map required changes. Findings:

- **`keycloak.spi.mcp.md` §5.1** gained one change: a DETECTION-SIGNAL CAVEAT. The pseudocode is unchanged; the implementation still matches. The caveat warns that `mcp-default`-scope detection only holds while `mcp-default` is not a realm-default scope, and offers an escape hatch (a DCR-time `knobby.mcp` client attribute) for anyone forced onto Option A.
- **Driving context (commit 1e67e13):** setup guide D.8 reversed the flow-binding recommendation from Option A to **Option B** after Option A took down all logins in testing (a malformed MCP flow bound realm-wide returns HTTP 400 for every login). PRD §17's new client taxonomy (mobile, browser plugins, user-context CLI) leans on the SPI short-circuit to pass non-MCP interactive clients through — matching the current code with no contract change.

**Conclusion: no SPI source change required.** Under the recommended Option B, `mcp-default` is never a realm default, so the current `isMcpClient` guard is correct and acts as a pure safety net.

**The required work was documentation drift from July 1** (all mine): `keycloak.web.mcp.md §7.2.1` still recommended Option A. Fixed it to recommend Option B and align with setup guide D.8. Recorded ADR-010 correcting ADR-009's "bound realm-wide safely" framing, updated the `McpTenantPickerAuthenticator` concept, added a CHANGELOG correction entry, and filed **TD-009** for the deferred `knobby.mcp`-attribute hardening (YAGNI under Option B; revisit if Option A is ever adopted).
