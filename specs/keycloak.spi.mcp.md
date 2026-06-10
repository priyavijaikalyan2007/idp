# Keycloak MCP SPI — Implementation Design

Companion to `KEYCLOAK_AUTH_PRD.md` §16.8. The PRD specifies the architecture and contract; this document specifies *how* to implement that contract — file layout, build setup, class skeletons, error handling, testing.

**Document version:** v0.4 — per-realm HMAC keys (env-var convention `KNOBBY_MCP_HANDOFF_HMAC_KEY__<REALM>`) and per-realm `knobby.web.host` Authenticator config, replacing the prior single-instance env vars. One Keycloak instance serves three realms (`knobby-prod`, `knobby-dev`, `knobby-test`); single global keys/hosts would defeat env isolation and routing.

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

    4. realmName = context.getRealm().getName()
       authConfig = context.getAuthenticatorConfig()
       if authConfig is null or isBlank(authConfig.getConfig().get("knobby.web.host")):
           log.errorf("Authenticator config missing knobby.web.host realm=%s", realmName)
           context.failure(INTERNAL_ERROR, "MCP picker not configured for this realm")
           return
       knobbyWebHost = authConfig.getConfig().get("knobby.web.host")

       try:
           signed_token = signer.sign(picker_request, realmName)
       catch McpSpiConfigException e:
           log.errorf("HMAC key not configured realm=%s code=%s", realmName, e.getCode())
           context.failure(INTERNAL_ERROR, "MCP picker not configured for this realm")
           return

       redirect_url = "https://" + knobbyWebHost + "/mcp/consent?token=" + URL_encode(signed_token)
       // Both knobbyWebHost (per-realm Authenticator config) and the HMAC key
       // (per-realm env var KNOBBY_MCP_HANDOFF_HMAC_KEY__<REALM>) vary by realm.
       // See §7 for the configuration model.

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
- `isConfigurable()` → `true`  (per-realm `knobby.web.host`)
- `getConfigProperties()` → one entry:
  ```
  new ProviderConfigProperty(
      "knobby.web.host",                                        // name (config key)
      "Knobby web host",                                        // label
      "Hostname Knobby web serves /mcp/consent at, for this " + // help text
          "realm. No scheme, no trailing slash. " +
          "E.g., 'prod.knobby.io' in knobby-prod, " +
          "'dev.knobby.io' in knobby-dev. " +
          "The Authenticator constructs https://<host>/mcp/consent?token=...",
      ProviderConfigProperty.STRING_TYPE,
      null                                                      // no default — required per realm
  )
  ```
  Per-realm because one Keycloak instance serves multiple Knobby web hosts (knobby-prod → prod.knobby.io, knobby-dev → dev.knobby.io, knobby-test → ...). See §7.3.
- `getRequirementChoices()` → `[REQUIRED]` (no other options make sense for this step)
- `isUserSetupAllowed()` → `false`
- `getHelpText()` → `"Redirects MCP-client auth flows to Knobby web for tenant picker and consent. Required final step of browser-mcp-tenant-pick flow. Configure knobby.web.host per realm."`
- `create(KeycloakSession session)` → `new McpTenantPickerAuthenticator()`
- `init(Config.Scope config)` → enumerate `System.getenv()` entries matching `KNOBBY_MCP_HANDOFF_HMAC_KEY__*` and log the set of realms with keys configured (operator visibility at startup; see §7.2). No per-realm validation here — env vars are read lazily on first request through each realm.
- `postInit(...)`, `close()` → no-op for this SPI

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

