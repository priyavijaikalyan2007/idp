<!-- AGENT: Human-readable conversation log for this repository. Each session adds a chronological summary of work done, decisions made, files touched. Detailed code archaeology lives in agentknowledge/ and the spec docs; this file is the running narrative. -->

# Conversation Log — YourApp Keycloak IdP

The repository hosts a customised Keycloak 26.6.0 deployment that acts as the identity broker for Outcrop Inc. web properties. The MCP SPI work, which dominates the session log below, implements the OAuth + MCP tenant-picker handoff specified in `specs/keycloak.spi.mcp.md`.

---

## Session: 2026-06-07 → 2026-06-09 — MCP SPI implementation

### Scope of the session

Build, test, and ship the Keycloak MCP SPI end to end. Bring the repo from "specs and instructions only" to "deployable Docker image with full unit + IT coverage."

### Major decisions and shape changes

1. **Per-realm HMAC contract** (2026-06-07). The original spec assumed a single global `YOURAPP_MCP_HANDOFF_HMAC_KEY` env var and a single `YOURAPP_WEB_HOST`. The user pointed out we run one Keycloak instance hosting `yourapp-prod`, `yourapp-dev`, and (future) `yourapp-test` realms — sharing one HMAC key across them would defeat env isolation. Restructured the entire contract to per-realm env vars `YOURAPP_MCP_HANDOFF_HMAC_KEY__<R>` (and rotation-overlap `_PREVIOUS__<R>`) and moved `yourapp.web.host` to per-realm Authenticator configuration in the Keycloak admin console. Touched `specs/keycloak.spi.mcp.md`, `specs/keycloak.prd.md`, `specs/keycloak.mcp.md`, `specs/keycloak.web.mcp.md`. Authored `specs/keycloak-hmac-operations-guide.md`. Recorded as ADR-001 and ADR-002.

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

8. **End-of-session docs** (2026-06-09). Created `AGENT_INSIGHTS.md` and `TECH_DEBT.md` (modelled on `~/work/yourapp/apps/` patterns). Updated `CHANGELOG.md`. Marker block check across all 27 Java files and all 6 shell scripts: production .java files all have SPDX + marker block; test .java files have SPDX (marker block omitted per MARKERS.md §9 exception for non-workflow utility files); shell scripts have both. Updated `agentknowledge/history.jsonl` after each meaningful unit.

### Files net new this session

| Category | Files |
|---|---|
| Java production | 13 files in `src/providers/src/main/java/io/yourapp/keycloak/mcp/` |
| Java tests | 14 files in `src/providers/src/test/java/io/yourapp/keycloak/mcp/` |
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
- Outstanding work tracked in `TECH_DEBT.md`: TD-001 (full OAuth-flow IT, deferred), TD-002 (YourApp web `/mcp/consent` — separate repo, blocking for launch), TD-003 (verify bootstrap admin still works after typo fix on next deploy), TD-005 (Keycloakify theme, parked), TD-006 (concepts.yaml gaps, low priority).

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
- `cloudrun.yaml` refreshed to the live revision shape: per-realm HMAC secret binding (`YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD` from Secret Manager) and `KC_DB_PASSWORD`/`KC_BOOTSTRAP_ADMIN_PASSWORD` from secrets.
- New insights in `AGENT_INSIGHTS.md` §5 (incident debugging); `TECH_DEBT.md` TD-003 resolved, TD-007 (base-image SHA pinning) and TD-008 (`run.sh` does not exercise the optimized entrypoint) added.

### What the next session should know

1. The MCP SPI is deployed to production. The YourApp web `/mcp/consent` companion (TD-002) remains the launch blocker.
2. If 42P01-style "relation does not exist" errors recur on tables that exist, suspect the Neon pooler/compute first; `check_image.sh` plus the §"How it was debugged" recipe above is the fast falsification path for image theories.
3. `run.sh` boots `start-dev`, which re-augments and therefore cannot reproduce optimized-build issues — use the TD-008 recipe (production entrypoint against the sidecar) for incident reproduction.

---

## Session: 2026-07-01 — Non-MCP client short-circuit

The user updated spec §5.1 with a step-0 short-circuit guard and asked for it to be implemented before configuring the MCP flows. Problem being solved: when `browser-mcp-tenant-pick` is bound realm-wide as the default browser flow (setup guide D.8 Option A), the Authenticator's `authenticate()` runs for *every* client — including regular `yourapp-{env}-web` logins and service clients — and without a guard it would 302 all of them to YourApp web's `/mcp/consent`, breaking normal login.

