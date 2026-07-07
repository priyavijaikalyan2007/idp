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

---

## Session: 2026-07-04 — Repository orientation summary

The user asked for a summary of the repository's purpose and the agent's role in it. Read `README.md`, `agentknowledge/{concepts,entities,decisions}.yaml`, `CONVERSATION.md`, recent `git log`, and the MCP SPI status document. No source code or behavior was changed.

Summary provided: this repo is the customized Keycloak 26.x identity broker for Outcrop Inc./Knobby web properties, with Java SPI code, themes/deployment scripts, Cloud Run configuration, and detailed specs for MCP/OAuth 2.1/DCR support. The agent's role is to act as the repository's implementation and maintenance engineer, following the documented V-V-P-T-I-R-V-C/TDD workflow, preserving the knowledge base and conversation history, keeping specs/docs synchronized, and making small, verified, committed changes when implementation work is requested.

Correction from user: `CODEX.md` contains a critical role override. The primary role in this repository is red-team security lead for the Keycloak IdP: analyze repository, implementation, setup, and runtime for security issues, vulnerabilities, bypasses, DDoS exposure, patch/CVE posture, and write security reports for a separate coding agent to fix. Unless explicitly asked, do not modify existing code; review changes with the user and produce security findings/remediation reports instead.

### Red-team review follow-up

The user asked for a red-team analysis of everything done so far by the coding agent, including Keycloak setup instructions and whether any security credentials had been checked in. Produced `specs/security-red-team-report-2026-07-04.md`.

Key findings: no plaintext production secret values were found in tracked files or git-history pattern scans, but a local untracked `keycloak_neon.dump` PostgreSQL dump exists and is ignored but world-readable by file mode. The highest-risk issues are: Keycloak is pinned to 26.6.0 while upstream current is 26.6.4 with multiple security fixes; bootstrap admin env vars remain mounted in `cloudrun.yaml`; Cloud Run uses the default compute service account; DCR redirect-host/protocol-mapper hardening and WAF/rate limiting remain deferred; setup docs still contain contradictory `mcp-default` realm-default checklist text; the MCP SPI should add server-side picker-request/result correlation and scope validation before public MCP exposure; replay protection is per-JVM; and Dependabot only covers pip, not Docker/Maven.

No source implementation code was modified. The report is intended as a handoff artifact for a coding agent or operator to fix in priority order.

### Secret scanner and GitHub security automation follow-up

The user approved installing Gitleaks and TruffleHog and asked for a full local secret scan first, plus GitHub repository security-tool configuration where available. Installed Gitleaks 8.30.1 and TruffleHog 3.95.8 under `/tmp/security-tools`. Reports were written under `/tmp/security-scan` and not committed.

Scan results: Gitleaks found 5 redacted findings in git history and 3 in the working tree, all reviewed as documentation/config-example false positives (`YOUR_ACCESS_TOKEN` Auth0 examples and a JDBC env-var example). TruffleHog found 0 verified and 0 unverified secrets in both git-history and working-tree scans. The sensitive local `keycloak_neon.dump` finding remains because dumps are sensitive even when scanners do not detect token-like strings.

GitHub repository changes: enabled Dependabot alerts and automated security fixes via GitHub API; GitHub secret scanning / push protection returned HTTP 422 ("Secret scanning is not available for this repository") for this private repo. Updated `.github/dependabot.yml` to cover Docker, Maven, and GitHub Actions; added `.github/workflows/codeql.yml`; added `.github/workflows/dependency-review.yml`; rewrote `SECURITY.md` for the Keycloak IdP instead of the old UI-library scope. YAML parsed successfully with PyYAML and `git diff --check` passed.

Live GCP read-only check: active `gcloud` account is `priyavijai.kalyan2007@proton.me`; configured project is `stellar-zoo-478023-v4`. A read-only `gcloud run services describe knobbyauth --region=asia-southeast1` succeeded and confirmed the latest service still has bootstrap admin env vars mounted and still uses the default compute service account.

---

## 2026-07-06 — MCP client registration policy (CRP): atomic bootstrapping at registration

**Request.** Production testing uncovered a circular dependency in how DCR'd MCP clients get their scopes and browser-flow binding. The SPI design, PRD, and setup guide were updated, plus a focused `specs/ERRATA-001-mcp-registration-crp.md`. The user asked me to review the changes (ERRATA first), discuss, make a plan, and only implement after review.

