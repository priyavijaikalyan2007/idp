<!-- AGENT: Structured backlog of infrastructure / architecture items deliberately deferred. Each entry has enough context for a future engineer to pick up and implement without archaeology. -->

# Technical Debt Register — YourApp Keycloak IdP

**Format:** Each item carries an ID, status, current behaviour, what's deferred, and a concrete implementation plan. Triage on cadence: at the start of any sizeable change in the same area, re-check whether the debt has become blocking.

---

## TD-001: Full OAuth-flow Testcontainers IT

**Status:** Deferred
**Priority:** Low
**Created:** 2026-06-08
**Current location:** `src/providers/src/test/java/io/yourapp/keycloak/mcp/integration/McpSpiLoadingIT.java`

### What we have now

A single-test IT that boots Keycloak 26.6.0 in a container with the SPI JAR mounted via `withProviderLibsFrom`, hits `GET /realms/master/mcp-picker-callback`, and asserts a `400 missing_token` JSON response. This proves the JAR loads, META-INF/services files register, and the resource provider mounts at the expected URL path. ~ 39 s runtime per IT (Keycloak startup is the bulk).

### Why this is debt

The IT doesn't exercise:

- The Authenticator's flow-suspend path (would need an OAuth authorization-code request, federation IdP redirect mock, browser cookie handling).
- The picker_request → YourApp web → picker_result round-trip (would need an embedded HTTP server impersonating YourApp web's `/mcp/consent`).
- Tab-id preservation across the cross-process redirect.
- The resume of the suspended flow (verify `getLastExecutionUrl` actually re-enters the Authenticator).
- Token-issuance verification (decode the final access token, assert `scope` and `tenant` claims match the embedded mock's chosen values).

### Why deferred

The 100+ unit tests cover every individual handler code path with deterministic mocks. The added confidence from a full browser-flow IT is real but marginal vs. the cost: standing up an embedded HTTP server, managing `JSESSIONID` / `AUTH_SESSION_ID` cookie jar, scripting form POSTs through Keycloak's federation step. Production smoke tests (`./smoke.sh`) against a deployed Keycloak cover the integration paths the unit + minimal IT layers miss.

### Implementation plan

1. Author `src/providers/src/test/resources/test-realm.json` with realm `yourapp-test-it`, a confidential client `mcp-test-client`, the `browser-mcp-tenant-pick` flow including the SPI Authenticator step with `yourapp.web.host=localhost:8090` configured, and the `mcp-default` Client Scope with the McpScopeOverrideMapper attached.
2. Spin up a tiny embedded HTTP server inside the IT (`com.sun.net.httpserver.HttpServer` is stdlib; ~ 50 lines) on port 8090 that: receives the picker_request token, validates it against a shared test HMAC key, constructs a valid picker_result echoing `kc_client_id`/`kc_tab_id`/`auth_session_id`, signs it, and 302s the browser to `/realms/yourapp-test-it/mcp-picker-callback?picker_result=...`.
3. Drive the flow with `RestAssured` configured with a shared cookie jar.
4. Verify the final access token has `tenant == "test-tenant-uuid"` and `scope == "yourapp:read"`.

Estimated effort: ~ 6 hours (most of it is the cookie/redirect plumbing, not the SPI code).

### Triggers to revisit

- Keycloak base image upgrade that might affect the suspend/resume API.
- Any change to `McpPickerCallbackResourceProvider.findAuthSession()` logic.
- Real production incident that the current test stack failed to catch.

---

## TD-002: YourApp web `/mcp/consent` companion implementation

**Status:** Not started (dependency)
**Priority:** High (blocks MCP launch)
**Created:** 2026-06-08
**Current location:** YourApp web repo (separate)

### What we have now

The Keycloak SPI side of the picker handoff is complete and tested. The complementary `/mcp/consent` endpoint on YourApp web does not yet exist. Until it does, the SPI's `McpTenantPickerAuthenticator` will redirect to `https://<yourapp.web.host>/mcp/consent?token=...` and the browser will land on a 404.

### Implementation plan

Specified in `specs/keycloak.web.mcp.md`. Key points the YourApp web team needs from the Keycloak SPI side (already locked in):

- Verify the picker_request JWT against the realm's HMAC key (`YOURAPP_MCP_HANDOFF_HMAC_KEY__<R>`).
- The picker_result JWT MUST echo `kc_client_id`, `kc_tab_id`, `auth_session_id`, `user_sub_echo`, `picker_request_jti` exactly as received.
- Sign the picker_result with the same HMAC key (1-min TTL).
- 302 to `https://<keycloak-host>/realms/{realm}/mcp-picker-callback?picker_result=<signed-jwt>`.

### Triggers to revisit

- This is the MCP launch blocker; track in the YourApp web roadmap.

---

## TD-003: `KC_BOOTSTRAP_ADMIN_PASSWORD` may have been silently dropped

**Status:** Resolved 2026-06-10
**Priority:** Medium
**Created:** 2026-06-09
**Current location:** `cloudrun.yaml`

### Resolution

The 2026-06-10 deploys (revisions through `yourappauth-00020`) ran with the corrected
binding (`KC_BOOTSTRAP_ADMIN_PASSWORD` from Secret Manager `yourapp-keycloak-bootstrap-password`)
and the operator logged into the admin console and switched realms during incident
debugging — admin authentication works on the fixed configuration. Note the admin
*user* predates the fix (bootstrap only creates the user when absent), so the binding
fix mattered for clean-database scenarios, which is now the verified-good path.

### What we have now

Until this session, `cloudrun.yaml` had `- name: KC_BOOTSTRAP_ADMIN_PASSWORD=` (trailing `=`), an invalid env-var name. Cloud Run almost certainly silently dropped this entry, meaning the bootstrap admin password may have never been set via this binding. The fix is in place; the typo is removed. But it's unclear whether production has been relying on a different admin-credential mechanism (manual realm import? a pre-existing admin from initial setup?) and what happens on the next clean deploy.

### Action required

On the next deploy after merging:
1. Watch the Keycloak container logs at startup for any `KC_BOOTSTRAP_ADMIN_PASSWORD` related messages.
2. Attempt admin login at https://auth.yourapp.com/admin with the credentials in `yourapp-keycloak-bootstrap-password` Secret Manager entry.
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

The Dockerfile's `COPY ./target/themes/ /opt/keycloak/themes/` and build.sh's `mkdir -p ./target/themes` exist but produce/consume an empty directory. The Keycloakify theme is parked per PRD §15 because the MCP consent UX runs in YourApp web — Keycloak's login screens are seen only briefly in the federated-only flow.

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

---

## TD-007: Pin the Keycloak base image by SHA digest

**Status:** Deferred
**Priority:** Medium
**Created:** 2026-06-10
**Current location:** `Dockerfile` (`FROM quay.io/keycloak/keycloak:26.6.0`)

### What we have now

Both Dockerfile stages pull `quay.io/keycloak/keycloak:26.6.0` by tag. Quay tags are
mutable: a re-published `26.6.0` would silently change the base under us between
builds, and the two `FROM` lines could in principle even resolve differently if a
re-publish landed mid-build. During the 2026-06-10 incident this ambiguity cost real
diagnostic time — "did the base drift?" had to be ruled out empirically instead of
being impossible by construction.

### Implementation plan

1. `docker buildx imagetools inspect quay.io/keycloak/keycloak:26.6.0` → record the
   manifest-list digest.
2. Change both `FROM` lines to `quay.io/keycloak/keycloak:26.6.0@sha256:<digest>`
   (keep the tag for human readability; the digest is what pins).
3. Document the digest-refresh step in the upgrade runbook: bumping Keycloak =
   update tag + digest together, one commit.

Estimated effort: 15 minutes.

### Triggers to revisit

- Next Keycloak version bump (do it as part of that change).
- Any future "image content changed without a commit" suspicion.

---

## TD-008: `run.sh` cannot reproduce optimized-image behaviour

**Status:** Deferred
**Priority:** Medium
**Created:** 2026-06-10
**Current location:** `run.sh`

### What we have now

`run.sh` starts the locally-built image with `--entrypoint /opt/keycloak/bin/kc.sh ... start-dev`.
`start-dev` re-augments the Quarkus application at startup, bypassing everything
`kc.sh build` baked into the image. That is convenient for theme/SPI iteration but
means the local runner exercises a *different* application than production runs —
optimized-augmentation defects are invisible to it (see AGENT_INSIGHTS.md §5.4).

### Implementation plan

Add a `--prod` flag to `run.sh` that drops the entrypoint override and runs the
image's own `ENTRYPOINT` (`start --optimized`) with the same env contract Cloud Run
supplies (`KC_DB=postgres`, sidecar URL, hostname flags). The incident-reproduction
recipe used on 2026-06-10 (vanilla image initialises the schema, suspect image runs
optimized against it) can live in a comment block in the script.

Estimated effort: ~30 minutes.

### Triggers to revisit

- Next production incident suspected to be image-related.
- Any change to the Dockerfile build stage or `kc.sh build` flags.

---

## TD-009: MCP-client detection has no signal robust to realm-default scoping

**Status:** Resolved (2026-07-06, ADR-011)
**Priority:** Low (Medium if Option A is ever adopted)
**Created:** 2026-07-03
**Current location:** `src/providers/src/main/java/io/yourapp/keycloak/mcp/authenticator/McpTenantPickerAuthenticator.java` (`isMcpClient`)

> **Resolution (2026-07-06).** Implemented as part of ADR-011. `isMcpClient` now
> **prefers** the `yourapp.mcp="true"` attribute (checked first), falling back to
> `mcp-default` scope presence — exactly the hardening sketched below. The attribute
> is set **by `McpClientRegistrationPolicy` atomically at registration** (not by the
> app, as the original plan assumed), so it exists before the client's first
> authorization. 1 new unit test (`authenticate_mcpAttributeSet_proceedsEvenWithoutScope`).
> The remainder of this entry is retained for historical context.

### What we have now

The short-circuit guard identifies an MCP client by the presence of the
`mcp-default` client scope (default or optional). This is correct **only while
`mcp-default` is not a realm-default scope** — i.e. under the recommended
per-client binding (setup guide D.8 Option B). The detection signal and the
thing that can be handed out realm-wide are the same object (`mcp-default`), so
the guard is one misconfiguration away from breaking: assign `mcp-default` as a
realm default and every client — including `yourapp-{env}-web` — is seen as an
MCP client and pushed into the consent wizard.

### Why deferred

Under Option B (the recommended and current path) the scope signal is correct
and the guard is a pure safety net, so nothing is broken. The hardening only
earns its keep if someone adopts Option A (realm-wide flow binding) or wants
defence-in-depth against the realm-default footgun. Adding it now is YAGNI.

### Implementation plan

Add a dedicated detection signal the web client cannot accidentally acquire — a
DCR-time client attribute — and OR it into the guard (non-breaking):

```java
return client.getClientScopes(true).containsKey(MCP_CLIENT_SCOPE)
        || client.getClientScopes(false).containsKey(MCP_CLIENT_SCOPE)
        || "true".equals(client.getAttribute("yourapp.mcp"));
```

`ClientModel.getAttribute(String)` is verified present in 26.6.0. YourApp web
sets `yourapp.mcp = "true"` on each DCR'd MCP client during post-registration
processing (the same step that assigns scopes / binds the flow). Add unit tests
mirroring the scope cases (attribute present → MCP; absent → passthrough). See
SPI design §5.1 DETECTION-SIGNAL CAVEAT and ADR-010.

### Triggers to revisit

- A decision to adopt Option A (realm-wide binding).
- Any incident where a non-MCP client is misrouted into the MCP consent flow.
- Introduction of client types (PRD §17: mobile, browser plugins) where the
  scope-only signal proves insufficient.

---

## TD-010: Per-client browser-flow override is not honored after the IdP broker round-trip

**Status:** Open (diagnosed, fix pending a decision)
**Priority:** High — blocks MCP consent on the *primary* login path (fresh federated login)
**Created:** 2026-07-07
**Current location:** interaction between `McpClientRegistrationPolicy.bindBrowserFlow` (per-client override) and the realm's default browser flow; `src/providers/src/main/java/io/yourapp/keycloak/mcp/authenticator/McpTenantPickerAuthenticator.java`

### Symptom

A freshly DCR'd, correctly-marked MCP client (CRP log confirms `yourapp.mcp` + scopes + browser-flow override) logs in via the Google IdP and goes **Google → Keycloak `OAUTH_GRANT` → token**, never hitting `/mcp/consent`. The server log shows **no** `Emitting MCP picker request` line — `authenticate()` never ran after the broker round-trip.

### Root cause (confirmed by elimination)

A **Cookie-path** login (existing Keycloak session, no broker redirect) **does** fire the picker and reach `/mcp/consent`. So the `browser-mcp-tenant-pick` flow is structurally correct (the picker is REQUIRED and reachable). The only difference on the failing path is the **Identity Provider Redirector round-trip**. Conclusion: the **per-client** browser-flow override the CRP sets is dropped when Keycloak resumes after the broker login — the post-broker resume runs the **realm default** browser flow (`browser-federated-only`, which has no picker). This is why the earlier deployments that bound the flow realm-wide (Option A) worked and the CRP's per-client binding (Option B) regressed the broker path.

### Fix options

1. **Recommended — Option A (realm-wide).** Bind `browser-mcp-tenant-pick` as the realm's **default** browser flow and rely on `McpTenantPickerAuthenticator`'s `isMcpClient` short-circuit (now **attribute-based**, TD-009/ADR-011, so `yourapp-{env}-web` is unaffected) to pass non-MCP clients through. Removes the per-client override entirely, so there is nothing to lose on resume. The two historical objections to Option A are now moot: the flow structure is proven correct (Cookie path works), and detection no longer depends on `mcp-default` being off the realm defaults. If adopted, drop `bindBrowserFlow` from the CRP (or keep it as belt-and-suspenders — harmless but redundant).
2. **Keep Option B and re-apply the override post-broker.** Investigate whether a `postBrokerLoginFlow` or a custom step can re-assert the client override after `firstBrokerLogin`. More moving parts; not recommended.

### Next step before implementing

Run `./diag-mcp-flow.sh` (added 2026-07-07) to confirm the realm default browser flow is `browser-federated-only` and that the picker is `REQUIRED` at the top level of `browser-mcp-tenant-pick`. Then apply Option A and re-run `smoke-mcp.sh` (fresh login) — it should reach `/mcp/consent` and stamp the tenant.

### Triggers to revisit

- Any change to how MCP clients bind the browser flow.
- Adoption of `kc_idp_hint` / a non-broker first login path for MCP clients.

### Related

- ERRATA-004 (the resume loop) is a **separate** bug on the Cookie path — fixed. TD-010 is the broker path. Both must be green for end-to-end MCP login to work.