Implemented via TDD (V-V-P-T-I-R-V-C): verified `ClientModel.getClientScopes(boolean) -> Map<String,ClientScopeModel>` and `AbstractAuthenticationFlowContext.success()` against the 26.6.0 JARs first (per AGENT_INSIGHTS §1.1), wrote 5 failing tests, then added the guard. An MCP client is one carrying the `mcp-default` client scope as a default or optional scope; non-MCP clients get `context.success()` (a pass-through — `success()` not `attempted()`, since `attempted()` would fail a REQUIRED execution) and the flow finishes as a normal login. Extracted `MCP_CLIENT_SCOPE` constant + `isMcpClient(ClientModel)` helper. 113 unit + 1 IT green. Recorded ADR-009.

**Configuration implication surfaced for the user:** `mcp-default` is now the single on/off switch for the whole handoff. The flow can be bound realm-wide safely, but MCP clients must have the `mcp-default` scope assigned (default or optional) for the picker to fire.

Documentation swept (concepts, decisions ADR-009, history, status log, changelog), committed, and a new image built + pushed for the user to redeploy after finishing realm configuration.

---

## Session: 2026-07-03 — Reconcile SPI with post-July-1 spec updates

The user asked to double-check all SPI-spec updates since the July-1 implementation and map required changes. Findings:

- **`keycloak.spi.mcp.md` §5.1** gained one change: a DETECTION-SIGNAL CAVEAT. The pseudocode is unchanged; the implementation still matches. The caveat warns that `mcp-default`-scope detection only holds while `mcp-default` is not a realm-default scope, and offers an escape hatch (a DCR-time `yourapp.mcp` client attribute) for anyone forced onto Option A.
- **Driving context (commit 1e67e13):** setup guide D.8 reversed the flow-binding recommendation from Option A to **Option B** after Option A took down all logins in testing (a malformed MCP flow bound realm-wide returns HTTP 400 for every login). PRD §17's new client taxonomy (mobile, browser plugins, user-context CLI) leans on the SPI short-circuit to pass non-MCP interactive clients through — matching the current code with no contract change.

**Conclusion: no SPI source change required.** Under the recommended Option B, `mcp-default` is never a realm default, so the current `isMcpClient` guard is correct and acts as a pure safety net.

**The required work was documentation drift from July 1** (all mine): `keycloak.web.mcp.md §7.2.1` still recommended Option A. Fixed it to recommend Option B and align with setup guide D.8. Recorded ADR-010 correcting ADR-009's "bound realm-wide safely" framing, updated the `McpTenantPickerAuthenticator` concept, added a CHANGELOG correction entry, and filed **TD-009** for the deferred `yourapp.mcp`-attribute hardening (YAGNI under Option B; revisit if Option A is ever adopted).

---

## Session: 2026-07-04 — Repository orientation summary

The user asked for a summary of the repository's purpose and the agent's role in it. Read `README.md`, `agentknowledge/{concepts,entities,decisions}.yaml`, `CONVERSATION.md`, recent `git log`, and the MCP SPI status document. No source code or behavior was changed.

Summary provided: this repo is the customized Keycloak 26.x identity broker for Outcrop Inc./YourApp web properties, with Java SPI code, themes/deployment scripts, Cloud Run configuration, and detailed specs for MCP/OAuth 2.1/DCR support. The agent's role is to act as the repository's implementation and maintenance engineer, following the documented V-V-P-T-I-R-V-C/TDD workflow, preserving the knowledge base and conversation history, keeping specs/docs synchronized, and making small, verified, committed changes when implementation work is requested.

Correction from user: `CODEX.md` contains a critical role override. The primary role in this repository is red-team security lead for the Keycloak IdP: analyze repository, implementation, setup, and runtime for security issues, vulnerabilities, bypasses, DDoS exposure, patch/CVE posture, and write security reports for a separate coding agent to fix. Unless explicitly asked, do not modify existing code; review changes with the user and produce security findings/remediation reports instead.

### Red-team review follow-up

The user asked for a red-team analysis of everything done so far by the coding agent, including Keycloak setup instructions and whether any security credentials had been checked in. Produced `specs/security-red-team-report-2026-07-04.md`.