Pseudocode:
```
@GET
@Path("/")
public Response handleCallback(@QueryParam("picker_result") String pickerResult)

    1. if pickerResult is null or empty:
           return badRequest("missing_token")

    2. try:
           tokenObj = HandoffTokenValidator.validate(
               pickerResult,
               expected_audience="keycloak-mcp-spi",
               expected_issuer="knobby-web-mcp-consent"
           )
       catch HandoffValidationException e:
           log.warn("Picker-result validation failed: {}", e.getCode())
           return badRequest("invalid_handoff", e.getCode())

    3. // Resume the suspended authentication flow.
       // Keycloak stores authentication sessions keyed by a cookie or query param
       // we need to retrieve the right one. The picker_request_jti claim in the
       // picker-result token correlates back to the original session.
       authSession = findAuthSessionByJti(tokenObj.pickerRequestJti)
       if authSession is null:
           return badRequest("session_not_found")

    4. currentUser = session.users().getUserById(realm, authSession.getAuthenticatedUserId())
       if currentUser == null || !currentUser.getId().equals(tokenObj.userSubEcho):
           log.warn("Picker-result user mismatch: session={} echo={}",
                    currentUser?.getId(), tokenObj.userSubEcho)
           return badRequest("user_mismatch")

    5. // Write session notes that protocol mappers will read.
       authSession.setUserSessionNote("knobby_tenant_id", tokenObj.chosenTenantId)
       authSession.setUserSessionNote("knobby_scopes", String.join(" ", tokenObj.grantedScopes))

    6. log.info("Picker-result accepted for user={} tenant={} scopes={}",
                currentUser.getId(), tokenObj.chosenTenantId,
                tokenObj.grantedScopes)

    7. // Resume the authentication flow. This step requires invoking Keycloak's
       // AuthenticationProcessor to continue from where the Authenticator suspended.
       // The exact API for "resume from suspended state" requires consulting the
       // Keycloak SDK; the pattern is:
       //   - Mark the Authenticator's execution as SUCCESS in the auth session
       //   - Redirect the browser back to Keycloak's standard authentication flow
       //     entry point, which will pick up where we left off
       processor = new AuthenticationProcessor()
           .setSession(session)
           .setRealm(realm)
           .setAuthenticationSession(authSession)

       // Set the Authenticator execution as success
       executionId = findExecutionId(authSession, McpTenantPickerAuthenticatorFactory.PROVIDER_ID)
       authSession.setExecutionStatus(executionId, ExecutionStatus.SUCCESS)

       return processor.continueAuthentication()
       // ^ pseudocode for "let Keycloak finish the flow now"
```

**Important implementation note:** the exact mechanics of "suspend authentication flow, resume from a different endpoint" require careful reading of Keycloak's `AuthenticationProcessor` and `AuthenticationFlowContext` internals. There are working examples in the Keycloak source tree (e.g., the IdP first-broker-login flow does similar suspend/resume). The implementer should study those before writing the resume logic from scratch.

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

---

## 6. JWT handoff implementation

### 6.1 PickerRequestToken POJO

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
- Sign POJOs into HS256 JWTs using the current HMAC key **for the active realm**.
- Source the HMAC key from `McpSpiConfig`, which reads the realm-scoped env var (§7.1).
- Cache decoded key bytes per realm to avoid repeated env-var reads and base64 decoding.

Pseudocode:
```
class HandoffTokenSigner:
    private final McpSpiConfig config;
    private final ConcurrentMap<String, byte[]> currentKeyByRealm;

    HandoffTokenSigner(McpSpiConfig config):
        this.config = config
        this.currentKeyByRealm = new ConcurrentHashMap<>()

    String sign(Object payload, String realmName) throws McpSpiConfigException:
        byte[] key = currentKeyByRealm.computeIfAbsent(realmName,
            r -> base64Decode(config.handoffHmacKey(r)))    // throws McpSpiConfigException if absent/malformed

        // Use Keycloak's bundled JWS infrastructure — do NOT hand-roll base64url
        // or HMAC. The runtime already ships these and they are battle-tested.
        return new JWSBuilder()
            .type("JWT")
            .jsonContent(payload)
            .hmac256(key);
```

Implementation notes:
- Use `org.keycloak.jose.jws.JWSBuilder` and `org.keycloak.crypto.hash.MacAlgorithmProvider` (or equivalent — confirm exact API surface against Keycloak 26.6 source). Do **not** introduce Nimbus or any external JOSE library; the runtime's own classes are sufficient.
- `config.handoffHmacKey(realmName)` resolves `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` where `<R>` is the realm name uppercased with `-`→`_` (§7.1). Validation (present, valid base64, 32 bytes) lives in `McpSpiConfig`; signer is purely a consumer.
- The cache is unbounded by design — bounded by the number of realms (3 today; never expected to exceed ~10). No eviction needed.

