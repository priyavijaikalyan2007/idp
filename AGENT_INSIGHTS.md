<!-- AGENT: Accumulated engineering insights from coding sessions on this repository. Consult before implementation; append new insights after each session. -->

# Agent Insights — Knobby Keycloak IdP

Insights are hard-won lessons from real bugs, design dead-ends, API archaeology, and user-feedback corrections during work on this repository. Each insight captures a *principle* — not just what happened, but *why* it matters and *how* to apply it next time.

**For agents**: Read this at session start. Append new insights here when you hit a non-obvious wall and find a way through. Date entries.

---

## 1. Keycloak SPI integration

### 1.1 Verify Keycloak's JOSE/auth APIs against the JARs, not docs (2026-06-08)
Keycloak's published docs lag the source by 1–2 minor versions and the deprecation timeline of internal classes (`JWSBuilder.hmac256(byte[])`, `org.keycloak.jose.jws.Algorithm` enum, etc.) is not reliably called out anywhere except the JAR's `@Deprecated` annotations. Before committing to any signature/JOSE call, run `javap -p -classpath ~/.m2/repository/org/keycloak/...jar <FQCN>` to see the actual method set, then compile with `-Dmaven.compiler.showDeprecation=true` and replace anything that warns. The modern HMAC path in 26.6 is `JWSBuilder.sign(new MacSignatureSignerContext(KeyWrapper{secretKey, "HS256"}))`, not the public-API-looking `hmac256(byte[])`.

**Principle**: For an SPI compiled against a fast-moving host runtime, the JARs are the API contract. Treat docs as orientation, not specification.

### 1.2 OIDC `scope` is access-token-only; resist the spec's "implement three interfaces" pattern (2026-06-08)
The design spec said `McpScopeOverrideMapper` should implement `OIDCAccessTokenMapper + OIDCIDTokenMapper + UserInfoTokenMapper`. But `org.keycloak.representations.IDToken` has no `setScope` method — OIDC reserves the `scope` claim for access tokens (RFC 6749/OIDC core). Implementing the other two marker interfaces would be either a no-op or a hack via `otherClaims`. Trimmed the mapper to `OIDCAccessTokenMapper` only and documented the deviation in the class JavaDoc.

**Principle**: When a spec lists multiple integration points, sanity-check each against the underlying contract before mass-implementing. "Symmetric" interface sets often hide one-off semantics that justify only a subset.

### 1.3 Suspend/resume uses the auth-session breadcrumb Keycloak already writes (2026-06-08)
The Keycloak source-spike found a critical detail: when `context.challenge(Response)` runs on a REQUIRED execution, `DefaultAuthenticationFlow.processResult` auto-writes the auth-session note `AuthenticationProcessor.CURRENT_AUTHENTICATION_EXECUTION` = current execution id. The resume side doesn't need to track this — it just needs to redirect to `AuthenticationFlowURLHelper.getLastExecutionUrl(authSession)` which reads that note and rebuilds the URL. **Do not** construct an `AuthenticationProcessor` and call `authenticate()` from the callback — that re-runs the entire flow from the top.

**Principle**: Before re-implementing flow machinery, study how `IdentityBrokerService.afterFirstBrokerLogin()` (or the equivalent canonical handler) resumes. Keycloak frequently provides the right primitive one method call away.

### 1.4 Carry `client_id` + `tab_id` through every cross-process round-trip (2026-06-08)
`AuthenticationSessionManager.getCurrentAuthenticationSession(realm, client, tabId)` keys on `(rootAuthSessionId from cookie, client, tabId)` — losing tab_id makes the cookie alone insufficient. Always sign `kc_client_id` + `kc_tab_id` + `auth_session_id` into any JWT that traverses an external system and is expected to resume a Keycloak flow.

**Principle**: Auth sessions are not identified by cookie alone. Any handoff that comes back via a path that bypasses normal flow continuation must carry the routing tuple explicitly, HMAC-signed.

### 1.5 A challenge-based authenticator that suspends to external UI MUST be re-entrant (2026-07-07)
When the resume rides a redirect to `getLastExecutionUrl` (a GET), Keycloak re-enters the suspended execution through the authenticator's **`authenticate()`**, NOT `action()`. `action()` only runs for a form POST to the execution's action URL. So an authenticator that redirects out and expects to be "finished" on return is a **loop generator by construction** unless `authenticate()`'s FIRST move is a "has my out-of-band step already completed?" check that calls `context.success()` and returns. We hit this as ERRATA-004: the callback recorded consent and resumed, `authenticate()` re-issued a fresh picker-request, and the browser bounced `/mcp/consent` ⇄ Keycloak forever. The completion signal must be an **explicit** auth note (we used `knobby.mcp.picker.completed`), not an inference from a data note like "is the tenant set?" — the validator's Jackson deserialization bypasses the builder's `requireString`, so a malformed-but-signed result could carry a null tenant and still loop.