Key findings: no plaintext production secret values were found in tracked files or git-history pattern scans, but a local untracked `keycloak_neon.dump` PostgreSQL dump exists and is ignored but world-readable by file mode. The highest-risk issues are: Keycloak is pinned to 26.6.0 while upstream current is 26.6.4 with multiple security fixes; bootstrap admin env vars remain mounted in `cloudrun.yaml`; Cloud Run uses the default compute service account; DCR redirect-host/protocol-mapper hardening and WAF/rate limiting remain deferred; setup docs still contain contradictory `mcp-default` realm-default checklist text; the MCP SPI should add server-side picker-request/result correlation and scope validation before public MCP exposure; replay protection is per-JVM; and Dependabot only covers pip, not Docker/Maven.

No source implementation code was modified. The report is intended as a handoff artifact for a coding agent or operator to fix in priority order.

### Secret scanner and GitHub security automation follow-up

The user approved installing Gitleaks and TruffleHog and asked for a full local secret scan first, plus GitHub repository security-tool configuration where available. Installed Gitleaks 8.30.1 and TruffleHog 3.95.8 under `/tmp/security-tools`. Reports were written under `/tmp/security-scan` and not committed.

Scan results: Gitleaks found 5 redacted findings in git history and 3 in the working tree, all reviewed as documentation/config-example false positives (`YOUR_ACCESS_TOKEN` Auth0 examples and a JDBC env-var example). TruffleHog found 0 verified and 0 unverified secrets in both git-history and working-tree scans. The sensitive local `keycloak_neon.dump` finding remains because dumps are sensitive even when scanners do not detect token-like strings.

GitHub repository changes: enabled Dependabot alerts and automated security fixes via GitHub API; GitHub secret scanning / push protection returned HTTP 422 ("Secret scanning is not available for this repository") for this repository. Updated `.github/dependabot.yml` to cover Docker, Maven, and GitHub Actions; added `.github/workflows/codeql.yml`; added `.github/workflows/dependency-review.yml`; rewrote `SECURITY.md` for the Keycloak IdP instead of the old UI-library scope. YAML parsed successfully with PyYAML and `git diff --check` passed.

Live GCP read-only check: active `gcloud` account is `operator@example.com`; configured project is `your-gcp-project-id`. A read-only `gcloud run services describe your-keycloak-service --region=your-region` succeeded and confirmed the latest service still has bootstrap admin env vars mounted and still uses the default compute service account.

---

## 2026-07-06 — MCP client registration policy (CRP): atomic bootstrapping at registration

**Request.** Production testing uncovered a circular dependency in how DCR'd MCP clients get their scopes and browser-flow binding. The SPI design, PRD, and setup guide were updated, plus a focused `specs/ERRATA-001-mcp-registration-crp.md`. The user asked me to review the changes (ERRATA first), discuss, make a plan, and only implement after review.

**Review & decisions.** Read ERRATA-001, SPI design §5.1 (updated short-circuit) + §5.8 (new CRP), web spec §7.5, setup guide D.2/D.7/D.8, and the current authenticator. Confirmed the core: a fresh DCR client has no `mcp-default` scope and no `browser-mcp-tenant-pick` binding, so its first authorization can't be detected as MCP (deadlock: binding was planned at `/mcp/consent`, which requires the binding to already exist). Fix: a new `McpClientRegistrationPolicy` CRP marks every MCP client atomically at registration. Raised concerns and got the user's calls: (1) all anonymous DCR = MCP (anonymous registration is the only signal); (2) scope lists + flow alias are ComponentModel config-driven; (3) scope = CRP + §5.1 update only (defer B1, no app change); (4) add a pointer note to web spec §7.5.

**Implementation (TDD).** Phase 0: verified every 26.6.0 model-API signature via `javap` against the pinned BOM jars — notably that `ClientRegistrationPolicyException extends RuntimeException` (so `afterRegister`, which declares no checked throws, can throw to roll back), and that the built-in `ClientScopesClientRegistrationPolicy` is an exact structural template. Also confirmed the documented `browser-mcp-tenant-pick` structure (D.2) is valid and 26.6.0-constraint-aware. Built `McpClientRegistrationPolicy` + factory + META-INF/services in a new `clientreg` package; `afterRegister` sets `yourapp.mcp=true`, assigns default + optional scopes, binds the browser flow, all in-transaction. Updated `McpTenantPickerAuthenticator.isMcpClient` to prefer the `yourapp.mcp` attribute and reworded the §5.1 short-circuit as a pure safety net (resolves TD-009). Tests: 15 CRP unit tests, 1 real-DCR testcontainers IT (drops the default Trusted Hosts anon policy, registers the CRP as anonymous, does anonymous DCR, asserts the client shape), 1 authenticator unit test. **129 unit + 2 IT green.**