### 6.4 HandoffTokenValidator

Responsibilities:
- Verify signature against the **active realm's** current key (or previous key during rotation).
- Verify `iss`, `aud`, `exp`, `iat`.
- Check `jti` for replay (via ReplayCache, §6.5).
- Return parsed POJO on success; throw `HandoffValidationException` on failure.

Pseudocode:
```
class HandoffTokenValidator:
    private final McpSpiConfig config;
    private final ReplayCache replayCache;
    private final ConcurrentMap<String, byte[]> currentKeyByRealm;
    private final ConcurrentMap<String, Optional<byte[]>> previousKeyByRealm;

    HandoffTokenValidator(McpSpiConfig config, ReplayCache cache):
        this.config = config
        this.replayCache = cache
        this.currentKeyByRealm = new ConcurrentHashMap<>()
        this.previousKeyByRealm = new ConcurrentHashMap<>()

    PickerResultToken validatePickerResult(String jwt, String realmName) throws ...:
        byte[] currentKey = currentKeyByRealm.computeIfAbsent(realmName,
            r -> base64Decode(config.handoffHmacKey(r)))
        Optional<byte[]> previousKey = previousKeyByRealm.computeIfAbsent(realmName, r -> {
            String v = config.handoffHmacKeyPrevious(r)         // null if not set
            return v == null ? Optional.empty() : Optional.of(base64Decode(v))
        })
        // NB: previousKey cache is NOT invalidated when env var disappears post-rotation.
        // Acceptable because removing _PREVIOUS env var coincides with a container redeploy,
        // which restarts the JVM and rebuilds the cache.

        // Use Keycloak's bundled JWS verification — do NOT hand-roll signature checks.
        JWSInput parsed = new JWSInput(jwt)               // throws if structurally malformed
        if !HMACProvider.verify(parsed, currentKey):
            if previousKey.isEmpty() || !HMACProvider.verify(parsed, previousKey.get()):
                throw HandoffValidationException(BAD_SIGNATURE)

        PickerResultToken payload = parsed.readJsonContent(PickerResultToken.class)

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

        // Replay check (global cache — UUID v4 jti collision across realms is astronomically
        // unlikely; per-realm cache adds no security and complicates the implementation).
        if !replayCache.tryConsume(payload.jti, payload.exp):
            throw HandoffValidationException(REPLAY)

        return payload
```

The callsite in §5.3 step 2 passes `realm.getName()` derived from the JAX-RS path parameter `{realm}`:
```
tokenObj = validator.validatePickerResult(pickerResult, realm.getName())
```

A `picker_result` captured from `knobby-prod` and replayed against `/realms/knobby-dev/mcp-picker-callback` fails at signature verification because each realm holds a distinct HMAC key. This is the cross-realm isolation that motivates per-realm keys.

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

This SPI is configured in two layers:

| Layer | Holds | Per | Storage | Sensitive? |
|---|---|---|---|---|
| Per-realm environment variables | HMAC key(s) for signing and validating picker-request / picker-result JWTs | Realm | Cloud Run env, backed by GCP Secret Manager | Yes — never enters the Keycloak DB |
| Per-realm Authenticator config (admin console) | Knobby web hostname for this realm's `/mcp/consent` endpoint | Realm | Keycloak realm DB / realm export | No |

**Rationale.** One Keycloak instance serves three realms (`knobby-prod`, `knobby-dev`, `knobby-test`). A single global HMAC key shared across realms would mean: dev Knobby web's HMAC key, if exfiltrated, could mint a valid `picker_result` carrying any `chosen_tenant_id`/`grantedScopes`, POST it to `/realms/knobby-prod/mcp-picker-callback`, and have it pass signature validation. Per-realm keys close that path. The web host, by contrast, is non-sensitive routing config and lives most naturally next to the realm's flow definition in the admin console (where it is also captured by realm export).