**Principle**: Model any suspend-to-external-UI authenticator as re-entrant on `authenticate()`. Its first branch is the resume guard (finish if already done); the challenge is the fallthrough. Note the completion with a dedicated boolean marker, and share the marker's key as one constant between the writer (callback) and reader (authenticator) so they cannot drift. (Companion to 1.3: 1.3 is how to resume; 1.5 is what the resumed step must check.)

### 1.6 DCR pre-binds requested scopes as optional; `addClientScope` won't promote them; know the registration order (2026-07-07)
Two coupled facts bit us in the same run (ERRATA-006). (a) Keycloak's OIDC Dynamic Client Registration maps the request's `scope` field to the new client's **optional** client scopes *before* any registration-policy `afterRegister` runs. (b) `ClientModel.addClientScope(scope, defaultScope)` is a **no-op when a binding already exists** — it does NOT update the default/optional flag. So a policy that "adds mcp-default as default" silently does nothing for any scope the client *requested*, leaving it optional. The fix is **remove-then-add** (`removeClientScope` then `addClientScope(scope, asDefault)`) so the policy's placement is authoritative. The diagnostic tell: a scope the client does NOT request (here `knobby:admin`) is placed correctly, while requested ones are stuck — that asymmetry points straight at pre-binding.

Relatedly, when two registration-time systems both mutate the client (the newer **Client Policies** executors and the older **Client Registration Policies**), the order is decidable, not a guess: read `AbstractClientRegistrationProvider`'s bytecode. In 26.6.0, `clientPolicy().triggerOnEvent(DynamicClientRegistered…)` runs **before** `ClientRegistrationPolicyManager.triggerAfterRegister(…)` (offsets 228 < 237), so a CRP `afterRegister` is the last writer and can authoritatively override an executor (e.g. set `consentRequired=false` after the `consent-required` executor set it true).

**Principle**: When a framework hook mutates state that an earlier hook already touched, verify the hook order against the actual dispatch code before assuming your write wins — and prefer set-then-verify APIs (remove-then-add) over add-if-absent ones when you need a specific end state.

---

## 2. Test harness

### 2.1 "Flip the last char of a JWS" is not a reliable tamper trick (2026-06-08)
The Slice 1 `validate_tamperedSignature_throwsBadSignature` test was passing for the wrong reason. HS256 produces a 256-bit signature → base64url-encodes to 43 chars where the last char encodes only 4 meaningful bits (256 % 6 = 4 used, 2 unused). Flipping `A` → `B` at the last position changes one of the **unused** bits and the decoded signature bytes are identical. The bug stayed latent until the picker_result payload grew (added `kc_*` fields) and the alignment shifted to expose it. Fix: tamper with the **first** char of the signature segment, which always changes a meaningful bit.

**Principle**: When testing failure detection, perturb input where you have a guarantee it changes the decoded value, not where you have an intuition. For base64-encoded fixed-size payloads, the boundary chars often have unused bits.

### 2.2 Provided-scope is the right answer for Keycloak runtime classes (2026-06-08)
Every `org.keycloak:*` dependency for an SPI should be `<scope>provided</scope>` — the runtime ships them, and bundling them in the SPI JAR causes class-loader confusion (duplicate classes, mismatched versions vs the runtime). The Maven Keycloak BOM (`org.keycloak.bom:keycloak-spi-bom`) handles version alignment for the public SPI artifacts; internal ones (`keycloak-server-spi-private`, `keycloak-services`) need explicit `<version>${keycloak.version}</version>` because the BOM doesn't manage them. Both work at provided scope.

**Principle**: Treat the host runtime's classpath as the contract. Use `provided` consistently. Bundle only your own code and small utilities the runtime doesn't ship.

### 2.3 Function-injection beats subclassing for testability when wrapping concrete Keycloak classes (2026-06-08)
`AuthenticationSessionManager` and `AuthenticationFlowURLHelper` are concrete classes constructed inside handler methods, which makes them hard to mock without subclassing the resource provider. Cleaner pattern: a private constructor parameter taking `Function<KeycloakSession, AuthenticationSessionManager>` plus a `@FunctionalInterface ResumeUrlBuilder`. Production wires the real instantiations; tests wire mocks/stubs. The public constructor is a one-line passthrough so callers aren't burdened.

**Principle**: For a class that uses concrete collaborators it can't avoid constructing, factor those constructions into single-method functional interfaces and inject them via a non-public constructor. Keeps the production API tight while making the seams visible to tests.

---

## 3. Build & tooling

### 3.1 Maven XML rejects supplementary-plane Unicode (2026-06-08)
The MARKERS.md emoji block (⚓ 📜 🔗 ⚡ 🛡️) is fine in Java source (javac handles UTF-8 surrogate pairs) but Maven's `KXmlParser` fails on supplementary-plane code points in XML comments. Use ASCII fallback tokens (`COMPONENT:`, `PURPOSE:`, etc.) in `pom.xml` and document the deviation inline. MARKERS.md doesn't list XML build files in its target formats, so the deviation is doctrinally clean.

**Principle**: Apply convention rules at file granularity. "All files do X" is rarely true; check the parser, not the rule.