**Docs/knowledge.** ADR-011; new `McpClientRegistrationPolicy` concept; history.jsonl line; CHANGELOG (Added + Changed); status-log row; web spec §7.5 interim pointer note; TD-009 marked Resolved. No `/mcp/consent`/app changes (ERRATA item #2 follow-on); B1 grant-types still deferred. Verification path handed to the user: deploy, register the CRP as an anonymous policy (D.8), re-run `smoke-mcp.sh` — a fresh DCR client should now be fully-marked without visiting `/mcp/consent`.

---

## 2026-07-06 — Picker-result correlation claims: the callback `client=null` fix (ERRATA-003)

**Request.** After the CRP work, the end-to-end MCP login worked except the final hop: the app posts the picker-result back to `/realms/yourapp-prod/mcp-picker-callback` and Keycloak returns 400 with the SPI logging `client=null not found`. The user asked me to find the fault (Keycloak vs app), check whether ERRATA-002 already covered it, and — per the desktop assistant's hand-off — consider re-architecting the resume around `getActionUrl`/`session_code`.

**Diagnosis.** Decoding the app's picker-result JWT showed it lacks `kc_client_id`/`kc_tab_id`/`auth_session_id`. The SPI callback recovers the suspended session + client from exactly those three signed claims (`getClientByClientId(token.getKcClientId())` → null → `client=null`). The picker-REQUEST already carries them and the app holds the request server-side (§2.1), so the correlation exists — the app just isn't echoing it. Root cause: **contract desync** — web spec §2.2/§3.3 defined the picker-result claim set without the `kc_*` claims (added SPI-side in Slice 4), so the app built to a stale spec. Told the user two things they asked about: ERRATA-001 (CRP) is fully implemented; ERRATA-002 is the app `/mcp/consent` split and does NOT cover this; and the "updated SPI spec §5.9 step 7" the desktop referenced never landed — the file still had the old §5.3 (jti-correlation + `AuthenticationProcessor`), which is what misled the diagnosis toward a resume rewrite.

**Decision.** Fix A (echo the claims), not the re-architecture: the correlation is already available and signed; the SPI already resumes via Keycloak's own action URL (`getLastExecutionUrl`). Documented as ERRATA-003 (user's naming).

**Implementation.** SPI: added a `missing_correlation` guard (distinct from `client_not_found`) with a spec-pointing WARN + `isBlank` helper + marker note in `McpPickerCallbackResourceProvider`; TDD unit test signs the app's exact correlation-less claim set and asserts `missing_correlation` (18 provider tests green). Specs: ERRATA-003; web spec §2.2 step 5 + §3.3 now require the three echoed claims, sourced from the **server-held** picker-request (not the client POST body — a session-fixation guard I flagged); reconciled the stale SPI §5.3 to the real design. Docs: ADR-012, CHANGELOG (Fixed), history, status row. **The app-side echo in YourAppApi (separate repo) is the remaining change that actually clears the 400** — I can't make it from this repo.

---

## 2026-07-07 — The `/mcp/consent` redirect loop: authenticator re-entrancy (ERRATA-004) + broker-path finding (TD-010)

**Request.** After deploying the ERRATA-003 + CRP work, the user re-ran `smoke-mcp.sh` and `/mcp/consent` was never hit; then found an infinite redirect between `/mcp/consent` and Keycloak. Asked me to diagnose.

**Two distinct problems surfaced.** (1) A **regression** where a fresh (Google broker) login skips the picker entirely, and (2) a **redirect loop** once the picker *does* fire.