**Review & decisions.** Read ERRATA-001, SPI design §5.1 (updated short-circuit) + §5.8 (new CRP), web spec §7.5, setup guide D.2/D.7/D.8, and the current authenticator. Confirmed the core: a fresh DCR client has no `mcp-default` scope and no `browser-mcp-tenant-pick` binding, so its first authorization can't be detected as MCP (deadlock: binding was planned at `/mcp/consent`, which requires the binding to already exist). Fix: a new `McpClientRegistrationPolicy` CRP marks every MCP client atomically at registration. Raised concerns and got the user's calls: (1) all anonymous DCR = MCP (anonymous registration is the only signal); (2) scope lists + flow alias are ComponentModel config-driven; (3) scope = CRP + §5.1 update only (defer B1, no app change); (4) add a pointer note to web spec §7.5.

**Implementation (TDD).** Phase 0: verified every 26.6.0 model-API signature via `javap` against the pinned BOM jars — notably that `ClientRegistrationPolicyException extends RuntimeException` (so `afterRegister`, which declares no checked throws, can throw to roll back), and that the built-in `ClientScopesClientRegistrationPolicy` is an exact structural template. Also confirmed the documented `browser-mcp-tenant-pick` structure (D.2) is valid and 26.6.0-constraint-aware. Built `McpClientRegistrationPolicy` + factory + META-INF/services in a new `clientreg` package; `afterRegister` sets `knobby.mcp=true`, assigns default + optional scopes, binds the browser flow, all in-transaction. Updated `McpTenantPickerAuthenticator.isMcpClient` to prefer the `knobby.mcp` attribute and reworded the §5.1 short-circuit as a pure safety net (resolves TD-009). Tests: 15 CRP unit tests, 1 real-DCR testcontainers IT (drops the default Trusted Hosts anon policy, registers the CRP as anonymous, does anonymous DCR, asserts the client shape), 1 authenticator unit test. **129 unit + 2 IT green.**

**Docs/knowledge.** ADR-011; new `McpClientRegistrationPolicy` concept; history.jsonl line; CHANGELOG (Added + Changed); status-log row; web spec §7.5 interim pointer note; TD-009 marked Resolved. No `/mcp/consent`/app changes (ERRATA item #2 follow-on); B1 grant-types still deferred. Verification path handed to the user: deploy, register the CRP as an anonymous policy (D.8), re-run `smoke-mcp.sh` — a fresh DCR client should now be fully-marked without visiting `/mcp/consent`.

---

## 2026-07-06 — Picker-result correlation claims: the callback `client=null` fix (ERRATA-003)

**Request.** After the CRP work, the end-to-end MCP login worked except the final hop: the app posts the picker-result back to `/realms/knobby-prod/mcp-picker-callback` and Keycloak returns 400 with the SPI logging `client=null not found`. The user asked me to find the fault (Keycloak vs app), check whether ERRATA-002 already covered it, and — per the desktop assistant's hand-off — consider re-architecting the resume around `getActionUrl`/`session_code`.

**Diagnosis.** Decoding the app's picker-result JWT showed it lacks `kc_client_id`/`kc_tab_id`/`auth_session_id`. The SPI callback recovers the suspended session + client from exactly those three signed claims (`getClientByClientId(token.getKcClientId())` → null → `client=null`). The picker-REQUEST already carries them and the app holds the request server-side (§2.1), so the correlation exists — the app just isn't echoing it. Root cause: **contract desync** — web spec §2.2/§3.3 defined the picker-result claim set without the `kc_*` claims (added SPI-side in Slice 4), so the app built to a stale spec. Told the user two things they asked about: ERRATA-001 (CRP) is fully implemented; ERRATA-002 is the app `/mcp/consent` split and does NOT cover this; and the "updated SPI spec §5.9 step 7" the desktop referenced never landed — the file still had the old §5.3 (jti-correlation + `AuthenticationProcessor`), which is what misled the diagnosis toward a resume rewrite.

**Decision.** Fix A (echo the claims), not the re-architecture: the correlation is already available and signed; the SPI already resumes via Keycloak's own action URL (`getLastExecutionUrl`). Documented as ERRATA-003 (user's naming).

**Implementation.** SPI: added a `missing_correlation` guard (distinct from `client_not_found`) with a spec-pointing WARN + `isBlank` helper + marker note in `McpPickerCallbackResourceProvider`; TDD unit test signs the app's exact correlation-less claim set and asserts `missing_correlation` (18 provider tests green). Specs: ERRATA-003; web spec §2.2 step 5 + §3.3 now require the three echoed claims, sourced from the **server-held** picker-request (not the client POST body — a session-fixation guard I flagged); reconciled the stale SPI §5.3 to the real design. Docs: ADR-012, CHANGELOG (Fixed), history, status row. **The app-side echo in KnobbyApi (separate repo) is the remaining change that actually clears the 400** — I can't make it from this repo.
