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