**Problem 1 (broker path).** Server log: the CRP fully marks the client (`Marked MCP client at registration … attribute + 6 default / 1 optional scopes + browser flow`), yet the login goes Google → `OAUTH_GRANT` → token with **no** `Emitting MCP picker request` — `authenticate()` never ran after the broker round-trip. The user's Cookie-path experiment (existing session, no broker redirect) **did** fire the picker and reach `/mcp/consent`, proving the flow structure is correct. By elimination: the **per-client browser-flow override the CRP sets is lost on the post-broker resume** — Keycloak resumes on the realm default (`browser-federated-only`, no picker). Recorded as **TD-010**; recommended fix is Option A (bind the flow realm-wide, rely on the now attribute-based `isMcpClient` short-circuit). Also hardened `smoke-mcp.sh` to reclaim a stale loopback listener (`Errno 98 Address already in use`) and added read-only `diag-mcp-flow.sh`. **Not yet fixed** — pending the user's decision + diag output.

**Problem 2 (the loop, ERRATA-004).** From the HAR: `POST consent/authorize` → `mcp-picker-callback` **303** (the ERRATA-003 echo working — callback now resumes instead of 400-ing) → `login-actions/authenticate` **303** → `/mcp/consent?token=<fresh picker-REQUEST>` → repeat. The apps team's independent diagnosis matched mine: Keycloak resumes a challenged execution via **`authenticate()`**, not `action()` (the resume rides `getLastExecutionUrl`, a redirect, not a form POST to the action URL), and `McpTenantPickerAuthenticator.authenticate()` was not re-entrant — it re-issued a fresh picker-request every time.

**Fix (ERRATA-004).** Made `authenticate()` re-entrant: it opens with a resume guard reading a new auth note `yourapp.mcp.picker.completed`, written by `McpPickerCallbackResourceProvider.writeSessionNotes` alongside the tenant/scope notes → `context.success()` and finish. Chose an **explicit** marker over the apps team's "is `yourapp_tenant_id` set?" because the validator's Jackson path bypasses the builder's `requireString`, so a signed-but-malformed null-tenant result could still loop. Shared public constant `AUTH_NOTE_PICKER_COMPLETED` (callback references it) prevents writer/reader drift. **No app-side change** — the loop was evidence ERRATA-003 works. TDD: 3 new unit tests (authenticator finishes-without-challenge / still-challenges-without-note; callback sets the marker); **133 unit + 2 IT green.** Docs: ERRATA-004, ADR-013, insight 1.5, concepts.yaml (both picker concepts), CHANGELOG (Fixed), status row, history. TD-010 for the still-open broker path.

---

## 2026-07-07 (cont.) — CRP scope promotion + built-in-consent suppression (ERRATA-006)

**Request.** After deploying ERRATA-004, `smoke-mcp.sh` finally completed (tenant stamped, `aud` correct, no loop) but reported one FAIL — the client's default scopes were missing `mcp-default` + the author bundle — and the user also noticed Keycloak's built-in consent screen still appearing on the post-back, after the yourapp wizard.

**Diagnosis 1 (scopes).** `yourapp:admin` (optional) was placed correctly while every scope the client *requested* (`mcp-default` + author bundle) was missing from defaults though effective (`aud` correct). That asymmetry pinned it: Keycloak's OIDC DCR pre-binds the request's `scope` values as OPTIONAL client scopes before the CRP runs, and `ClientModel.addClientScope` is a no-op when a binding already exists, so the CRP never promoted them to default. Fix: `assignScopes` now does `removeClientScope` then `addClientScope(scope, asDefault)`. Discovered the IT never caught this because its DCR sent no `scope` field — so I made the IT send `scope` (reproducing prod). That surfaced a 403 from the default "Allowed Client Scopes" anonymous policy, so the IT now clears all pre-existing registration policies before the scoped DCR.

**Diagnosis 2 (consent).** `consentRequired=true` from the mcp-hardening `consent-required` client-policy executor → Keycloak's `OAUTH_GRANT` screen double-ups the yourapp wizard. User chose: CRP sets `consentRequired=false`. Verified it wins by decompiling `AbstractClientRegistrationProvider` (26.6.0): `triggerOnEvent` (executors) at bytecode offset 228 runs before `triggerAfterRegister` (CRP) at 237, so the CRP is the last writer.

**Implementation.** `McpClientRegistrationPolicy.afterRegister`: remove-then-add scope placement + `setConsentRequired(false)`. Verified `removeClientScope` + `setConsentRequired` in 26.6.0 via javap. TDD: 2 new unit tests (promotion removes-before-adds; consent suppressed) + tightened no-op test; IT now asserts default-scope placement + `consentRequired=false` end-to-end. 135 unit + 2 IT green. Docs: ERRATA-006, ADR-014, insight 1.6, concepts.yaml, spec §5.8, setup guide §D.6a note, CHANGELOG, status, history. **Still open: TD-010** (broker-path per-client browser-flow override lost after the IdP round-trip — the fresh-login path).