### 7.1 Per-realm environment variables

For each realm `R` that uses the MCP SPI, set the following on the Keycloak container. The suffix `<R>` is the realm name uppercased with `-` replaced by `_` (e.g., `knobby-prod` → `KNOBBY_PROD`). The double-underscore separator (`__`) makes the boundary between the fixed prefix and the realm suffix unambiguous when parsing env-var names.

| Variable | Required? | Description |
|---|---|---|
| `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` | Yes (per realm using the SPI) | Current HMAC key for realm `R`, base64-encoded 32 bytes (256 bits). Standard base64 (not URL-safe). Used for signing picker-request and validating picker-result tokens within this realm. |
| `KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__<R>` | Only during rotation for realm `R` | Previous HMAC key for realm `R`. When set, the validator accepts tokens signed with either current or previous. Removed once all in-flight tokens have expired (15-minute overlap window — see `keycloak-hmac-operations-guide.md` §4). |

Expected env vars for the three realms:

```
KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD            ← required when knobby-prod uses the SPI
KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_DEV             ← required when knobby-dev uses the SPI
KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_TEST            ← required when knobby-test exists and uses the SPI
```

A realm that does not use the MCP SPI requires no env var. Resolution is lazy: env vars are read on the first request through the realm, not at startup, so the absence of an unused realm's env var is not an error.

### 7.2 Startup behavior and lazy resolution

`McpSpiConfig` is lazy by design — the SPI does not enumerate which realms exist at JVM startup (realms come and go independently of the SPI deployment cycle). Validation happens in two places:

**At startup (`AuthenticatorFactory.init`):** scan `System.getenv()` for keys matching the pattern `KNOBBY_MCP_HANDOFF_HMAC_KEY__*` and log the set of realms with HMAC keys configured. Single line, operator-visible:

```
INFO Loaded MCP SPI provider knobby-mcp-tenant-picker.
     HMAC keys configured for realms: [knobby-prod, knobby-dev]
     (knobby-test absent — that realm will not be able to use the MCP SPI until configured)
```

The startup scan does **not** decode or validate key values — that would require holding decoded keys in memory longer than necessary. It only confirms env-var presence.

**On first request through realm `R`:** `McpSpiConfig.handoffHmacKey(realmName)` resolves the env var, validates it (present, valid standard base64, decodes to exactly 32 bytes), and caches the validated string in the signer/validator. Failures throw `McpSpiConfigException` with a code:

| Code | Trigger |
|---|---|
| `MISSING_HMAC_KEY` | `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` not set |
| `MALFORMED_BASE64` | Value is not valid standard base64 (URL-safe base64 also rejected) |
| `WRONG_KEY_LENGTH` | Value decodes to ≠ 32 bytes |

The Authenticator catches `McpSpiConfigException` and fails the flow with a literate error (§8). The first such failure surfaces immediately on the first MCP login test through the misconfigured realm — well before any external user sees it.

```
class McpSpiConfig:
    private static final String ENV_KEY_PREFIX = "KNOBBY_MCP_HANDOFF_HMAC_KEY__";
    private static final String ENV_KEY_PREVIOUS_PREFIX = "KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__";

    String handoffHmacKey(String realmName) throws McpSpiConfigException:
        String envName = ENV_KEY_PREFIX + normalize(realmName)   // knobby-prod → KNOBBY_PROD
        String value = System.getenv(envName)
        if isBlank(value):
            throw new McpSpiConfigException(MISSING_HMAC_KEY, envName)
        try:
            byte[] bytes = Base64.getDecoder().decode(value)
            if bytes.length != 32:
                throw new McpSpiConfigException(WRONG_KEY_LENGTH, envName, bytes.length)
        catch IllegalArgumentException e:
            throw new McpSpiConfigException(MALFORMED_BASE64, envName)
        return value

    String handoffHmacKeyPrevious(String realmName):
        // Returns null if not set — that is the steady-state case, not an error.
        String envName = ENV_KEY_PREVIOUS_PREFIX + normalize(realmName)
        String value = System.getenv(envName)
        return isBlank(value) ? null : value
        // Caller validates length/base64 the same way as current — extract a private helper.

    private static String normalize(String realmName):
        return realmName.toUpperCase(Locale.ROOT).replace('-', '_')
```

