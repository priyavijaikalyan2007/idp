<!-- AGENT: Structured backlog of infrastructure / architecture items deliberately deferred. Each entry has enough context for a future engineer to pick up and implement without archaeology. -->

# Technical Debt Register — Knobby Keycloak IdP

**Format:** Each item carries an ID, status, current behaviour, what's deferred, and a concrete implementation plan. Triage on cadence: at the start of any sizeable change in the same area, re-check whether the debt has become blocking.

---

## TD-001: Full OAuth-flow Testcontainers IT

**Status:** Deferred
**Priority:** Low
**Created:** 2026-06-08
**Current location:** `src/providers/src/test/java/io/knobby/keycloak/mcp/integration/McpSpiLoadingIT.java`

### What we have now

A single-test IT that boots Keycloak 26.6.0 in a container with the SPI JAR mounted via `withProviderLibsFrom`, hits `GET /realms/master/mcp-picker-callback`, and asserts a `400 missing_token` JSON response. This proves the JAR loads, META-INF/services files register, and the resource provider mounts at the expected URL path. ~ 39 s runtime per IT (Keycloak startup is the bulk).

### Why this is debt

The IT doesn't exercise:

- The Authenticator's flow-suspend path (would need an OAuth authorization-code request, federation IdP redirect mock, browser cookie handling).
- The picker_request → Knobby web → picker_result round-trip (would need an embedded HTTP server impersonating Knobby web's `/mcp/consent`).
- Tab-id preservation across the cross-process redirect.
- The resume of the suspended flow (verify `getLastExecutionUrl` actually re-enters the Authenticator).
- Token-issuance verification (decode the final access token, assert `scope` and `tenant` claims match the embedded mock's chosen values).

### Why deferred

The 100+ unit tests cover every individual handler code path with deterministic mocks. The added confidence from a full browser-flow IT is real but marginal vs. the cost: standing up an embedded HTTP server, managing `JSESSIONID` / `AUTH_SESSION_ID` cookie jar, scripting form POSTs through Keycloak's federation step. Production smoke tests (`./smoke.sh`) against a deployed Keycloak cover the integration paths the unit + minimal IT layers miss.

### Implementation plan

1. Author `src/providers/src/test/resources/test-realm.json` with realm `knobby-test-it`, a confidential client `mcp-test-client`, the `browser-mcp-tenant-pick` flow including the SPI Authenticator step with `knobby.web.host=localhost:8090` configured, and the `mcp-default` Client Scope with the McpScopeOverrideMapper attached.
2. Spin up a tiny embedded HTTP server inside the IT (`com.sun.net.httpserver.HttpServer` is stdlib; ~ 50 lines) on port 8090 that: receives the picker_request token, validates it against a shared test HMAC key, constructs a valid picker_result echoing `kc_client_id`/`kc_tab_id`/`auth_session_id`, signs it, and 302s the browser to `/realms/knobby-test-it/mcp-picker-callback?picker_result=...`.
3. Drive the flow with `RestAssured` configured with a shared cookie jar.
4. Verify the final access token has `tenant == "test-tenant-uuid"` and `scope == "knobby:read"`.

Estimated effort: ~ 6 hours (most of it is the cookie/redirect plumbing, not the SPI code).

### Triggers to revisit

- Keycloak base image upgrade that might affect the suspend/resume API.
- Any change to `McpPickerCallbackResourceProvider.findAuthSession()` logic.
- Real production incident that the current test stack failed to catch.

---

## TD-002: Knobby web `/mcp/consent` companion implementation

**Status:** Not started (dependency)
**Priority:** High (blocks MCP launch)
**Created:** 2026-06-08
**Current location:** Knobby web repo (separate)

### What we have now

The Keycloak SPI side of the picker handoff is complete and tested. The complementary `/mcp/consent` endpoint on Knobby web does not yet exist. Until it does, the SPI's `McpTenantPickerAuthenticator` will redirect to `https://<knobby.web.host>/mcp/consent?token=...` and the browser will land on a 404.

### Implementation plan

Specified in `specs/keycloak.web.mcp.md`. Key points the Knobby web team needs from the Keycloak SPI side (already locked in):

- Verify the picker_request JWT against the realm's HMAC key (`KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>`).
- The picker_result JWT MUST echo `kc_client_id`, `kc_tab_id`, `auth_session_id`, `user_sub_echo`, `picker_request_jti` exactly as received.
- Sign the picker_result with the same HMAC key (1-min TTL).
- 302 to `https://<keycloak-host>/realms/{realm}/mcp-picker-callback?picker_result=<signed-jwt>`.

### Triggers to revisit

- This is the MCP launch blocker; track in the Knobby web roadmap.

---

## TD-003: `KC_BOOTSTRAP_ADMIN_PASSWORD` may have been silently dropped

**Status:** Needs verification on next deploy
**Priority:** Medium
**Created:** 2026-06-09
**Current location:** `cloudrun.yaml`

### What we have now

Until this session, `cloudrun.yaml` had `- name: KC_BOOTSTRAP_ADMIN_PASSWORD=` (trailing `=`), an invalid env-var name. Cloud Run almost certainly silently dropped this entry, meaning the bootstrap admin password may have never been set via this binding. The fix is in place; the typo is removed. But it's unclear whether production has been relying on a different admin-credential mechanism (manual realm import? a pre-existing admin from initial setup?) and what happens on the next clean deploy.

### Action required

On the next deploy after merging:
1. Watch the Keycloak container logs at startup for any `KC_BOOTSTRAP_ADMIN_PASSWORD` related messages.
2. Attempt admin login at https://auth.knobby.io/admin with the credentials in `knobby-keycloak-bootstrap-password` Secret Manager entry.
3. If login works, debt is resolved. If not, investigate how admin was actually being authenticated and document.

### Triggers to revisit

- Next deploy after this commit lands in production.

---

## TD-004: Author-side script gaps already filled — none remaining

**Status:** Resolved
**Created:** 2026-06-09

### Context

AGENTS.md repository-structure section calls out these scripts: `build.sh`, `clean.sh`, `deploy.sh`, `logs.sh`, `monitor.sh`, `prune.sh`, `push.sh`, `run.sh`, `smoke.sh`, `test.sh`. All ten are now present in the repo root. Closed for now; track only if AGENTS.md adds new required scripts.

---

## TD-005: Theme JAR build path is wired but unused

**Status:** Deferred (parked feature)
**Priority:** Low
**Created:** 2026-06-09
**Current location:** `Dockerfile`, `build.sh`, `/target/themes/`

### What we have now

The Dockerfile's `COPY ./target/themes/ /opt/keycloak/themes/` and build.sh's `mkdir -p ./target/themes` exist but produce/consume an empty directory. The Keycloakify theme is parked per PRD §15 because the MCP consent UX runs in Knobby web — Keycloak's login screens are seen only briefly in the federated-only flow.

### Why deferred

Building a custom Keycloak theme is real work (Keycloakify tooling, Storybook for the login pages, brand styling). The current generic Keycloak login UI is fine for the small "click your IdP" interstitial users see in the federated flow. Revisit if the federated flow ever shows non-trivial Keycloak UI screens.

### Implementation plan

Documented in `specs/keycloak-themeing-guide.md`. Build pipeline:
1. Add `src/themes/` Keycloakify project.
2. `build.sh` runs `npm run build-keycloak-theme` and stages the resulting JAR to `/target/themes/`.
3. Dockerfile already picks it up.

### Triggers to revisit

- A product decision to brand the Keycloak login screens.
- Any user complaint about the unbranded Keycloak interstitial.

---

## TD-006: agentknowledge/concepts.yaml has gaps

**Status:** Deferred (low value)
**Priority:** Low
**Created:** 2026-06-09
**Current location:** `agentknowledge/concepts.yaml`

### What we have now

Five concepts catalogued (`McpTenantPickerFlow`, `McpHandoffJwt`, `HmacKeyRotation`, `McpScopeOverride`, `McpDefaultClientScope`, `McpSpiConfig`, `HandoffTokenValidator`, `McpTenantPickerAuthenticator`, `McpPickerCallbackResourceProvider`). Missing: `PickerRequestToken`/`PickerResultToken` POJOs, `ReplayCache`, the Authenticator/ResourceProvider factory classes, `HandoffTokenSigner`. The omissions are mostly small utility types that don't add much value to a concept lookup.

### Implementation plan

If the index becomes inadequate for a future search task, append the missing entries via the schema in `KNOWLEDGE_ARCHITECTURE.md` §2.2. Each entry is 5 lines of YAML.

### Triggers to revisit

- Future agent reports "couldn't find <class> via concepts.yaml".