---

## 2026-07-07 (cont.) — ERRATA-005 spike: fresh-session tenant picker via Post Broker Login Flow

**Request.** Implement ERRATA-005 (the fresh/cookieless login gap). User asked me to work through the 5 open questions via SDK spikes, settle a solution, and report whether anything is needed app-side.

**Spike (26.6.0 SDK, by decompiling `LoginActionsService`, `AuthenticationProcessor`, `AuthenticationFlowURLHelper`, `IdentityBrokerService`).** Resolved all five:
1. Authenticator runs unmodified in post-broker — brokered login keeps ONE auth session keyed by (root, client, tab); `postBrokerLoginGet/Post` recover it by clientId+tabId → client/user/re-entrancy-note all resolve. The ERRATA-004 loop does NOT reappear on the IdP path (same session ⇒ same note).
2. Client available + `isMcpClient` load-bearing there (per-IdP flow shared with web logins; no-ops non-MCP).
3. Suspend/resume works: `getLastExecutionUrl` is flow-path-agnostic — rebuilds from `current.flow.path`, which `brokerLoginFlow`→`setFlowPath("post-broker-login")` sets. Callback unchanged.
4. One shared `post-broker-mcp-tenant-pick` flow, bound as Post login flow on Google + Microsoft.
5. Runs after `first-broker-login-no-prompt`, no conflict, every brokered login.

**Conclusion — CONFIG-ONLY.** No change to `McpTenantPickerAuthenticator` logic or `McpPickerCallbackResourceProvider`; **no app-side change** (picker-request/result contract + correlation claims + fixed `/mcp-picker-callback` URL are identical regardless of hosting flow). Code touch was documentation-only: §5.1 guard reclassified safety-net(browser)/load-bearing(post-broker) in the comment, factory help text + marker note both flows. Emphasized the per-execution `yourapp.web.host` gotcha.

**Deliverables.** ERRATA-005 spike write-up + status flip; SPI §5.1; setup guide new **D.2a** (create the flow + bind per-IdP + cookieless acceptance test); ADR-015; CHANGELOG/status/history/concepts/insight (1.7). Rejected a RequiredActionProvider alternative (one hook both paths) — would force changing the callback resume mechanism, larger/riskier than reusing the working authenticator. TD-010 is now resolved-by-ERRATA-005. 135 unit + 2 IT green (doc-only code touch). **App team: nothing to do.**

---

## 2026-07-08 — ERRATA-007, consent config correction, and B1 grant-type guard

**Request.** Continue production MCP debugging after the post-broker picker started firing but the fresh-session flow still did not complete.

**Diagnosis.** Keycloak/SPI was confirmed to be reaching `prod.yourapp.com/mcp/consent?token=...` with a valid picker-request JWT. The remaining failure was app-side: `/mcp/consent` was gated on a YourApp web app session instead of the signed handoff token, causing a second login, losing the return URL, and never posting back to `mcp-picker-callback`. Captured as **ERRATA-007**; fix belongs in YourAppApi.

**Consent correction.** `smoke-mcp.sh` proved `consentRequired=true` still persisted on the DCR client. The earlier CRP override did not win against the `mcp-hardening` `consent-required` executor because that executor re-applies the representation after CRP `afterRegister`. Correct fix: remove the `consent-required` executor and CRP from the MCP hardening config. Dropping Keycloak's generic consent does not weaken enforcement because the tenant picker and YourApp wizard are flow-gated.

**B1 implementation.** Folded allowed-grant-types enforcement into `McpClientRegistrationPolicy.beforeRegister` and `beforeUpdate` (ADR-017). DCR clients enabling password/ROPC, implicit, client_credentials, device authorization, or CIBA are rejected with 400. TDD: 7 unit tests plus a real-DCR integration test; 142 unit + 3 IT green. Keycloak/SPI side is complete including grant-type hardening. Remaining launch blocker: ERRATA-007 in YourAppApi plus applying the `consent-required` config removal in the environment.

---

## 2026-07-09 — Continue prior conversation: documentation state sync

**Request.** "continue the prior conversation"