The web host is **not** read by `McpSpiConfig` — it is read from `AuthenticatorConfigModel` in `McpTenantPickerAuthenticator.authenticate()` (§5.1 step 4). Keep concerns separate: env vars hold secrets; admin-console config holds routing.

### 7.3 Per-realm Authenticator configuration: `knobby.web.host`

Surfaced by `McpTenantPickerAuthenticatorFactory.getConfigProperties()` (§5.2). The admin console exposes it on the `browser-mcp-tenant-pick` flow's execution config for the Authenticator step.

| Property | Type | Required | Description |
|---|---|---|---|
| `knobby.web.host` | String | Yes | Hostname Knobby web serves `/mcp/consent` at, for this realm. No scheme, no trailing slash. Per-realm convention: `prod.knobby.io` for `knobby-prod`, `dev.knobby.io` for `knobby-dev`, `test.knobby.io` (or a local equivalent) for `knobby-test`. |

Captured by realm export — re-applying a realm export reinstates this value. The Authenticator hard-fails the flow with a literate error (§8) if `knobby.web.host` is unset for the active realm. This catches the "new realm created without finishing the flow config" case before any user-visible damage.

Operational note: when adding a new realm, the order is (1) create the realm and import its config, (2) set `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` in Cloud Run, (3) verify `knobby.web.host` is set on the Authenticator execution. The smoke suite (`./smoke.sh`) Test 15 confirms the SPI Authenticator is wired into the flow but does not validate config presence; an extension to smoke is recommended (see `keycloak-hmac-operations-guide.md` §6).

### 7.4 Replay cache configuration

Currently hardcoded in `ReplayCache` (maxSize=10000, maxAgeSeconds=600). Single cache across all realms — UUID v4 jti collisions across realms are astronomically unlikely, and the cache is per Keycloak JVM. If tuning is ever needed, expose via env vars.

---

## 8. Error handling

### Error categories

| Category | Triggers | User-facing response | Logging |
|---|---|---|---|
| Realm configuration error | Missing `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>`, malformed key, or missing `knobby.web.host` Authenticator config for the active realm | Authentication flow fails with `access_denied`; user sees Keycloak's standard error page | ERROR with realm name and code (`MISSING_HMAC_KEY`, `MISSING_WEB_HOST`, `MALFORMED_BASE64`, `WRONG_KEY_LENGTH`). Never log raw key material. |
| Authenticator misuse | `action()` called unexpectedly | OAuth flow fails with `access_denied` | WARN with context |
| Picker-result validation failure | HMAC mismatch, expired, replay, user mismatch | HTTP 400 JSON `{"error": "invalid_handoff", "error_description": "..."}` | WARN with category code, realm name, jti — no PII |
| Session not found | Auth session expired before user returned | HTTP 400 JSON `{"error": "session_not_found"}` | WARN |
| Internal error (uncaught exception) | Bug | HTTP 500 generic | ERROR with stack trace |

Two exception types separate config errors from validation errors:
- `McpSpiConfigException` — thrown by `McpSpiConfig` when env vars are missing/malformed for a realm, or by the Authenticator when `knobby.web.host` is unset. Codes: `MISSING_HMAC_KEY`, `MISSING_WEB_HOST`, `MALFORMED_BASE64`, `WRONG_KEY_LENGTH`.
- `HandoffValidationException` — thrown by `HandoffTokenValidator` on JWT validation failures. Codes per §6.4.

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
        // Test realm name in test-realm.json is "knobby-test-it" (kept distinct from
        // the real knobby-test environment realm to avoid accidental conflation).
        // knobby.web.host for this realm is set inside test-realm.json itself
        // (as Authenticator config), not via env var.
        .withEnv("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_TEST_IT", BASE64_TEST_KEY);

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