### 3.2 JDK 21 + Mockito + Keycloak runtime has three JVM-noise sources, all fixable (2026-06-09)
Keycloak's `JBossLoggerFinder` complains the LogManager wasn't set; Mockito's byte-buddy agent triggers the dynamic-agent-loading warning; the JBoss LogManager being appended to bootstrap classpath triggers the CDS sharing warning. All three are silenced by a single Surefire/Failsafe `<argLine>`:
```
@{argLine} -Xshare:off -Djava.util.logging.manager=org.jboss.logmanager.LogManager -javaagent:${net.bytebuddy:byte-buddy-agent:jar}
```
The `${net.bytebuddy:byte-buddy-agent:jar}` property requires adding the `maven-dependency-plugin:properties` execution. `@{argLine}` (not `${argLine}`) preserves Jacoco's argLine injection.

**Principle**: Test-runner noise that looks irreducible is often three independent fixes stacked. Address them as a set, not one at a time.

### 3.3 Test-time log output from the code-under-test is signal, not noise (2026-06-09)
Several dozen `ERROR/WARN` lines appear in the test output because each test case deliberately drives the code into an error path that legitimately logs. Suppressing them via a `logging.properties` filter would also hide a regression where the SPI silently stopped logging an error case. Keep them visible; they're useful when a future test fails.

**Principle**: Output from the system-under-test during tests is observable behaviour. Suppress only when volume actively impedes diagnosis.

---

## 4. Documentation & process

### 4.1 Status doc is the contract; agentknowledge is the index (2026-06-08)
`specs/keycloak.spi.mcp.status.md` carries the live narrative (what's done, what's broken, what's deferred, what each slice cost). `agentknowledge/{concepts,decisions,history}.yaml` is the queryable index. Updating one without the other splits the truth. Establish the rhythm: after each slice closes, append to both before moving on. The cost is ~30 lines of YAML/markdown and saves the next agent 30 minutes of code archaeology.

**Principle**: A status doc explains intent; an agent knowledge base lets the next session locate. You need both, kept in sync as a single end-of-slice ritual.

---

## 5. Operations & incident debugging

### 5.1 Failures that cluster by time are environmental; failures that cluster by artifact are yours (2026-06-10)
The first SPI deploy coincided with `42P01 relation does not exist` errors and everyone (user and agent alike) reached for "the new image broke it". But the timeline showed a rollback to the *previous day's known-good image* failing in the same window, and two vanilla images succeeding *after* the window. The failures correlated with **when** deploys happened, not **what** was deployed. Before accepting an artifact-correlation theory, lay out every deploy attempt on a timeline and check whether a known-good artifact also failed inside the suspect window.

**Principle**: Artifact bisection is only valid when trials are interleaved in time. A fails / B works proves nothing if all A-trials preceded all B-trials.

### 5.2 Exonerate (or convict) a suspect image by running the exact artifact, not a rebuild (2026-06-10)
The decisive experiment was running the *literal failed image ID* (`docker images` still had it) under the production entrypoint `start --optimized`, against a schema pre-initialised by the vanilla image — the same sequence production went through. It wrote rows into the exact table production said didn't exist, served the failing endpoints, and soaked 6+ hours clean. A rebuild would have left doubt ("maybe the rebuild differs"); the exact image ID left none. Corollary: keep failed images around — they are evidence. `check_image.sh` + `kc.sh show-config` diff turns "what differs between these images?" into a one-line answer.

**Principle**: Reproduce with the byte-identical artifact and the production launch path. Every substitution (rebuilt JAR, dev-mode entrypoint, fresh schema) is a hole the conclusion can leak through.

### 5.3 Read the failing SQL before blaming your code (2026-06-10)
The failing statement was `select re1_0.ID from REALM re1_0` — stock Keycloak SQL from `JpaRealmProvider`, on a code path (`user-session-purge-expired`) the SPI never touches, while *other* connections in the same process were happily querying the same tables. No build-time JAR can make Postgres hide a table from some connections and not others; that symptom set points at connection routing (pooler/compute transient on Neon) before it points at anything in the repository. The early JAX-RS theory (`final` class, `@Path("/")`) never explained the observed symptom — it was pattern-matching on "what did we change?" rather than "what does the evidence say?".

**Principle**: Match the proposed mechanism to the observed symptom before acting on it. If the theory can't explain why login worked while realm-switch failed on the same tables, it's the wrong theory — and code changes made under it must be reverted, not kept "just in case".

### 5.4 `start-dev` cannot reproduce optimized-image problems (2026-06-10)
`run.sh` boots the image with `kc.sh start-dev`, which re-augments the Quarkus application at startup — silently bypassing whatever `kc.sh build` baked at image-build time. Any defect living in the optimized augmentation (provider registry, build-time config) is invisible under `start-dev`. Incident reproduction must use the image's real entrypoint (`start --optimized`) with production-equivalent env vars. Tracked as TD-008.

**Principle**: A local runner that swaps the entrypoint tests your code, not your image. Keep one path that runs the image exactly as production does.