**Action.** Rehydrated repo context from README, agentknowledge, git log, status docs, and conversation history. The working tree was clean at commit `f0bff50` (`feat: B1 AllowedGrantTypes — reject non-auth-code grants at DCR registration`). No unfinished Java or shell change remained in this repo; the live blocker remains ERRATA-007 in the app repo.

**Docs fixed.** Synchronized the stale in-repo handoff docs that still described B1 or the CRP as pending: `specs/keycloak-tech-debt.md`, `specs/ERRATA-001-mcp-registration-crp.md`, `specs/ERRATA-006-crp-scope-promotion-and-consent.md`, and SPI design §13a now agree that CRP bootstrap and B1 are shipped, consent suppression requires config removal of `consent-required`, and the active product blocker is app-side token-authenticated `/mcp/consent`.

---

## 2026-07-11 — Red-team closeout: RT-010 distributed replay + RT-004/RT-005 regression tests

**Request.** (1) Finish RT-010 — replace the custom in-memory `ReplayCache` with Keycloak's distributed `SingleUseObjectProvider` — and commit/push. (2) After confirming RT-004 is deployed (prod Cloud Run now runs on the dedicated `keycloak-runner` service account), "add a test for that as well as the negative test" — i.e. a smoke test for the dedicated runtime SA (RT-004) and the RT-005 attacker-domain redirect rejection. (3) Explain the `KC-SERVICES0047` internal-SPI startup warnings.

**RT-010 (ADR-019).** Deleted `ReplayCache.java` + `ReplayCacheTest.java`. Introduced `ReplayGuard` — a `@FunctionalInterface (jti, lifespanSeconds) -> boolean` (true = first use, false = replay). `HandoffTokenValidator.validatePickerResult` now takes a per-call `ReplayGuard`; the callback supplies `(jti, ttl) -> session.singleUseObjects().putIfAbsent("mcp.picker.result." + jti, ttl)`, keyed by the token's remaining time-to-`exp` so entries self-expire. Backing store is Infinispan-backed (cluster-wide) and restart-durable, so **`maxScale=1` is no longer a security invariant** for replay protection. API verified via `javap` against the 26.6.4 JARs before depending on it. TDD: validator + callback suites migrated to an in-memory `ReplayGuard` / mocked `SingleUseObjectProvider`. **147 unit + 3 IT green.** Committed `79e1809`.

**RT-004 / RT-005 tests.** `smoke.sh` **Test 31** (prod-only, gcloud-gated): reads `spec.template.spec.serviceAccountName` and fails if it ends `-compute@developer.gserviceaccount.com` **or is empty** (empty = Cloud Run falls back to the default compute SA), passes on the dedicated `keycloak-runner@…` SA. **Test 32** (RT-005): registers via anonymous DCR with an **HTTPS** untrusted-host redirect URI — HTTPS deliberately, so a pass proves host-level Trusted-Hosts enforcement is live (not merely the http-scheme rule that Test 22 already covers); expects 400/403, cleans up + fails on an accidental 201. Committed `a161179`. Red-team report: RT-004 → Fixed (cites Test 31), RT-005 cites Test 32, "**Remaining = none — all 14 findings closed**".

**KC-SERVICES0047.** Explained as benign: Keycloak flags four SPIs (`realm-restapi-extension`, `protocol-mapper`, `authenticator`, `client-registration-policy`) as "internal … may change without notice" whenever a third-party (`io.yourapp.*`) provider binds them. Expected for our SPIs; no action.

**Closeout (this session).** Reconciled the remaining housekeeping artifacts to the RT-010 file swap: `TECH_DEBT.md` TD-006 (drop the deleted `ReplayCache` from the concept-gap list, note the `ReplayGuard` seam), `specs/keycloak.spi.mcp.status.md` (current-status header refreshed to 147/3 + a superseded-content banner mapping `ReplayCache` → `ReplayGuard`/`SingleUseObjectProvider`), and this log. Confirmed `ReplayGuard.java` carries the copyright/SPDX header + full marker block. Open thread (not yet accepted by the user): triage the 3 moderate Dependabot alerts on `main`.

---

## 2026-07-11 (cont.) — Post-remediation endpoint hardening instructions

**Request.** After the live exploratory scan, the user clarified: ignore the stale checked-in `cloudrun.yaml` because they will redownload it and keep it as a repave reference; fix the documentation/knowledge drift; and for the public admin/master exposure plus permissive CORS findings, write detailed setup instructions into `specs/keycloak-security-hardening.md` or `specs/keycloak-setup-guide.md`.

