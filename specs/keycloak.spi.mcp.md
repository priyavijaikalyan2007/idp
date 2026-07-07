# Keycloak MCP SPI — Implementation Design

Companion to `KEYCLOAK_AUTH_PRD.md` §16.8. The PRD specifies the architecture and contract; this document specifies *how* to implement that contract — file layout, build setup, class skeletons, error handling, testing.

**Document version:** v0.3 — unified build output to repo-root `/target/` (Maven/Java convention) with subdirectories per artifact type (`/target/providers/`, `/target/themes/`).

---

## 1. Scope

### What this document covers

- Build technology choices (Java/Kotlin, Maven/Gradle, Keycloak SDK pinning)
- Project layout and package structure
- File-by-file specification of each class with method-level pseudocode
- JWT handoff token format and validation logic
- Configuration via environment variables
- Error handling and logging conventions
- Testing strategy (unit, integration, smoke)
- Build pipeline and artifact lifecycle
- Deployment into the custom Keycloak Docker image

### What this document does NOT cover

- Actual Java/Kotlin source code (this is implementation work)
- UI/UX of the consent wizard (that's in `KNOBBY_WEB_MCP_ENDPOINTS.md`)
- Realm configuration steps (that's in `KEYCLOAK_AUTH_PRD.md` §16.11)
- Keycloak SDK fundamentals (Keycloak's own docs are authoritative)

### Inherited contract from PRD §16.8

The architecture in PRD §16.8 is **the contract**. This document refines but never contradicts that contract. If a conflict appears between this doc and the PRD, the PRD wins; raise a PR to update this doc.

Specifically inherited:

- The `browser-mcp-tenant-pick` authentication flow structure (§16.8.1)
- The two-class structure: Authenticator + RealmResourceProvider (§16.8.2, §16.8.3)
- The three protocol mappers: Tenant (User Session Note, built-in), Scope Override (custom), Audience (built-in) (§16.8.4)
- The picker-request and picker-result JWT claim sets (§16.8.5)
- The HMAC signing approach (HS256, two-key overlap rotation) (§16.8.5)
- The JAR build & deployment story (§16.8.6)
- The SPI disambiguation: this is the Authenticator + RRP SPI, NOT the parked event-listener SPI (§16.8.7)

---

## 2. Technology choices

### Language: Java (recommended) or Kotlin

**Recommend Java.** Reasons:
- Keycloak itself is Java; every Keycloak SPI example, debugging guide, and Stack Overflow answer is in Java.
- The JVM interop is irrelevant since the SPI runs inside the same JVM as Keycloak. Choosing Kotlin only adds another build dependency without a clear win.
- Hiring/onboarding: more Java engineers than Kotlin engineers in the operational profile.

Kotlin is acceptable if the implementer has a strong preference; nothing in the design depends on the language choice. Use the same conventions Keycloak's own codebase uses.

### Build tool: Maven

Maven is what 90%+ of Keycloak SPI examples use, including all official Keycloak examples. Gradle works but isn't idiomatic in this ecosystem. Use Maven 3.9+.

### Keycloak SDK version: pin to base image

**Use Keycloak SPI version `26.6.0`** to match the base image specified in the project's Dockerfile (`quay.io/keycloak/keycloak:26.6.0`). When the base image upgrades, the SPI's dependency version upgrades in lockstep.

Pin via Maven BOM:

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>org.keycloak.bom</groupId>
      <artifactId>keycloak-spi-bom</artifactId>
      <version>26.6.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
```

All Keycloak dependencies are then declared without versions (inherited from the BOM).

### JDK version: Java 21 LTS

Matches what Keycloak 26.x is built for. Use the same Temurin or Adoptium build the deployment platform uses (specified in Dockerfile downstream).

### Testing: JUnit 5 + Mockito + Testcontainers

- **JUnit 5 (Jupiter)** for unit tests
- **Mockito** for mocking Keycloak's `KeycloakSession`, `AuthenticationFlowContext`, etc.
- **Testcontainers + keycloak-testcontainers** for integration tests that spin up a real Keycloak with the SPI loaded
- **`io.rest-assured:rest-assured`** for HTTP assertions in integration tests

---

## 3. Project structure

### Repository layout

The SPI lives in the same Git repository as the Keycloak Docker image build, alongside the operational scripts and the specs that govern them. This is a monorepo for all knobby.io Keycloak operational concerns: image build, custom code, theming, runbooks, and specs.

Rationale:
- The SPI version is tightly coupled to the Keycloak base image version (must match the BOM); coupling them in one repo enforces synchronization at PR-time rather than at deploy-time.
- The Dockerfile, the SPI source, and the build orchestration all change together when the SPI is updated; one repo, one PR, one CI run, one tag.
- The existing repo already contains the Dockerfile, scripts, and specs; folding SPI work in keeps everything discoverable from one place.

Top-level layout:

```
repo-root/
├── Dockerfile                          # base image: quay.io/keycloak/keycloak:26.6.0
├── build.sh                            # builds artifacts → stages to /target/ → builds Docker image
├── run.sh                              # runs the latest container image locally
├── push.sh                             # pushes :latest + SHA-pinned tags
├── deploy.sh                           # rolls Cloud Run revision to the latest image
├── test.sh                             # runs Java unit + integration tests
├── smoke.sh                            # post-deployment Keycloak realm/MCP smoke tests
├── monitor.sh                          # streams Cloud Run logs in real time
├── logs.sh                             # retrieves latest Cloud Run logs
├── specs/                              # specs (PRDs, designs)
│   ├── KEYCLOAK_AUTH_PRD.md
│   ├── KEYCLOAK_MCP_SPI_DESIGN.md      ← this document
│   ├── KNOBBY_WEB_MCP_ENDPOINTS.md
│   └── KEYCLOAK_THEMING_GUIDE.md
├── src/                                # all custom source code
│   ├── providers/                      # Keycloak SPI providers (Maven module root)
│   │   ├── pom.xml
│   │   ├── src/main/java/io/knobby/keycloak/mcp/...
│   │   ├── src/main/resources/META-INF/services/...
│   │   ├── src/test/java/io/knobby/keycloak/mcp/...
│   │   └── target/                     # Maven's working directory (gitignored, internal cruft)
│   ├── themes/                         # Keycloakify theme source (parked)
│   └── static/                         # custom static HTML (not used by MCP SPI)
├── target/                             # unified deliverable output (gitignored)
│   ├── providers/                      # only deployable JARs end up here
│   │   └── knobby-keycloak-mcp-spi-{version}.jar
│   └── themes/                         # built theme JAR(s); empty until Keycloakify work activates
│       └── knobby-theme-{version}.jar
├── playbooks/                          # operational runbooks
└── docs/                               # supplementary documentation (if any)
```

### Two `target/` directories — why both exist

There are intentionally two `target/` paths in the layout:

| Path | Owner | Purpose | Cleanup |
|---|---|---|---|
| `src/providers/target/` | Maven | Standard Maven working directory — `classes/`, `test-classes/`, `maven-archiver/`, and the *built* JAR Maven produces. Maven's defaults are preserved here. | `mvn clean` |
| `/target/providers/` | `build.sh` | Clean staging directory containing **only deployable JARs**. This is what the Dockerfile's `COPY` step reads. | `build.sh` recreates it on every run |

The reason to keep both rather than collapsing them: if Maven were configured to output directly to `/target/providers/` (via pom.xml's `<build><directory>` override), that directory would also contain Maven's intermediate cruft (`classes/`, etc.), and the Dockerfile's `COPY ./target/providers/ /opt/keycloak/providers/` would drag all that cruft into the Keycloak image's providers directory. Two directories with clearly-separated responsibilities is cleaner.

Both directories are in `.gitignore`. The repo's git-tracked content is source files only.

### Maven module location

The SPI is a single Maven module rooted at `src/providers/`. Within that module, the standard Maven directory layout applies:

```
src/providers/
├── pom.xml
├── src/main/java/
│   └── io/knobby/keycloak/mcp/
│       ├── authenticator/
│       │   ├── McpTenantPickerAuthenticator.java
│       │   └── McpTenantPickerAuthenticatorFactory.java
│       ├── resource/
│       │   ├── McpPickerCallbackResourceProvider.java
│       │   └── McpPickerCallbackResourceProviderFactory.java
│       ├── mapper/
│       │   ├── McpScopeOverrideMapper.java
│       │   └── McpScopeOverrideMapperFactory.java
│       ├── jwt/
│       │   ├── PickerRequestToken.java
│       │   ├── PickerResultToken.java
│       │   ├── HandoffTokenSigner.java
│       │   ├── HandoffTokenValidator.java
│       │   └── HandoffValidationException.java
│       ├── config/
│       │   └── McpSpiConfig.java
│       └── util/
│           └── ReplayCache.java
├── src/main/resources/
│   └── META-INF/services/
│       ├── org.keycloak.authentication.AuthenticatorFactory
│       ├── org.keycloak.services.resource.RealmResourceProviderFactory
│       └── org.keycloak.protocol.ProtocolMapper
├── src/test/
│   ├── java/io/knobby/keycloak/mcp/
│   │   ├── jwt/
│   │   │   ├── HandoffTokenSignerTest.java
│   │   │   ├── HandoffTokenValidatorTest.java
│   │   │   └── ReplayCacheTest.java
│   │   └── integration/
│   │       └── EndToEndHandoffIT.java
│   └── resources/
│       └── (test fixtures)
└── target/                             # gitignored
    └── knobby-keycloak-mcp-spi-{version}.jar
```

The "src/" inside "src/providers/" is Maven's standard source directory and is independent of the repo's top-level `src/`. The pattern looks slightly doubled, but it's idiomatic Maven and any Java developer will recognize it instantly. The alternative (overriding Maven's `sourceDirectory` to flatten the structure) creates more confusion than it removes.

### Notes on other src/ subdirectories

- **`src/themes/`** — Keycloakify theme source. Parked for MCP v1 launch (the consent UX runs in Knobby web, not in Keycloak's IdP login screens). See `KEYCLOAK_THEMING_GUIDE.md` for when this work activates.
- **`src/static/`** — for custom static HTML served by Keycloak outside the theming system. Not used by the MCP SPI (all UI is on Knobby web's side; the SPI only emits 302 redirects and a JAX-RS endpoint that returns JSON).

### Package layout rationale

- `io.knobby.keycloak.mcp` root — clearly identifies origin, avoids collision with Keycloak's `org.keycloak.*` namespace
- Sub-packages named for the **Keycloak SPI category** the class implements (`authenticator`, `resource`, `mapper`) — matches Keycloak's own structure and makes the META-INF/services declarations obvious
- `jwt` and `util` for shared infrastructure
- `config` for env-var-driven configuration

### META-INF/services registration

Each SPI type Keycloak recognizes is registered via a `META-INF/services/<spi-interface>` file containing the fully-qualified factory class name.

`src/providers/src/main/resources/META-INF/services/org.keycloak.authentication.AuthenticatorFactory`:
```
io.knobby.keycloak.mcp.authenticator.McpTenantPickerAuthenticatorFactory
```

`src/providers/src/main/resources/META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory`:
```
io.knobby.keycloak.mcp.resource.McpPickerCallbackResourceProviderFactory
```

`src/providers/src/main/resources/META-INF/services/org.keycloak.protocol.ProtocolMapper` (only if Scope Override is implemented as a custom mapper rather than a Script Mapper — see §5.5):
```
io.knobby.keycloak.mcp.mapper.McpScopeOverrideMapperFactory
```

---

## 4. Build & packaging

### Maven configuration outline

The `pom.xml` lives at `src/providers/pom.xml` and declares:

- **GroupId:** `io.knobby`
- **ArtifactId:** `knobby-keycloak-mcp-spi`
- **Version:** semver, e.g. `1.0.0`
- **Packaging:** `jar`
- **Java version:** 21 (source and target)
- **Keycloak BOM import** as in §2
- **Dependencies** (all `<scope>provided</scope>` because Keycloak supplies them at runtime):
  - `org.keycloak:keycloak-core`
  - `org.keycloak:keycloak-server-spi`
  - `org.keycloak:keycloak-server-spi-private`
  - `org.keycloak:keycloak-services`
  - `org.keycloak:keycloak-saml-core` (only if SAML interactions are needed; usually not for this SPI)
  - `jakarta.ws.rs:jakarta.ws.rs-api` (for the RealmResourceProvider JAX-RS annotations)
- **Test dependencies:**
  - `org.junit.jupiter:junit-jupiter`
  - `org.mockito:mockito-core`
  - `org.testcontainers:testcontainers`
  - `org.testcontainers:junit-jupiter`
  - `com.github.dasniko:testcontainers-keycloak`
  - `io.rest-assured:rest-assured`
- **Plugin: maven-shade-plugin** (or just maven-jar) — shade is needed only if pulling in dependencies not provided by Keycloak. For this SPI, no external deps beyond what Keycloak provides, so a plain `maven-jar-plugin` is sufficient.
- **Plugin: maven-failsafe-plugin** for integration tests (`*IT.java` files run separately from unit tests)

### Output JAR

Maven's working output (intermediate classes, test artifacts, and the built JAR) goes to its standard location:

`src/providers/target/knobby-keycloak-mcp-spi-${project.version}.jar`

`build.sh` then stages the deployable JAR (and only the JAR — none of Maven's intermediates) to the repo-root unified output directory:

`/target/providers/knobby-keycloak-mcp-spi-${project.version}.jar`

The Dockerfile reads from `/target/providers/` when assembling the image. See §11 for the build.sh orchestration and §3 (Two `target/` directories — why both exist) for the rationale on the two-target layout.

### Versioning

Semver: `MAJOR.MINOR.PATCH`. Increment rules:
- **MAJOR**: contract-breaking change (e.g., new required env var, change in JWT claim names). Requires coordinated update with `KNOBBY_WEB_MCP_ENDPOINTS.md`.
- **MINOR**: new feature in a backwards-compatible way (e.g., new optional claim).
- **PATCH**: bug fix.

The SPI version is stamped into the Docker image via `--build-arg SPI_VERSION=...` (which `build.sh` reads from the pom.xml automatically — see §11). The same value populates the `io.knobby.keycloak.spi.version` OCI label, making it visible at `docker inspect` time on any running revision.

---

## 5. Component specifications

### 5.1 McpTenantPickerAuthenticator

The SPI Authenticator class that runs as the final step of the `browser-mcp-tenant-pick` flow. Responsibilities per PRD §16.8.2 plus implementation specifics.

**Class signature:**
```
public class McpTenantPickerAuthenticator implements Authenticator {
    // No instance state — Keycloak creates per-request
}
```

**Methods to implement** (from the `Authenticator` interface):

#### `authenticate(AuthenticationFlowContext context)`

Called when this step is first encountered in the flow.

Pseudocode:
```
authenticate(context):
    0. // SHORT-CIRCUIT GUARD — SAFETY NET ONLY (not load-bearing under the current design).
       //
       // CURRENT DESIGN (settled): the McpClientRegistrationPolicy CRP (§5.8) binds
       // 'browser-mcp-tenant-pick' to each MCP client ATOMICALLY at registration.
       // So this Authenticator only ever runs for real MCP clients — a non-MCP
       // client (e.g. knobby-{env}-web) is never bound to this flow and never
       // reaches this code. The realm default stays 'browser-federated-only'
       // (Option B); this flow is NEVER the realm default.
       //
       // Therefore this guard is a PURE SAFETY NET: it exists only to fail safe if
       // someone ever misconfigures the realm to make this flow the default, or
       // binds it to a non-MCP client by mistake. It is NOT relied upon for
       // correctness — correctness comes from atomic per-client binding at
       // registration (§5.8).
       //
       // Detection signal: an MCP client is marked by the CRP with the client
       // attribute 'knobby.mcp'="true" (§5.8) AND/OR the 'mcp-default' client scope.
       // Prefer the attribute — it is set atomically at registration and cannot be
       // accidentally acquired by the web client via a realm-default scope.
       client = context.getAuthenticationSession().getClient()
       isMcpClient = "true".equals(client.getAttribute("knobby.mcp"))
                     || client.getClientScopes(true).containsKey("mcp-default")
                     || client.getClientScopes(false).containsKey("mcp-default")
       if not isMcpClient:
           context.success()      // no-op safety net: let the flow finish as normal login
           return

    1. user = context.getUser()             // set by previous flow steps
       if user is null:
           context.failure(INTERNAL_ERROR, "MCP picker reached without authenticated user")
           return

    2. authSession = context.getAuthenticationSession()
       clientId = authSession.getClient().getClientId()
       requestedScopes = authSession.getClientScopes()
       oauthState = authSession.getRedirectUri()     // or wherever Keycloak stores the original state

    3. picker_request = PickerRequestToken.builder()
           .issuer("keycloak-mcp-spi")
           .audience("knobby-web-mcp-consent")
           .subject(user.getId())
           .knobbySubject(user.getId())
           .mcpClientId(clientId)
           .mcpRequestedScopes(requestedScopes)
           .oauthState(oauthState)
           .nonce(SecureRandom.bytes(16) hex-encoded)
           .jti(UUID.randomUUID())
           .issuedAt(now)
           .expiresAt(now + 5 minutes)
           .build()

    4. signed_token = HandoffTokenSigner.sign(picker_request)
       knobbyWebHost = McpSpiConfig.knobbyWebHost()       // e.g., "prod.knobby.io"
       redirect_url = "https://" + knobbyWebHost + "/mcp/consent?token=" + URL_encode(signed_token)

    5. log.info("Emitting MCP picker request for user={} client={} jti={}",
                user.getId(), clientId, picker_request.jti)

    6. context.challenge(Response.seeOther(URI.create(redirect_url)).build())
       // .challenge() with a redirect Response tells Keycloak to suspend the flow
       // and serve the response to the browser. When the user comes back via the
       // RealmResourceProvider's callback, the flow will resume.
```

#### `action(AuthenticationFlowContext context)`

Called when the user is returned to this Authenticator's step (e.g., via a form POST). For our flow, the user does NOT come back via the Authenticator's action endpoint — they come back via the RealmResourceProvider's callback (§5.3). So `action()` should not be called in our happy path. If it IS called, that's a bug or an attempted bypass:

```
action(context):
    log.warn("Unexpected action() call on McpTenantPickerAuthenticator. Flow not " +
             "designed to receive direct form POSTs. Failing.")
    context.failure(AuthenticationFlowError.INVALID_CREDENTIALS)
```

#### `requiresUser()`

```
requiresUser(): return true
// This step requires a user to be set by prior flow steps (federated auth).
```

#### `configuredFor(KeycloakSession session, RealmModel realm, UserModel user)`

```
configuredFor(...): return true
// No per-user configuration needed.
```

#### `setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user)`

```
setRequiredActions(...): return
// No-op. No required actions set by this Authenticator.
```

#### `close()`

```
close(): return
// No resources to close.
```

### 5.2 McpTenantPickerAuthenticatorFactory

The factory class that Keycloak uses to instantiate the Authenticator and surface it in the admin console.

**Class signature:**
```
public class McpTenantPickerAuthenticatorFactory implements AuthenticatorFactory {
    public static final String PROVIDER_ID = "knobby-mcp-tenant-picker";
    // PROVIDER_ID must match smoke test MCP_SPI_PROVIDER_ID env var.
}
```

**Methods:**

- `getId()` → `PROVIDER_ID` constant
- `getDisplayType()` → `"Knobby MCP Tenant Picker"`  (what the admin console shows)
- `getReferenceCategory()` → `"knobby-mcp"`
- `isConfigurable()` → `false`
- `getConfigProperties()` → empty list
- `getRequirementChoices()` → `[REQUIRED]` (no other options make sense for this step)
- `isUserSetupAllowed()` → `false`
- `getHelpText()` → `"Redirects MCP-client auth flows to Knobby web for tenant picker and consent. Required final step of browser-mcp-tenant-pick flow."`
- `create(KeycloakSession session)` → `new McpTenantPickerAuthenticator()`
- `init(...)`, `postInit(...)`, `close()` → no-op for this SPI

### 5.3 McpPickerCallbackResourceProvider

Implements `RealmResourceProvider`. Registers a JAX-RS endpoint at `/realms/{realm}/mcp-picker-callback` that receives the picker-result token from Knobby web and resumes the suspended authentication flow.

**Class signature:**
```
public class McpPickerCallbackResourceProvider implements RealmResourceProvider {
    private final KeycloakSession session;

    public McpPickerCallbackResourceProvider(KeycloakSession session) {
        this.session = session;
    }
}
```

**Methods:**

#### `getResource()`

Returns the JAX-RS resource class (this same class with @Path methods).

```
getResource(): return this
```

#### `close()`

```
close(): return
```

#### JAX-RS endpoint: `GET /` (after Keycloak's `/realms/{realm}/mcp-picker-callback` path prefix)

> **RECONCILED with the shipped implementation (ERRATA-003, 2026-07-06).** The
> original pseudocode below correlated the session by `picker_request_jti` and
> resumed via a hand-driven `AuthenticationProcessor.continueAuthentication()`.
> Neither matches what was built. The **actual** design correlates via three
> signed claims the app echoes from the picker-request — `kc_client_id`,
> `kc_tab_id`, `auth_session_id` — recovers the auth session through
> `AuthenticationSessionManager`, and resumes by redirecting to Keycloak's own
> action URL (`AuthenticationFlowURLHelper.getLastExecutionUrl`). This section now
> documents that.

**Correlation-claim contract.** The callback is stateless: it recovers the
suspended session purely from the signed picker-result. The app **must** echo
`kc_client_id`, `kc_tab_id`, and `auth_session_id` from the picker-request into
the picker-result (web spec §3.3 / ERRATA-003). Carrying them *inside the
HMAC-signed JWT* (rather than as URL query params) keeps them tamper-proof. Their
absence is the production `client=null` failure — reported as `missing_correlation`.

Pseudocode (as implemented):
```
@GET
@Path("/")
public Response handleCallback(@QueryParam("picker_result") String pickerResult)

    1. if pickerResult is null or empty:
           return badRequest("missing_token")

    2. try:
           token = HandoffTokenValidator.validatePickerResult(pickerResult, realmName)
           // verifies HS256 sig (current+previous key), iss/aud/exp/iat, jti replay
       catch HandoffValidationException e:
           return badRequest("invalid_handoff", e.getCode())
       catch McpSpiConfigException e:
           return badRequest("realm_misconfigured", e.getCode())

    3. // Correlation-claim guard (ERRATA-003). Distinguishes "app sent no
       //  client id" from "client id doesn't resolve".
       if isBlank(token.kcClientId) || isBlank(token.kcTabId) || isBlank(token.authSessionId):
           return badRequest("missing_correlation")

    4. client = realm.getClientByClientId(token.kcClientId)
       if client is null:
           return badRequest("client_not_found")

    5. // Recover the suspended auth session: AUTH_SESSION_ID cookie first, then
       //  the HMAC-signed auth_session_id as a fallback (cookie may be dropped
       //  on the cross-site round-trip through the app).
       authSession = AuthenticationSessionManager
                        .getCurrentAuthenticationSession(realm, client, token.kcTabId)
                     ?? AuthenticationSessionManager
                        .getAuthenticationSessionByIdAndClient(realm, token.authSessionId, client, token.kcTabId)
       if authSession is null:
           return badRequest("session_not_found")

    6. currentUser = authSession.getAuthenticatedUser()
       if currentUser == null || !currentUser.getId().equals(token.userSubEcho):
           return badRequest("user_mismatch")

    7. // Write the session notes the protocol mappers read.
       authSession.setUserSessionNote("knobby_tenant_id", token.chosenTenantId)
       authSession.setUserSessionNote("knobby_scopes", join(" ", token.grantedScopes))

    8. // Resume by handing the browser back to Keycloak's own last-execution URL;
       //  Keycloak's flow engine re-enters the CHALLENGED authenticator execution
       //  and finishes the flow. No manual AuthenticationProcessor needed.
       resumeUrl = new AuthenticationFlowURLHelper(session, realm, uriInfo)
                       .getLastExecutionUrl(authSession)
       return Response.seeOther(resumeUrl).build()
```

**Implementation note.** The suspend (Authenticator, §5.1) uses
`context.challenge(seeOther(...))`; the resume rides
`AuthenticationFlowURLHelper.getLastExecutionUrl`, which is Keycloak's supported
mechanism for re-entering a suspended flow at its last execution — no direct
`AuthenticationProcessor` driving. The correlation lives in the signed token, not
in server-side state, so the callback stays stateless and multi-instance-safe
(except the `jti` replay cache, §6.5).

### 5.4 McpPickerCallbackResourceProviderFactory

```
public class McpPickerCallbackResourceProviderFactory implements RealmResourceProviderFactory {
    public static final String PROVIDER_ID = "mcp-picker-callback";
    // Resulting URL: /realms/{realm}/mcp-picker-callback
}
```

Methods:
- `getId()` → `PROVIDER_ID`
- `create(KeycloakSession session)` → `new McpPickerCallbackResourceProvider(session)`
- `init(...)`, `postInit(...)`, `close()` → no-op

### 5.5 Scope Override Protocol Mapper

Two implementation choices:

#### Option A: Custom protocol mapper (recommended)

A `ProtocolMapper` implementation that reads session note `knobby_scopes` and sets the `scope` claim. Slightly more code but no Keycloak feature flag dependency.

```
public class McpScopeOverrideMapper
    extends AbstractOIDCProtocolMapper
    implements OIDCAccessTokenMapper, OIDCIDTokenMapper, UserInfoTokenMapper {

    public static final String PROVIDER_ID = "knobby-mcp-scope-override";

    @Override
    public AccessToken transformAccessToken(AccessToken token,
                                            ProtocolMapperModel mappingModel,
                                            KeycloakSession session,
                                            UserSessionModel userSession,
                                            ClientSessionContext clientSessionCtx) {
        String scopesNote = userSession.getNote("knobby_scopes");
        if (scopesNote != null && !scopesNote.isEmpty()) {
            token.setScope(scopesNote);
        }
        return token;
    }

    // Similar for transformIDToken, transformUserInfoToken if needed
}
```

Factory class follows the same pattern as the AuthenticatorFactory.

META-INF/services registration:
```
io.knobby.keycloak.mcp.mapper.McpScopeOverrideMapperFactory
```

#### Option B: Script Mapper

Use Keycloak's built-in `oidc-script-based-protocol-mapper` with JavaScript that reads the session note. Pros: no Java code. Cons: requires the `scripts` feature enabled in Keycloak (`--features=scripts`), which is disabled by default in 26.x and considered preview.

Script payload (configured in admin console as part of `mcp-default` scope's mapper config):
```javascript
var note = userSession.getNote("knobby_scopes");
if (note) {
    token.setScope(note);
}
exports = null;
```

**Recommendation: go with Option A.** Avoids the preview-feature dependency and gives us a clean, testable Java class. ~30 lines of code.

### 5.6 Tenant Claim Mapper (built-in, no custom code)

Uses Keycloak's built-in `oidc-usersessionmodel-note-mapper`. Configured in the admin console as part of the `mcp-default` Client Scope:

- Mapper Type: User Session Note
- User Session Note: `knobby_tenant_id`
- Token Claim Name: `tenant`
- Claim JSON Type: String
- Add to ID token: On
- Add to access token: On
- Add to userinfo: On

No SPI code needed; configuration only. The SPI's responsibility is to *write* the session note via the RealmResourceProvider (§5.3 step 5).

### 5.7 Audience Mapper (built-in, no custom code)

Uses Keycloak's built-in `oidc-audience-mapper`. Configured on `mcp-default` Client Scope:

- Mapper Type: Audience
- Included Custom Audience: `knobby-mcp-api`
- Add to access token: On
- Add to ID token: Off

No SPI code needed.

### 5.8 McpClientRegistrationPolicy (Client Registration Policy — atomic MCP bootstrapping)

**Purpose.** Close the MCP-client bootstrapping gap: a freshly DCR'd client has no `mcp-default` scope and no flow binding, so its *first* authorization can't be detected as MCP and never routes to the tenant-picker (it falls through the realm-default `browser-federated-only` flow → Keycloak's own consent → no provisioning). This CRP fixes that by **atomically marking every anonymous-DCR client at registration time**, before its first authorization: it assigns `mcp-default` (+ the author bundle) as default scopes and binds the `browser-mcp-tenant-pick` flow — all on the live `ClientModel`, inside the registration transaction.

**🔒 Load-bearing invariant: "anonymous DCR in this realm is MCP-only."** This CRP marks **every** anonymous-DCR client unconditionally — it does NOT gate on a discriminator. That is deliberate and correct, but rests on an explicit invariant:

> **In the `knobby-{env}` realm, the only integration that performs anonymous Dynamic Client Registration is MCP clients.**

Why unconditional (and why NOT a discriminator): the whole reason this CRP exists is that we **cannot rely on what a client requests** — the bootstrapping redesign happened precisely because a client requesting `mcp-default` (or any request-time signal) is unreliable (some MCP clients won't send it). So gating on requested-scope or `software_id` would reintroduce the exact bug this fixes: a real MCP client that omits the signal wouldn't get marked, wouldn't get the flow binding, and its first authorization would break again. The only *reliable* discriminators are intrinsic to how registration happens — and "it's anonymous DCR" is already one (the CRP is bound as an anonymous CRP, §deployment below). There is no finer reliable signal available without the client cooperating, which we've established we can't depend on.

**The mitigation is a documented invariant, not a code gate.** DCR (RFC 7591, 2015) predates MCP and is not MCP-exclusive in general — but in *this* realm it is, today and for the foreseeable roadmap, and the realm is entirely under knobby.io's control. If that ever changes (a non-MCP integration is added that self-registers anonymously against this realm), this CRP must gain a discriminator — and at *that* point there will be a concrete, real signal to gate on (that integration's `software_id`, a distinct registration endpoint, or a separate realm). Until then, a speculative gate using an unreliable signal would be strictly worse than the honest invariant. **Tracked in `DEFERRED_ITEMS.md` (invariant + revisit-trigger).**

**Why a CRP, and why `afterRegister`.** The `ClientRegistrationPolicy` SPI's `afterRegister(ClientRegistrationContext, ClientModel)` runs **synchronously within the registration transaction** and receives the mutable `ClientModel`. Keycloak's own built-ins (`ClientScopesClientRegistrationPolicy`, `ProtocolMappersClientRegistrationPolicy`, `ConsentRequiredClientRegistrationPolicy`) use exactly this hook to mutate just-registered clients — so this is a first-class, framework-blessed pattern, not a workaround. Because the mutations happen on the `ClientModel` in the same transaction as the registration, they are **atomic with it**: either the client is created fully-marked (scopes + flow binding + attribute) or the registration rolls back and no client is created. **Partial states (scope assigned but flow unbound, or vice-versa) are impossible.** This is the key property — it removes the need for any post-registration reconciliation or recovery logic.

**Config-driven, not hardcoded.** The scope list and flow alias are read from the CRP's `ComponentModel` config (the standard built-in-CRP pattern), NOT compiled in. knobby.io's scope taxonomy will grow (the ontology/RBAC surface implies more granular scopes over time), so hardcoding would couple a business-level change (new permission scope) to a JAR rebuild + Keycloak-image redeploy. Config-driven means adding a scope is a console config change. Provide sane defaults (the current six + `browser-mcp-tenant-pick`) but make them overridable via `ComponentConfig`.

**Interface:**
```java
public class McpClientRegistrationPolicy implements ClientRegistrationPolicy {

    private final KeycloakSession session;
    private final ComponentModel config;   // scope list + flow alias come from here

    // Config keys (with defaults):
    //   default-scopes  (default: mcp-default,knobby:read,knobby:comment,
    //                             knobby:curate,knobby:write,knobby:share)
    //   optional-scopes (default: knobby:admin)
    //   browser-flow    (default: browser-mcp-tenant-pick)
    //   mcp-attribute   (default: knobby.mcp)

    @Override
    public void afterRegister(ClientRegistrationContext context, ClientModel client) {
        // Marks EVERY anonymous-DCR client (see load-bearing invariant above).
        // Bound as an 'anonymous' CRP subtype, so first-party admin-created clients
        // never reach this. No per-request discriminator — by design.
        RealmModel realm = session.getContext().getRealm();

        // 1. Mark as MCP with the configured attribute (intrinsic marking, not
        //    scope-request dependent). Default attribute: "knobby.mcp".
        String mcpAttr = config.get("mcp-attribute", "knobby.mcp");
        client.setAttribute(mcpAttr, "true");

        // 2. Assign default + optional scopes from CONFIG (not hardcoded).
        //    Default scopes are granted whether or not the client requests them.
        for (String scopeName : config.getList("default-scopes")) {   // config-driven
            ClientScopeModel scope = KeycloakModelUtils
                .getClientScopeByName(realm, scopeName);
            if (scope == null) {
                throw new ClientRegistrationPolicyException(
                    "Required MCP client scope missing: " + scopeName
                    + " (create per setup guide D.3/D.4)");
            }
            client.addClientScope(scope, true);   // true = default (not optional)
        }
        for (String scopeName : config.getList("optional-scopes")) {  // e.g. knobby:admin
            ClientScopeModel scope = KeycloakModelUtils.getClientScopeByName(realm, scopeName);
            if (scope != null) { client.addClientScope(scope, false); }
        }

        // 3. Bind the configured MCP browser flow (per-client override).
        String flowAlias = config.get("browser-flow", "browser-mcp-tenant-pick");
        AuthenticationFlowModel flow = realm.getFlowByAlias(flowAlias);
        if (flow == null) {
            throw new ClientRegistrationPolicyException(
                "MCP browser flow not found: " + flowAlias
                + " (create per setup guide D.2)");
        }
        client.setAuthenticationFlowBindingOverride("browser", flow.getId());

        // Any throw here rolls back the ENTIRE registration transaction — atomic.
    }

    @Override public void afterUpdate(ClientRegistrationContext ctx, ClientModel client) { /* no-op */ }
    @Override public void beforeRegister(ClientRegistrationContext ctx) { /* see note on B1 below */ }
    @Override public void beforeUpdate(ClientRegistrationContext ctx, ClientModel client) { }
    @Override public void beforeView(ClientRegistrationProvider p, ClientModel client) { }
    @Override public void beforeDelete(ClientRegistrationProvider p, ClientModel client) { }
    @Override public void close() { }
}
```
Plus `McpClientRegistrationPolicyFactory implements ClientRegistrationPolicyFactory` (providerId e.g. `knobby-mcp-registration`) and a `META-INF/services/org.keycloak.services.clientregistration.policy.ClientRegistrationPolicyFactory` entry — same packaging as the authenticator SPI (§3), same JAR.

**Deployment — bind as an anonymous CRP.** Register it under **Clients → Client registration → Anonymous Access Policies** (the CRP system, same place as Trusted Hosts — setup guide F.1). As an anonymous-subtype policy it governs only anonymous DCR registrations, never admin-created first-party clients.

**⚠️ Verify during implementation (26.6.0 model API).** The pattern is confirmed (afterRegister receives a mutable ClientModel; Keycloak's own CRPs mutate there). Verify the exact 26.6.0 signatures: `client.setAuthenticationFlowBindingOverride("browser", flowId)`, `realm.getFlowByAlias(...)`, `client.addClientScope(scope, isDefault)`, and `KeycloakModelUtils.getClientScopeByName(...)`. Confirm the flow-binding override set in `afterRegister` persists (it should — it's a field on the client entity written in-transaction).

**Interaction with the tenant-picker Authenticator (§5.1).** Because this CRP guarantees only real MCP clients are ever bound to `browser-mcp-tenant-pick`, the Authenticator's step-0 short-circuit (§5.1) is now a **pure safety net, not load-bearing** — correctness comes from atomic binding here. The Authenticator's detection was updated to prefer the `knobby.mcp` attribute this CRP sets.

**Interaction with `/mcp/consent` provisioning (web spec §7.5).** This CRP does the **bootstrap subset** — `mcp-default` + author bundle + flow binding — the minimum for the first authorization to route correctly. The app's `/mcp/consent` still runs for the **rest**: the tenant-picker wizard, tenant-specific setup, and the `mcp_provisioned_clients` record. Because both the CRP and `/mcp/consent` are idempotent (adding an already-present scope / setting an already-correct binding is a no-op), it's safe for both to touch the client. **This splits provisioning: scope+flow bootstrap moves to registration (this CRP); the wizard/tenant work stays at `/mcp/consent`.** See errata + web spec §7.5 for the app-side implication (the app no longer needs to do the scope/flow bootstrap itself, though doing so idempotently is harmless).

**Relationship to the deferred `AllowedGrantTypesPolicy` (§13a.1 / register B1).** Both are `ClientRegistrationPolicy` providers. They can be **one provider**: this CRP's `beforeRegister` is the natural home for the grant-type/auth-method rejection (B1), while `afterRegister` does the marking. Folding them keeps all DCR-time registration policy in one SPI. When you build B1, add it here rather than as a separate provider.

```
public class PickerRequestToken {
    String iss;                    // "keycloak-mcp-spi"
    String aud;                    // "knobby-web-mcp-consent"
    String sub;                    // user's Keycloak sub
    String knobbySub;              // duplicate of sub for clarity
    String mcpClientId;            // DCR-registered client_id
    List<String> mcpRequestedScopes;
    String oauthState;
    String nonce;                  // 128-bit random, hex-encoded
    String jti;                    // UUID
    long iat;                      // epoch seconds
    long exp;                      // iat + 300 (5 min)

    // Builder pattern
    // toClaims() → Map<String, Object> for the JWT library
    // fromClaims(Map<String, Object>) → static factory
}
```

Use Jackson or Keycloak's bundled `org.keycloak.util.JsonSerialization` for ser/deser. Don't pull in an external JSON library — Keycloak ships one.

### 6.2 PickerResultToken POJO

```
public class PickerResultToken {
    String iss;                    // "knobby-web-mcp-consent"
    String aud;                    // "keycloak-mcp-spi"
    String pickerRequestJti;       // jti from the request token (correlation)
    String userSubEcho;            // must match the picker-request's sub
    String chosenTenantId;         // UUID of the tenant the user picked
    List<String> grantedScopes;
    String oauthState;
    String nonce;
    String jti;
    long iat;
    long exp;                      // iat + 60 (1 min)
}
```

### 6.3 HandoffTokenSigner

Responsibilities:
- Sign POJOs into HS256 JWTs using the current HMAC key.
- Source the HMAC key from `McpSpiConfig` (env var).

Pseudocode:
```
class HandoffTokenSigner:
    private final byte[] currentKey;

    HandoffTokenSigner(McpSpiConfig config):
        this.currentKey = base64Decode(config.handoffHmacKey())
        if currentKey.length != 32:
            throw new IllegalArgumentException("HMAC key must be 32 bytes (256 bits)")

    String sign(Object payload):
        header = '{"alg":"HS256","typ":"JWT"}'
        encHeader = base64url(header)
        encPayload = base64url(JsonSerialization.writeValueAsString(payload))
        signingInput = encHeader + "." + encPayload
        signature = HMAC_SHA256(currentKey, signingInput.getBytes("UTF-8"))
        encSignature = base64url(signature)
        return signingInput + "." + encSignature
```

Note: Keycloak ships `com.nimbusds:nimbus-jose-jwt` and similar JWT libraries. Prefer using one of those rather than hand-rolling. Keycloak's own `org.keycloak.crypto` package has HMAC utilities too.

### 6.4 HandoffTokenValidator

Responsibilities:
- Verify signature against current key (or previous key during rotation).
- Verify `iss`, `aud`, `exp`, `iat`.
- Check `jti` for replay (via ReplayCache, §6.5).
- Return parsed POJO on success; throw `HandoffValidationException` on failure.

Pseudocode:
```
class HandoffTokenValidator:
    private final byte[] currentKey;
    private final byte[] previousKey;     // nullable
    private final ReplayCache replayCache;

    HandoffTokenValidator(McpSpiConfig config, ReplayCache cache):
        this.currentKey = base64Decode(config.handoffHmacKey())
        this.previousKey = config.handoffHmacKeyPrevious() != null
                           ? base64Decode(config.handoffHmacKeyPrevious())
                           : null
        this.replayCache = cache

    PickerResultToken validatePickerResult(String jwt):
        parts = jwt.split("\\.")
        if parts.length != 3:
            throw HandoffValidationException(MALFORMED)

        signingInput = parts[0] + "." + parts[1]
        receivedSig = base64urlDecode(parts[2])

        // Try current key first, then previous (for rotation)
        if !constantTimeEquals(HMAC_SHA256(currentKey, signingInput), receivedSig):
            if previousKey == null || !constantTimeEquals(HMAC_SHA256(previousKey, signingInput), receivedSig):
                throw HandoffValidationException(BAD_SIGNATURE)

        payload = JsonSerialization.readValue(base64urlDecode(parts[1]), PickerResultToken.class)

        // Standard JWT claim checks
        if !payload.iss.equals("knobby-web-mcp-consent"):
            throw HandoffValidationException(BAD_ISSUER)
        if !payload.aud.equals("keycloak-mcp-spi"):
            throw HandoffValidationException(BAD_AUDIENCE)
        long now = System.currentTimeMillis() / 1000
        if payload.exp < now:
            throw HandoffValidationException(EXPIRED)
        if payload.iat > now + 60:    // future-dated (clock skew tolerance)
            throw HandoffValidationException(FUTURE_DATED)

        // Replay check
        if !replayCache.tryConsume(payload.jti, payload.exp):
            throw HandoffValidationException(REPLAY)

        return payload
```

### 6.5 ReplayCache

A bounded LRU cache mapping `jti` → expiry time. Used to prevent token replay.

```
class ReplayCache:
    private final Map<String, Long> cache    // LinkedHashMap with access order, bounded size
    private final int maxSize = 10000
    private final long maxAgeSeconds = 600   // 10 min, covers both token TTLs

    synchronized boolean tryConsume(String jti, long expiryEpochSeconds):
        // Evict expired entries on every call (lazy)
        long now = System.currentTimeMillis() / 1000
        cache.entrySet().removeIf(entry -> entry.getValue() < now)

        // Check for replay
        if cache.containsKey(jti):
            return false    // already consumed

        // Record consumption
        cache.put(jti, expiryEpochSeconds)

        // Bound size
        if cache.size() > maxSize:
            // Remove oldest (LinkedHashMap with access order semantics handles this)
            Iterator<String> it = cache.keySet().iterator()
            it.next()
            it.remove()

        return true
```

For multi-instance Keycloak deployments (clustered), this cache would need to be backed by Infinispan or similar. For the single-instance Cloud Run / Hetzner deployment, an in-memory map is fine. Document this assumption in the JavaDoc.

---

## 7. Configuration

### 7.1 Environment variables

| Variable | Required? | Description |
|---|---|---|
| `KNOBBY_MCP_HANDOFF_HMAC_KEY` | Yes | Current HMAC key, base64-encoded (32 bytes = 256 bits). Used for both signing outgoing picker-request tokens and validating incoming picker-result tokens. |
| `KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS` | No | Previous HMAC key during rotation. If set, the validator accepts tokens signed with either current or previous. Removed once all in-flight tokens have expired. |
| `KNOBBY_WEB_HOST` | Yes | Hostname of Knobby web for the picker redirect (e.g., `"prod.knobby.io"`). No scheme, no trailing slash. The Authenticator constructs the full URL as `https://<host>/mcp/consent?token=...`. |

### 7.2 Startup validation

`McpSpiConfig` reads these env vars eagerly at first use. If a required var is missing or malformed, throw a runtime exception that surfaces in Keycloak's startup logs and halts the SPI from registering. The Authenticator and RealmResourceProvider both depend on McpSpiConfig, so the failure cascades obviously rather than silently breaking flows at request time.

```
class McpSpiConfig:
    private static final String ENV_HMAC_KEY = "KNOBBY_MCP_HANDOFF_HMAC_KEY"
    private static final String ENV_HMAC_KEY_PREVIOUS = "KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS"
    private static final String ENV_KNOBBY_WEB_HOST = "KNOBBY_WEB_HOST"

    String handoffHmacKey():
        String value = System.getenv(ENV_HMAC_KEY)
        if isBlank(value):
            throw IllegalStateException("Required env var " + ENV_HMAC_KEY + " not set")
        try:
            byte[] bytes = Base64.getDecoder().decode(value)
            if bytes.length != 32:
                throw IllegalStateException(ENV_HMAC_KEY + " must decode to 32 bytes, got " + bytes.length)
        catch IllegalArgumentException e:
            throw IllegalStateException(ENV_HMAC_KEY + " is not valid base64")
        return value

    // similar for handoffHmacKeyPrevious() (returns null if not set)
    // similar for knobbyWebHost() (required, must not be blank)
```

### 7.3 Replay cache configuration

Currently hardcoded in `ReplayCache` (maxSize=10000, maxAgeSeconds=600). If tuning is ever needed, expose via env vars.

---

## 8. Error handling

### Error categories

| Category | Triggers | User-facing response | Logging |
|---|---|---|---|
| Configuration error | Missing env var, malformed key | SPI fails to load; Keycloak startup fails | ERROR with stack trace |
| Authenticator misuse | `action()` called unexpectedly | OAuth flow fails with `access_denied` | WARN with context |
| Picker-result validation failure | HMAC mismatch, expired, replay, user mismatch | HTTP 400 JSON `{"error": "invalid_handoff", "error_description": "..."}` | WARN with category code, no PII |
| Session not found | Auth session expired before user returned | HTTP 400 JSON `{"error": "session_not_found"}` | WARN |
| Internal error (uncaught exception) | Bug | HTTP 500 generic | ERROR with stack trace |

### `HandoffValidationException`

```
class HandoffValidationException extends RuntimeException:
    enum Code:
        MALFORMED,
        BAD_SIGNATURE,
        BAD_ISSUER,
        BAD_AUDIENCE,
        EXPIRED,
        FUTURE_DATED,
        REPLAY,
        USER_MISMATCH,
        ;

    private final Code code

    HandoffValidationException(Code code):
        super(code.name())
        this.code = code
```

### What NOT to log

- The raw HMAC key (obviously)
- The full JWT (it might contain user IDs that aren't logging-safe in some contexts; log the `jti` instead)
- User email or PII

What to log: provider name, code, `jti`, user ID (Keycloak's `sub` is the pseudonymous ID, OK to log per §10.6 audit conventions).

---

## 9. Logging

Use JBoss Logging (Keycloak's bundled logger). Same pattern as Keycloak's own code:

```
private static final Logger log = Logger.getLogger(McpTenantPickerAuthenticator.class);
```

Levels:
- **DEBUG**: detailed step-by-step trace. Off in prod, on in dev when debugging.
- **INFO**: significant events — picker-request emitted, picker-result accepted, flow completed.
- **WARN**: validation failures, unexpected `action()` calls, replays detected.
- **ERROR**: configuration errors, uncaught exceptions, integration failures.

Format every log message with structured key-value pairs:
```
log.infof("Picker-request emitted user=%s client=%s jti=%s", userId, clientId, jti);
log.warnf("Picker-result validation failed code=%s jti=%s", code, jti);
```

Keycloak's log aggregation can then parse these for metrics/alerting.

---

## 10. Testing

### 10.1 Unit tests

Run via `./test.sh` (which invokes `mvn -B verify` in `src/providers/`). Cover:

| Class | What to test |
|---|---|
| `HandoffTokenSigner` | Signs valid JWT; rejects wrong key length |
| `HandoffTokenValidator` | Accepts valid token; rejects tampered token; rejects expired token; rejects replay; accepts current+previous key during rotation; rejects future-dated tokens |
| `PickerRequestToken`, `PickerResultToken` | Round-trip JSON serialization |
| `ReplayCache` | First-use accepts; second-use rejects; bounded size; lazy expiry |
| `McpSpiConfig` | Throws on missing required env; throws on malformed base64; throws on wrong key length |

Mock Keycloak interfaces (`KeycloakSession`, `AuthenticationFlowContext`, `RealmModel`, `UserModel`) with Mockito.

Target: 90%+ line coverage on the JWT and config classes; 70%+ on the Authenticator/Resource classes (the Keycloak-integration parts are hard to unit-test).

### 10.2 Integration tests

Run via `./test.sh` (Maven's Failsafe plugin runs `*IT.java` tests during the `verify` phase). Use `testcontainers-keycloak` to spin up a real Keycloak with the SPI loaded:

```java
@Testcontainers
public class EndToEndHandoffIT {
    @Container
    static KeycloakContainer keycloak = new KeycloakContainer("quay.io/keycloak/keycloak:26.6.0")
        .withProviderClassesFrom("target/classes")
        .withRealmImportFile("test-realm.json")
        .withEnv("KNOBBY_MCP_HANDOFF_HMAC_KEY", BASE64_TEST_KEY)
        .withEnv("KNOBBY_WEB_HOST", "localhost:8090");

    @Test
    void authenticator_emits_valid_picker_request() { ... }

    @Test
    void resource_provider_accepts_valid_picker_result() { ... }

    @Test
    void resource_provider_rejects_tampered_picker_result() { ... }

    @Test
    void replay_attack_is_rejected() { ... }

    // etc.
}
```

The integration test should mock Knobby web by running a small JAX-RS endpoint on localhost:8090 that:
1. Accepts the SPI's picker-request redirect
2. Validates the request token using the same HMAC key
3. Constructs and signs a picker-result token
4. Redirects back to Keycloak's mcp-picker-callback

This exercises the full handoff round-trip in CI without needing real Knobby web.

### 10.3 Smoke tests

The repo's `./smoke.sh` script (which is the renamed `keycloak-smoke-test.sh` from earlier versions of the spec) covers the realm-level validation of the SPI deployment:

- **Test 14** — SPI loaded (verifies the JAR is in `/opt/keycloak/providers/` and Keycloak registered the Authenticator provider)
- **Test 15** — `browser-mcp-tenant-pick` flow contains the SPI Authenticator as a step
- **Test 17** — `mcp-default` Client Scope contains the tenant claim mapper
- **Test 29** — Scope override mapper attached to mcp-default

These pass once the JAR is loaded and the realm is configured per `KEYCLOAK_AUTH_PRD.md` §16.11. Run `./smoke.sh` after every deployment.

### 10.4 Manual end-to-end

Once Knobby web `/mcp/consent` exists, smoke test Test 33 covers manual end-to-end. See PRD §16.11 step 9.

---

## 11. Build pipeline

The SPI build is orchestrated by the repo's existing scripts. There is no separate SPI-specific CI workflow — the SPI is a build stage within the unified flow.

### Script responsibilities (SPI-relevant slices)

| Script | What it does (re: SPI) |
|---|---|
| `build.sh` | Compiles SPI (Maven in `src/providers/`), stages the JAR to `/target/providers/`, builds the Docker image with all version labels |
| `run.sh` | Runs `knobby-keycloak:latest` locally for smoke testing |
| `push.sh` | Pushes the image (with all tags pointing at the new SHA) to the registry |
| `deploy.sh` | Rolls Cloud Run to the latest image |
| `test.sh` | Runs `mvn -B verify` in `src/providers/` — both unit and Failsafe integration tests |
| `smoke.sh` | Post-deployment validation: runs the realm/MCP smoke tests (Tests 1–29 + manual 30–36) |
| `monitor.sh` | Streams Cloud Run logs — useful when verifying SPI provider loaded at startup |
| `logs.sh` | Snapshot of recent Cloud Run logs |

### `build.sh` orchestration

The SPI integrates as additional steps inside `build.sh`. Sketch:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# 1. Read SPI version from pom.xml (single source of truth)
SPI_VERSION=$(cd src/providers && mvn -q -DforceStdout help:evaluate -Dexpression=project.version)

# 2. Build SPI JAR (this also runs unit + integration tests via mvn verify)
echo ">> Building Keycloak MCP SPI v${SPI_VERSION}..."
(cd src/providers && mvn -B clean verify)

# 3. Stage deliverable artifacts to /target/ at repo root
#    Maven outputs to src/providers/target/ (its working dir).
#    build.sh stages just the final JAR(s) to /target/providers/ for Docker COPY.
echo ">> Staging deliverable artifacts to /target/..."
rm -rf ./target/providers ./target/themes
mkdir -p ./target/providers ./target/themes
cp src/providers/target/knobby-keycloak-mcp-spi-*.jar ./target/providers/
# Future: when Keycloakify theme builds activate, stage them similarly:
#   cp src/themes/<keycloakify-output>/*.jar ./target/themes/

# 4. Build the Docker image with metadata
VCS_REF=$(git rev-parse HEAD)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IMAGE_VERSION="${IMAGE_VERSION:-$(date -u +%Y%m%d-%H%M%S)}"

docker build \
    --build-arg SPI_VERSION="$SPI_VERSION" \
    --build-arg VCS_REF="$VCS_REF" \
    --build-arg BUILD_DATE="$BUILD_DATE" \
    --build-arg IMAGE_VERSION="$IMAGE_VERSION" \
    -t knobby-keycloak:latest \
    -t "knobby-keycloak:${IMAGE_VERSION}" \
    -t "knobby-keycloak:spi-${SPI_VERSION}" \
    .

echo ">> Build complete: knobby-keycloak:${IMAGE_VERSION} (SPI v${SPI_VERSION})"
```

Notes:
- The exact details depend on the existing `build.sh` conventions; the snippet above is illustrative of what the SPI step contributes.
- `/target/` at repo root is the unified deliverable output directory (per Maven/Java convention, but elevated to the repo root rather than per-module). It contains subdirectories per artifact type: `/target/providers/`, `/target/themes/`, etc.
- The Dockerfile reads from `./target/providers/` and `./target/themes/` rather than from per-module Maven target directories. This decouples the Docker build from Maven's internal layout.
- Both `/target/` and `src/providers/target/` are in `.gitignore`. Source lives at `src/providers/`; build outputs never get committed.

### Dockerfile COPY paths

The existing Dockerfile's COPY steps should reference the unified `/target/` location:

```dockerfile
COPY ./target/providers/ /opt/keycloak/providers/
COPY ./target/themes/    /opt/keycloak/themes/
```

Because `build.sh` stages only deliverable JARs into `/target/providers/` and `/target/themes/` (never Maven intermediates), the Dockerfile can safely copy the whole directory without dragging in `classes/`, `test-classes/`, `maven-archiver/`, or similar Maven cruft. The directories must exist at Docker build time even if empty — `build.sh`'s `mkdir -p` step ensures this.

### `test.sh` orchestration

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# All Java tests live under src/providers/ for now (and any future src/<other-java> too).
# Maven's verify phase runs unit tests (Surefire) AND integration tests (Failsafe).
echo ">> Running Java tests..."
(cd src/providers && mvn -B verify)
```

Future expansion: if more Java modules appear under `src/`, add them to `test.sh` as additional `(cd src/<module> && mvn -B verify)` lines or use a Maven aggregator POM at the repo root.

### `smoke.sh` orchestration

This is the renamed `keycloak-smoke-test.sh` from earlier versions of the spec. The behavior is unchanged — `smoke.sh` runs all 29 automated tests (1–13 realm foundation, 14–29 MCP readiness) and prints the manual test URLs (30–36) for federation and MCP end-to-end testing.

Invoke after every deployment:
```bash
./deploy.sh
./smoke.sh
```

### CI integration

The repo's existing CI runs the relevant scripts on push/PR:
- **On PR:** `test.sh` (verifies Java code compiles and tests pass before merge)
- **On push to main:** `build.sh` → `push.sh` (builds and pushes a tagged image)
- **On release tag (e.g., `v2026.06.15-1`):** `build.sh` → `push.sh` → manual or auto-triggered `deploy.sh` → `smoke.sh`

No SPI-specific GitHub Actions workflow needed; the SPI is just one stage of the existing pipeline.

### Versioning relationships

There are three versions to keep coordinated:

| Version | Source | Increment rule |
|---|---|---|
| **Base Keycloak version** | Dockerfile (`quay.io/keycloak/keycloak:X.Y.Z`) | Quarterly with Keycloak release schedule; security patches as needed |
| **SPI version** | `src/providers/pom.xml` | Per §4 (semver based on contract changes) |
| **Image version** | `IMAGE_VERSION` build arg | Per deploy — typically a timestamp or release tag |

The Dockerfile labels all three so any running revision can be audited:
- `io.knobby.keycloak.base` → base Keycloak version
- `io.knobby.keycloak.spi.version` → SPI version
- `org.opencontainers.image.version` → image version

---

## 12. Deployment

The SPI ships as part of the unified Keycloak image. Deployment uses the same scripts as any other image change.

### Deploying a new SPI version

```bash
# 1. Edit src/providers/pom.xml — bump <version>
$EDITOR src/providers/pom.xml

# 2. Build (compiles SPI, stages JAR, builds Docker image)
./build.sh

# 3. (Optional) Run locally for ad-hoc verification
./run.sh

# 4. Push image to the registry (latest + SHA-pinned tags)
./push.sh

# 5. Roll Cloud Run to the new image
./deploy.sh

# 6. Verify the deployment
./smoke.sh
```

### First-time SPI deployment

For the very first SPI deployment into a realm that has never had the SPI before:

1. Run `./build.sh`, `./push.sh`, `./deploy.sh` as above. Smoke test 14 (SPI loaded) should now pass.
2. Apply realm configuration per `KEYCLOAK_AUTH_PRD.md` §16.11 manually (this is one-time per realm).
3. Run `./smoke.sh` and watch Tests 14–29 turn green progressively as each realm config step lands.

### Verifying the deployed SPI version

Two ways at runtime:

1. **Docker image labels** (via `docker inspect` or Cloud Run revision metadata):
   ```bash
   docker inspect knobby-keycloak:latest | jq '.[0].Config.Labels'
   ```
   Look for `io.knobby.keycloak.spi.version`.

2. **Keycloak admin console** → Server Info → Providers → Authenticator factories → find `knobby-mcp-tenant-picker`. The provider's version field reflects what's loaded.

### Rolling back

`./deploy.sh` should support rolling Cloud Run to a previous revision (use the existing repo's rollback mechanism). The SPI version follows the image version, so rolling back an image rolls back the SPI atomically. There is no separate SPI rollback path.

If a partial rollback is needed (revert SPI but keep other image changes), revert the pom.xml version bump in a new commit and run `build.sh` → `push.sh` → `deploy.sh` again with the prior SPI version.

### Monitoring after deploy

```bash
./monitor.sh         # Stream Cloud Run logs in real time
./logs.sh            # Snapshot of recent logs
```

Look for SPI initialization messages at startup (e.g., `INFO Loaded MCP SPI provider knobby-mcp-tenant-picker version 1.0.0`). If the SPI fails to load, Keycloak's startup logs will show stack traces; this is the first place to check when smoke Test 14 fails.

### Operational playbooks

For predictable operational scenarios, see `playbooks/` in the repo:
- **HMAC key rotation** — the two-key overlap pattern from §6.3 / §16.8.5
- **SPI deployment runbook** — the steps above, plus rollback decision tree
- **Handoff failure incident response** — when Test 33 fails in production, how to diagnose (logs, JWT introspection, Knobby web ↔ Keycloak coordination)
- **Replay cache flush** — only needed if the cache gets poisoned somehow (rare; documented as a defensive measure)

These don't exist yet — create them as operational needs surface.

---

## 13. SPI-specific threat model (extends PRD §16.10)

Threats that arise from being SPI code running inside Keycloak's JVM:

| Threat | Defense |
|---|---|
| Code bug exposes Keycloak session state to attackers | Code review of all SPI changes; minimize surface (don't expose any custom endpoints other than the picker callback) |
| Malicious admin can configure the SPI in unintended ways | The SPI has zero admin-console configuration parameters; nothing for an admin to misconfigure |
| HMAC key leaked via logs / errors | Strict logging rules (§8 — never log raw token, never log HMAC key); env var sourced only from Secret Manager |
| Replay cache poisoning (DoS via filling cache with garbage jtis) | Bounded LRU (max 10000 entries); attacker needs to actually pass HMAC validation first to consume cache entries |
| Compromised Keycloak JVM extracts HMAC key from memory | Out of scope for this SPI — if Keycloak is compromised, the entire IdP is compromised; defense is infrastructure-level (Cloud Run / Hetzner hardening) |
| SPI version mismatch with Knobby web (different JWT claim semantics) | Two repos coupled by SPI version; release notes document any contract changes; integration test catches structural drift in CI |

Code review checklist for SPI PRs:
- [ ] No new dependencies (unless justified)
- [ ] No new logging that could expose PII or secrets
- [ ] No new admin-console configuration parameters
- [ ] Tests added for any new behavior
- [ ] Integration test still passes
- [ ] HMAC key handling unchanged unless intentional

---

## 13a. Planned providers (deferred — spec-level, not yet built)

Additional SPI providers that belong in this same Maven module / JAR but are **deferred** to the DCR-hardening phase (see `DEFERRED_ITEMS.md` B1). Documented here at spec level so they're a known design element, not a future rediscovery. They reuse the exact packaging and build pipeline as the tenant-picker authenticator (§11) — a factory + provider + `META-INF/services` entry in the existing module; no new infrastructure.

### 13a.1 `AllowedGrantTypesPolicy` (Client Registration Policy SPI)

**Status:** deferred to DCR-hardening phase. **Not currently a security gap** — ROPC is already blocked by the disabled realm Direct Grant flow (setup guide D.10), verified by smoke Test 23. This provider adds *fail-at-registration ergonomics* and broader grant/auth-method enforcement over that already-working control.

**Problem it solves.** Standard Keycloak client policies have **no executor that rejects a DCR registration for its requested `grant_types`.** The `mcp-hardening` executors constrain authorize/response-type behavior, not registration grant types. So a DCR registration requesting `password` returns 201 (the client just can't *use* ROPC once the Direct Grant flow is disabled). A custom `ClientRegistrationPolicy` closes this by rejecting the registration outright with a 400.

**Why the CRP SPI (not a Client Policies executor).** The `ClientRegistrationPolicy` SPI is registration-specific and is the same family as the built-in `allowed-client-scopes` / `trusted-hosts` policies already in use for MCP DCR. "Allowed grant types at registration" is exactly what CRPs are for. (A custom `ClientPolicyExecutorProvider` on the `REGISTER`/`UPDATE` events is the alternative; the CRP is the cleaner fit and packages identically to the existing MCP CRPs.)

**Interface shape:**
```java
public class AllowedGrantTypesPolicy implements ClientRegistrationPolicy {
    // MCP clients: authorization_code + refresh_token only. No ROPC, implicit,
    // or client_credentials for anonymous public DCR clients.
    private static final Set<String> ALLOWED_GRANTS =
        Set.of("authorization_code", "refresh_token");

    @Override
    public void beforeRegister(ClientRegistrationContext ctx)
            throws ClientRegistrationPolicyException {
        ClientRepresentation client = ctx.getClient();
        rejectDisallowed(client);
    }

    @Override
    public void beforeUpdate(ClientRegistrationContext ctx, ClientModel existing)
            throws ClientRegistrationPolicyException {
        rejectDisallowed(ctx.getClient());   // same guard on update
    }

    private void rejectDisallowed(ClientRepresentation client)
            throws ClientRegistrationPolicyException {
        if (Boolean.TRUE.equals(client.isDirectAccessGrantsEnabled())) {
            throw new ClientRegistrationPolicyException(
                "Direct access grants (password/ROPC) not permitted for DCR clients");
        }
        if (Boolean.TRUE.equals(client.isImplicitFlowEnabled())) {
            throw new ClientRegistrationPolicyException(
                "Implicit flow not permitted for DCR clients");
        }
        if (Boolean.TRUE.equals(client.isServiceAccountsEnabled())) {
            throw new ClientRegistrationPolicyException(
                "Client credentials / service accounts not permitted for public DCR clients");
        }
        // OIDC DCR also carries grant_types in the registration payload; if present,
        // reject any not in ALLOWED_GRANTS. (Read via the OIDC client-registration
        // context / client attributes as exposed by the Keycloak version.)
    }

    // afterRegister / afterUpdate: no-op.
}
```
Plus `AllowedGrantTypesPolicyFactory implements ClientRegistrationPolicyFactory` (providerId e.g. `knobby-allowed-grant-types`) and a `META-INF/services/org.keycloak.services.clientregistration.policy.ClientRegistrationPolicyFactory` entry. Wired as an **anonymous** Client Registration Policy (same subType as `allowed-client-scopes`), so it only governs anonymous DCR — never first-party clients.

**Scope creep it should absorb (build once, enforce broadly).** When built, this is the natural home for the *whole* registration-time grant/auth posture, not just password:
- forbid `implicit`, `client_credentials` on public clients (above);
- enforce `token_endpoint_auth_method=none` (public + PKCE) for MCP DCR clients;
- optionally pin `response_types` to `code`.
Consolidating these here keeps registration-time policy in one provider rather than scattered.

**Maintenance cost (the reason it's deferred).** This is a *second* SPI, doubling the Keycloak-version-coupling surface (every major Keycloak upgrade is a "does it still compile against the API" checkpoint — a cost already felt with the tenant-picker SPI). The `ClientRegistrationPolicy` API is relatively stable, but it's still surface. Deferring is correct while the disabled Direct Grant flow already provides the security property and MCP clients (code+PKCE) trip neither mechanism.

**Trigger to build:** the DCR-hardening milestone — same as re-adding Trusted Hosts (§F.1) and Allowed Protocol Mapper Types (§F.2), before untrusted third-party DCR / public GA. Build it alongside those as one hardening pass. Tracked in `DEFERRED_ITEMS.md` B1.

**Verification when built:** smoke Test 23 already accepts a registration-outright-rejection (400/403) as the *strongest* pass state — so once this provider is deployed, Test 23 should flip from "registered 201 but ROPC unusable" to "registration rejected outright," with no test change needed.

---

## 14. Open questions for the implementer

These came up during design but need code-level decisions:

1. **Suspended flow resumption pattern.** The exact API for "Authenticator suspends, RealmResourceProvider resumes" requires careful reading of Keycloak's `AuthenticationProcessor`. Study the IdP first-broker-login flow for a working example before writing the resume logic.

2. **Clock skew tolerance.** Currently §6.4 allows up to 60 seconds future-dated. Is that the right value? Match Keycloak's own JWT validation tolerance.

3. **Failure UX from the user's perspective.** When the picker-result token is invalid, the user gets a generic HTTP 400. Should we redirect them somewhere prettier (e.g., Knobby web's error page)? Probably yes — propose a follow-up improvement.

4. **Multi-realm support.** The current design assumes one realm per environment (`knobby-prod`, `knobby-dev`, etc.). The SPI's resource provider mounts at `/realms/{realm}/mcp-picker-callback`, so it works per-realm automatically. No changes needed.

5. **Test realm import file.** §10.2 mentions a `test-realm.json` for the integration tests. Need to produce one matching the production realm's MCP-relevant configuration (scopes, flow, policies).

---

## 15. References

### Specs (in `specs/`)
- `KEYCLOAK_AUTH_PRD.md` §16 — MCP support contract this SPI satisfies
- `KEYCLOAK_AUTH_PRD.md` §16.8 — the architecture this implementation specifies
- `KNOBBY_WEB_MCP_ENDPOINTS.md` — the Knobby web side of the cross-system handoff
- `KEYCLOAK_THEMING_GUIDE.md` — companion theming spec (parked)

### Repo scripts (at repo root)
- `build.sh` — orchestrates SPI build + Docker image build
- `test.sh` — runs Maven verify in `src/providers/`
- `push.sh` / `deploy.sh` — image deploy flow
- `smoke.sh` — post-deployment Keycloak realm/MCP smoke tests

### External
- Keycloak Server Development Guide (extension SPIs): https://www.keycloak.org/docs/latest/server_development/
- Keycloak source tree IdP first-broker-login flow: reference example of authenticator suspend/resume
- Maven Keycloak SPI examples: https://github.com/keycloak/keycloak-extensions-demo
- Testcontainers Keycloak: https://github.com/dasniko/testcontainers-keycloak