**Action.** Left `cloudrun.yaml` untouched. Added `specs/keycloak-security-hardening.md`, a dedicated operator runbook for protecting `https://auth.yourapp.com/admin/*` and `/realms/master/*` with Cloudflare Access or equivalent WAF rules, reviewing Keycloak Web Origins, and validating CORS behavior without breaking the public `yourapp-prod` OIDC endpoints. Linked it from setup guide A.11 and the infrastructure checklist so a future repave does not miss the edge policy.

**Drift fixed.** Corrected active knowledge/docs that still implied the CRP's `setConsentRequired(false)` overrides `consent-required`: `agentknowledge/concepts.yaml`, `AGENT_INSIGHTS.md`, SPI design pseudocode, and the `McpClientRegistrationPolicy` marker/log wording now say the setter is only belt-and-suspenders and the authoritative fix is removing the `consent-required` executor/CRP from MCP DCR configuration. The `McpClientRegistrationPolicy` concept now also reflects shipped `beforeRegister`/`beforeUpdate` grant-type rejection. Updated the red-team report so RT-001 through RT-014 remain closed, while the new exploratory items EX-001 (admin/master edge protection) and EX-002 (CORS/browser-origin hardening) are tracked as operator-action pending rather than hidden behind "remaining none." Updated the changelog accordingly.

### Follow-up: make the hardening guide operator-grade and support Cloudflare Access in smoke

**Request.** The user reviewed `specs/keycloak-security-hardening.md` and found it too vague for a non-security-expert operator. They asked for setup-guide-level explicitness. They also clarified that `cloudrun.yaml` may be committed in this round because it now contains the live `keycloak-runner` runtime service account, and asked whether `smoke.sh` should consume a Cloudflare Access service token so tests still run once `/admin/*` is protected.

**Action.** Rewrote the hardening guide into a step-by-step runbook: exact Cloudflare application type (Self-hosted public application, not SaaS), exact app names, host/path fields, allow policies, service-token policy, what not to protect, validation commands, Keycloak Web Origins values, and rollback. Updated `smoke.sh` to accept `CF_ACCESS_CLIENT_ID`/`CF_ACCESS_CLIENT_SECRET` (plus longer `CLOUDFLARE_ACCESS_*` aliases), fail fast if only one is set, and inject `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers through a curl wrapper without printing the secret. Included the refreshed `cloudrun.yaml` showing the `keycloak-runner@your-gcp-project-id.iam.gserviceaccount.com` service account.

### Correction: Cloudflare UI and solo-owner authentication model

**Request.** The user rejected the previous guide as still not good enough: the Cloudflare UI labels were wrong/stale, the authentication explanation was poor, and the guide was not written for the actual situation of a solo developer with one Cloudflare account and one Keycloak admin account.

**Action.** Rewrote `specs/keycloak-security-hardening.md` around the current Cloudflare Access flow and the solo-owner model. The guide now says to create **Zero Trust -> Access controls -> Applications -> Create new application -> Self-hosted and private -> Add public hostname** applications, explicitly not SaaS. It recommends One-time PIN as the first-pass outer gate for a solo developer, while keeping Keycloak admin login and Keycloak TOTP enabled as the inner controls. It now uses exact path entries (`admin/*`, `admin`, `realms/master/*`, `realms/master`), explains why parent and wildcard paths are both listed, documents the human allow policy and smoke-test Service Auth policy, gives Secret Manager commands for the service token, and includes concrete browser/curl verification and rollback steps.

---

## 2026-07-12 — Open-source template cleanup

**Request.** Prepare this repository for public release by removing product-specific endpoint names and production deployment metadata from the current tree and history. Scan scripts, tests, and config for inadvertent secret or endpoint references, remove stale branches so only `main` remains, and keep `Outcrop Inc` copyright/licensing references intact.

**Action.** Genericized product-specific hostnames, realm names, package names, resource names, and deployment identifiers. Converted `cloudrun.yaml` from a live Cloud Run export into a reusable template, placeholderized live GCP project/region/service coordinates, generated Cloud Run URLs, operator email, Postgres host/user, and Secret Manager resource names. Kept `Outcrop Inc` copyright/licensing references intact. Pruned local stale branches and matching remote-tracking refs, leaving `main` as the only local branch.
