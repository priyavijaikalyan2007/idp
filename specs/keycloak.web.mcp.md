# Knobby Web — MCP Endpoints Specification

Companion to `KEYCLOAK_AUTH_PRD.md` §16 and the brainstorm output `keycloak_mcp.md`. This document specifies what Knobby web needs to build to support the MCP path (iii) handoff and the Connected Agents UX.

**Document version:** v0.1 — initial draft, ready for implementation start.

---

## 1. Scope

### What this document covers

- All HTTP routes Knobby web exposes under `/mcp/*`, `/api/mcp/*`, `/api/connected-agents/*`, and `/.well-known/oauth-protected-resource`
- The 3-step consent wizard UI specification
- The Connected Agents user-menu entry and tenant-admin view
- Backend services supporting the wizard (token validation, generation, tenant lookup, RBAC membership check)
- Session establishment for `/mcp/consent` via silent OIDC bootstrap
- The `PermissionMappingRegistry.AccessLevelInfo` extension for affirmative/negative-list generation
- Authentication and authorization patterns
- Threat model and defenses

### What this document does NOT cover

- The Keycloak SPI implementation (see `KEYCLOAK_MCP_SPI_DESIGN.md`)
- Realm configuration (see `KEYCLOAK_AUTH_PRD.md` §16.11)
- knobby.io's MCP server (resource server) implementation — that's tracked in the MCP PRD as a separate work track
- Component-level UI design (assumes reuse of existing Knobby design system; specifics deferred to design pairing sessions)

### Inherited contract from Keycloak PRD §16

- The path (iii) consent flow (§16.7.2) — Knobby web is the consent UX layer
- The 3-step wizard structure (§16.7.3)
- Empty-membership state branching (§16.7.4)
- Connected Agents UX (§16.7.5)
- Trust signals / anti-phishing (§16.7.6)
- Picker-request and picker-result JWT claim sets (§16.8.5)
- HMAC handoff key contract (§16.8.5)
- The 6 atomic scopes + 5 bundles (§16.3)

---

## 2. Routes

All routes under the Knobby web app. Hostname per environment: `prod.knobby.io`, `dev.knobby.io`, `localhost:5173` (or whatever the dev port is).

### 2.1 `GET /mcp/consent`

The 3-step consent wizard entry point. The Keycloak SPI Authenticator redirects the browser here after federation completes.

**Query parameters:**
- `token` (required) — the picker-request JWT from the SPI

**Authentication:**
- Requires Knobby web session cookie. If not present, the auth middleware initiates a silent OIDC bootstrap (§3.1). This is automatic and transparent to the user — the middleware handles it before the route handler runs.

**Behavior:**
1. The auth middleware ensures a Knobby web session is established (silent bootstrap if needed).
2. The route handler reads the `token` query param.
3. Token is validated server-side (HMAC, expiry, jti for replay) — see §4.1.
4. Token claims are extracted: `mcp_client_id`, `mcp_requested_scopes`, `oauth_state`, `knobby_sub`.
5. The current Knobby web session user is fetched; their `sub` must match `knobby_sub` in the token (defense-in-depth for session fixation; see §11).
6. The wizard state is initialized: client identity card data is built from the DCR-registered client metadata (fetched from Keycloak Admin API), user's tenant memberships are loaded, RBAC membership confirmed.
7. The wizard component renders Step 1.

**Response:**
- Full Knobby app shell with the wizard component at `/mcp/consent`
- The picker-request token is held in server-side session state for the duration of the wizard (not exposed to client JS)

**Empty-membership detection:**
- After step 6, if the user has zero tenant memberships, branch to the empty-membership state per §2.1.1.

**Errors:**
- Invalid/expired/replay token → render error page: "This consent link is no longer valid. Return to your MCP client and try connecting again." HTTP 400 status.
- User sub mismatch → render error page: "Your account doesn't match the authentication request. Sign out and try again." HTTP 403.
- Other backend errors → generic error page, HTTP 500.

### 2.1.1 Empty-membership branches

When the wizard determines (step 6 above) the user has no tenant memberships, the page halts at Step 1 with no Continue action. Two messaging branches based on context (detected by §5.2 logic):

**Case A — user's email domain matches a connected tenant but no membership yet:**

UI message: *"Your domain ({acme.corp}) is connected to knobby.io, but you haven't been added as a member yet. Please ask your administrator to invite you, then return here to connect {client name}."*

Optional UI element: button "Email my administrator" → opens mailto: with template.

**Case B — no domain match:**

UI message: *"You need a knobby.io workspace to use {client name} with knobby.io."*

Buttons: `[Create a workspace]` → opens normal sign-up flow in new tab. `[Cancel]` → returns to the wizard with no consent action.

**In both cases:**
- No `[Continue]` button is shown.
- No picker-result token is ever emitted.
- The Keycloak SPI's Authenticator step times out after 5 minutes (matching picker-request expiry); the OAuth flow at Keycloak fails with `access_denied`.
- The user can come back later (after admin invites them, or after they create a workspace) and re-initiate the MCP client's connect flow; a fresh picker-request will be generated.

### 2.2 `POST /api/mcp/consent/authorize`

The final step of the wizard. The user clicks `[Authorize]` on Step 3; this endpoint accepts their selections, validates everything, generates the picker-result JWT, and returns the redirect URL to Keycloak's callback endpoint.

**Authentication:**
- Requires Knobby web session cookie
- CSRF token validated

**Request body:**
```json
{
  "picker_request_jti": "<jti from the original picker-request token, for correlation>",
  "chosen_tenant_id": "<UUID>",
  "granted_scopes": ["knobby:read", "knobby:comment", ...]
}
```

**Behavior:**
1. Validate CSRF.
2. Validate the picker-request is still active (look it up in server-side session state from §2.1).
3. Re-validate user membership in `chosen_tenant_id` (defense in depth — RBAC may have changed since Step 1).
4. Validate `granted_scopes` ⊆ allowed scopes for this user's role in this tenant (a tenant admin may have configured maximum scopes per role; granted ≤ allowed).
5. Construct picker-result JWT per Keycloak PRD §16.8.5:
   ```
   {
     "iss": "knobby-web-mcp-consent",
     "aud": "keycloak-mcp-spi",
     "picker_request_jti": <from session state>,
     "user_sub_echo": <current user's sub>,
     "chosen_tenant_id": <as posted>,
     "granted_scopes": <as posted>,
     "oauth_state": <from picker-request, held in session state>,
     "nonce": <128-bit random>,
     "jti": <UUID>,
     "iat": now,
     "exp": now + 60 seconds
   }
   ```
6. Sign with HMAC (current HMAC key from secret manager).
7. Construct redirect URL: `https://auth.knobby.io/realms/knobby-{env}/mcp-picker-callback?picker_result=<token>`
8. Clear server-side session state for this wizard (the picker-request is consumed).
9. Record an `AgentConnectionGranted` activity for audit (see §6).

**Response:**
```json
{ "redirect_url": "https://auth.knobby.io/realms/knobby-prod/mcp-picker-callback?picker_result=..." }
```

The client-side wizard then performs `window.location = redirect_url`.

(Alternative: return HTTP 303 See Other with `Location: <redirect_url>` and let the browser redirect on form POST. This works for non-JS clients. Implement based on the wizard's existing patterns.)

**Errors:**
- CSRF failure → 403
- Picker-request expired or session lost → 410 Gone with message "This consent session has expired. Return to your MCP client and try connecting again."
- User no longer member of chosen tenant → 403 with "Your access to this tenant has changed since you began. Please reload and try again."
- Granted scopes exceed max for user's role → 403 with "Your role doesn't permit granting these capabilities."

### 2.3 `POST /api/mcp/consent/cancel`

The user clicks `[Cancel — Don't Connect]` at any step.

**Behavior:**
1. Validate CSRF.
2. Clear server-side session state for the wizard.
3. Optionally: emit a signed cancel-result JWT back to Keycloak so the SPI can short-circuit the auth flow with `access_denied` immediately rather than waiting for the 5-minute timeout. This requires a corresponding endpoint at Keycloak; if not implemented, the SPI just times out, and the user sees a clean cancel page on Knobby's side.

**Response:**
- Renders a "Cancelled — you can close this tab" confirmation page.

### 2.4 `GET /.well-known/oauth-protected-resource`

RFC 9728 — Protected Resource Metadata. MCP clients fetch this to discover which authorization server protects knobby.io's MCP server.

**Authentication:** None (this is a discovery endpoint and must be publicly readable).

**Response:**
```json
{
  "resource": "https://prod.knobby.io/mcp",
  "authorization_servers": [
    "https://auth.knobby.io/realms/knobby-prod"
  ],
  "bearer_methods_supported": ["header"],
  "scopes_supported": [
    "knobby:read",
    "knobby:comment",
    "knobby:curate",
    "knobby:write",
    "knobby:share",
    "knobby:admin"
  ],
  "resource_documentation": "https://docs.knobby.io/mcp"
}
```

Static or dynamic — implementer's choice; the values are stable per environment. Caching: `Cache-Control: public, max-age=86400` (1 day).

### 2.5 `GET /connected-agents`

User's own connected agents page. Accessible from the user-menu (top right).

**Authentication:** Requires Knobby web session.

**Layout:** Standard Knobby app shell, page content lists the user's MCP connections (one row per granted MCP client) with:
- Client name + logo
- Tenant scope ("in {tenant name}")
- Bundle granted (e.g., "Author")
- Granted-at timestamp
- Last-activity timestamp
- `[Disconnect]` button per row

**Data source:** Aggregated from Keycloak Admin API — list the user's grants (consents) where the client has the `mcp-default` Client Scope assigned (this is how we distinguish MCP clients from non-MCP clients).

```
GET /admin/realms/{realm}/users/{user_id}/consents
```

For each consent, cross-reference with Keycloak's client list to determine which are MCP clients (via the `mcp-default` scope assignment).

### 2.6 `DELETE /api/connected-agents/:client_id`

User initiates disconnect of a single MCP client.

**Authentication:** Requires Knobby web session; user can only disconnect their own grants.

**Behavior:**
1. Validate CSRF.
2. Verify the client is actually an MCP client (has `mcp-default` scope).
3. Call Keycloak Admin API to revoke the user's consent and active sessions:
   ```
   DELETE /admin/realms/{realm}/users/{user_id}/consents/{client_id}
   ```
4. Record an `AgentConnectionRevoked` activity for audit (§6).
5. Return 204 No Content.

**Errors:**
- Client not found → 404
- Client is not MCP — refuse to disconnect via this UI → 400 (use a different endpoint for non-MCP clients)

### 2.7 `GET /tenant-admin/mcp-connections`

Tenant admin view. Lists ALL MCP grants across the tenant.

**Authentication:** Requires Knobby web session; user must have tenant-admin role in the currently-active tenant.

**Layout:** Standard Knobby tenant admin shell. Page content is a table of all MCP grants in the tenant:
- User name + email
- Client name + logo
- Bundle granted
- Granted-at, last-activity
- `[Force Disconnect]` button per row

**Data source:** Iterate the tenant's members, for each fetch their consents that involve MCP clients, aggregate.

For a large tenant this can be slow; cache aggressively. Refresh on disconnect actions.

### 2.8 `DELETE /api/tenant-admin/mcp-connections/:user_id/:client_id`

Tenant admin force-disconnects a user's MCP grant. Same Keycloak API as §2.6 but operating on another user.

**Authentication:** Requires Knobby web session; user must have tenant-admin role.

**Behavior:**
1. Validate CSRF.
2. Verify admin role.
3. Verify target user is a member of the admin's tenant.
4. Verify target client is MCP.
5. Call Keycloak Admin API to revoke.
6. Record an `AgentConnectionRevokedByAdmin` activity for audit.
7. Optionally: send notification to the affected user ("Your administrator disconnected {client name}.").
8. Return 204.

---

## 3. Authentication

### 3.1 Silent SSO bootstrap at `/mcp/consent`

When a user arrives at `/mcp/consent` after the Keycloak SPI's redirect, they may or may not have an active Knobby web session cookie. Two scenarios:

**Scenario A: user has an active Knobby web session.**
- The auth middleware sees the cookie, validates it, attaches the user to the request, and the route handler proceeds normally.
- This is the common case if the user was already using Knobby web in another tab.

**Scenario B: user has no Knobby web session (fresh browser / cookies expired).**
- The auth middleware finds no cookie.
- The middleware initiates a standard OIDC sign-in flow against the `knobby-{env}-web` client with `prompt=none` and `state=<encoded picker-request token + return URL>`.
- Because the user just completed federation in the Keycloak SPI's `browser-mcp-tenant-pick` flow, they have a fresh Keycloak SSO session. With `prompt=none`, Keycloak returns an authorization code immediately without showing any UI.
- The middleware exchanges the code for tokens, sets a Knobby web session cookie, and redirects back to `/mcp/consent?token=<picker-request-token>` (the original URL preserved via the OAuth state parameter).
- The route handler then proceeds normally.

This entire bootstrap happens in approximately 100ms with one browser redirect round-trip. The user perceives a slight pause between the IdP login and the wizard appearing — indistinguishable from normal app loading.

**Implementation notes:**

- The Knobby web auth middleware likely already supports OIDC flows for the main app. The silent bootstrap is just calling that path with `prompt=none` instead of `prompt=login`. Confirm the middleware can be invoked this way without code changes.
- If `prompt=none` fails (e.g., Keycloak SSO session expired between the SPI federation and arrival at `/mcp/consent`), the auth middleware falls back to a normal interactive sign-in. The user re-authenticates and continues — slightly worse UX but correct behavior.
- Preserve the `?token=<picker-request-token>` query parameter through the bootstrap by encoding it in OIDC `state`. The state is opaque to Keycloak and round-trips back to Knobby web on callback.

### 3.2 Picker-request token validation (server-side)

When `/mcp/consent` (§2.1) receives a picker-request token in the query param, validate it server-side:

```
1. Split JWT into header, payload, signature parts.
2. Verify HMAC-SHA256 signature against the current HMAC key from Secret Manager.
   - During key rotation, also try the previous key.
3. Validate claims:
   - iss == "keycloak-mcp-spi"
   - aud == "knobby-web-mcp-consent"
   - exp > now
   - iat <= now + 60 (allow 60s clock skew)
4. Check jti against the replay cache (Redis or in-memory bounded LRU).
   - First use: record jti with TTL = exp - now. Return success.
   - Subsequent use: reject as replay.
5. Verify knobby_sub matches the current session's authenticated user sub.
   - If mismatch: reject with USER_MISMATCH (defense in depth against session fixation).
```

All failures result in:
- HTTP 400 (or appropriate error code)
- Structured log entry with the error category (not the raw token)
- Generic user-facing error page

### 3.3 Picker-result token generation (server-side)

When `/api/mcp/consent/authorize` (§2.2) builds the picker-result token:

```
1. Generate jti (UUID v4) and nonce (128-bit random hex).
2. Build claims per Keycloak PRD §16.8.5.
3. Set iat = now, exp = now + 60s.
4. Serialize claims as JSON.
5. Construct JWT:
   - Header: {"alg":"HS256","typ":"JWT"}
   - Payload: claims JSON, base64url-encoded
   - Signature: HMAC-SHA256 of header.payload using current HMAC key, base64url-encoded
6. Return JWT as the redirect URL's picker_result query parameter.
```

**HMAC key sourcing:**
- Production: `knobby-mcp-handoff-hmac-key-{env}` from GCP Secret Manager.
- Development: env var or local config file pointing at a dev key.
- Test: a fixed key embedded in the test fixture (NOT a real key).

The same key is shared with Keycloak's SPI; both sides fetch it identically.

### 3.4 Replay cache

Same shape as the SPI's replay cache (`KEYCLOAK_MCP_SPI_DESIGN.md` §6.5):
- Maps jti → expiry.
- Lazy eviction on access.
- Bounded size.
- TTL = max token lifetime (5 min for picker-request, 1 min for picker-result; use 5 min as the upper bound).

**Storage:**
- Single-instance deployment: in-memory map is sufficient.
- Multi-instance deployment: back with Redis (knobby.io already uses Redis per the platform notes).

---

## 4. Wizard implementation

### 4.1 Step 1 — Who & Where (client identity + tenant confirmation)

**UI components:**
- Client identity card (top, prominent):
  - Client name (from DCR metadata `client_name`)
  - Client URI / domain extracted from redirect URI
  - "Self-registered" badge with hover tooltip explaining what self-registration means
  - Generic placeholder logo (DCR clients don't have uploaded logos; future hardening: client verification badge with logo)
- Tenant card:
  - Tenant logo + name
  - User's role in this tenant
  - Last activity timestamp (when the user last interacted with this tenant)
  - Member count
  - **Always shown for explicit confirmation**, even for single-tenant users
- For multi-tenant users: radio list, tenant cards stacked

**Actions:**
- `[Continue]` (disabled until a tenant is selected) → advances to Step 2
- `[Cancel — Don't Connect]` → calls §2.3 cancel endpoint

**Empty-membership state:** see §2.1.1.

### 4.2 Step 2 — What (bundle selection)

**UI components:**
- Heading: *"What should {client name} be able to do for you in {tenant name}?"*
- Five bundle cards stacked vertically: Viewer / Reviewer / Curator / Author / Admin
- Each card:
  - Bundle name + one-line description
  - 2-3 example actions (sourced from the PermissionMappingRegistry; see §5)
  - RBAC mirror in small text ("Like the Editor role")
  - Radio button or selectable card pattern
- Default selection: **Author**
- Expand affordance: "Show advanced (individual scopes)" — reveals 6 atom scope checkboxes; toggling any flips the bundle label to "Custom — based on {bundle}"
- Admin elevation banner: if the DCR client's `client_metadata.requested_scopes` includes `knobby:admin`, show a prominent warning banner above the cards before the user selects.

**Actions:**
- `[Continue]` → advances to Step 3
- `[Back]` → returns to Step 1, preserving Step 1's tenant selection

### 4.3 Step 3 — Review & Authorize

**UI components:**
- Heading: *"Confirm: {client name} will be able to..."*
- Affirmative list — what the user is granting (✓ items, generated from PermissionMappingRegistry)
- Negative list — what the user is NOT granting (✗ items, generated from PermissionMappingRegistry)
- Summary line: *"Connecting {client name} to {tenant name} · {Bundle name} bundle · until you disconnect."*

**Actions:**
- `[Authorize]`:
  - Visual prominence varies by bundle: standard styling for Viewer/Reviewer/Curator/Author; **extra-prominent (larger, distinct accent color)** for Admin
  - Calls `POST /api/mcp/consent/authorize` (§2.2) and on success redirects to Keycloak's callback URL
- `[Back]` → returns to Step 2, preserving Step 2's bundle selection
- `[Cancel — Don't Connect]` → calls §2.3 cancel endpoint

---

## 5. PermissionMappingRegistry extension

To generate the affirmative and negative lists in Step 3, Knobby web needs a registry of bundle → capabilities mappings. This extends the existing `PermissionMappingRegistry.AccessLevelInfo` per the brainstorm doc §3.4.

### 5.1 Schema additions

For each (Bundle, App) tuple, define:
- Affirmative actions: human-readable strings of what the bundle grants
- Negative actions: human-readable strings of what the bundle does NOT grant (relative to the next-higher bundle, or to a broader baseline)

Example representation (conceptual; concrete schema depends on the existing registry's structure):

```
{
  "bundles": {
    "Author": {
      "scopes": ["knobby:read", "knobby:comment", "knobby:curate", "knobby:write", "knobby:share"],
      "affirmative": [
        "Read any resource you have access to",
        "Comment on resources you can comment on",
        "Create, edit, and delete resources you have edit access to",
        "Share resources you own with other users in this tenant",
        "Create cross-app links between resources"
      ],
      "negative": [
        "Administer this tenant (cannot manage users or roles)",
        "Change tenant-wide settings",
        "Access audit logs",
        "Act in any tenant other than {tenant name}"
      ]
    },
    ...
  }
}
```

### 5.2 Generation rules

**Affirmative list** for a bundle: union of the affirmative actions for each scope the bundle includes, deduplicated, rendered with ✓.

**Negative list** for a bundle:
- Always includes: "Act in any tenant other than {tenant name}" (per the per-tenant-token decision)
- Includes: top capabilities from the next-higher bundle that the user is NOT granting
- For Admin bundle: negative list is mostly "nothing" — Admin has full authority within the tenant. Replace with positive framing: "This grants tenant-wide administrative access. Choose this only for highly-trusted clients."

**Source of truth:** the registry is the authoritative source; it must be reviewed alongside any RBAC role definition changes. If RBAC role definitions and registry drift, the consent screen lies. CI check should validate that every RBAC role is referenced by exactly one bundle's affirmative list.

### 5.3 Localization

For initial launch: English only. Registry stores strings in English. Future: i18n with the existing knobby.io localization infrastructure.

---

## 6. Audit events

Emit structured activity events for audit and analytics:

| Event | Trigger | Payload |
|---|---|---|
| `AgentConnectionGranted` | Successful `POST /api/mcp/consent/authorize` | user_id, tenant_id, client_id, client_name, bundle, granted_scopes |
| `AgentConnectionRevoked` | Successful `DELETE /api/connected-agents/:client_id` | user_id, tenant_id, client_id, initiator=user |
| `AgentConnectionRevokedByAdmin` | Successful `DELETE /api/tenant-admin/mcp-connections/:user_id/:client_id` | user_id, tenant_id, client_id, admin_user_id |
| `AgentConsentCancelled` | `POST /api/mcp/consent/cancel` (informational) | user_id, tenant_id_attempted, client_id |
| `AgentConsentFailed` | Validation failures during the wizard (token invalid, user mismatch, etc.) | user_id, error_category, jti |

These flow into the platform event bus per existing knobby.io audit conventions. The audit feed for a tenant admin includes all `AgentConnection*` events for tenant visibility.

---

## 7. Backend services

Implementation layout (suggestive, follow existing knobby.io conventions):

### 7.1 `McpConsentService`

Methods:
- `validatePickerRequest(token)` → returns parsed claims or throws `HandoffValidationException`
- `signPickerResult(claims)` → returns signed JWT
- `replayCache.tryConsume(jti, expiry)` → bool
- `loadUserTenants(user)` → list of tenants with membership info
- `validateMembership(user, tenant)` → bool

### 7.2 `KeycloakAdminClient`

Encapsulates Knobby's calls to Keycloak's Admin REST API:
- `listClientByClientId(clientId)` → fetch DCR-registered client metadata for the wizard's client identity card
- `listUserConsents(userId)` → fetch grants for the Connected Agents view
- `revokeConsent(userId, clientId)` → disconnect
- `listClients(filter)` → for the tenant-admin aggregate view

Authentication: client_credentials grant as the `knobby-{env}-admin-api` service account (same as the smoke test). The service account's roles per PRD §11.13 already cover these endpoints (view-users, view-clients, manage-users).

### 7.3 `HmacKeyProvider`

Loads the HMAC key(s) from GCP Secret Manager on startup. Supports two-key overlap during rotation.

### 7.4 `AgentActivityRecorder`

Emits audit events per §6.

---

## 8. Error handling

User-facing error pages:

| Error | Page | HTTP | Recovery action |
|---|---|---|---|
| Invalid / expired picker-request token | "This consent link is no longer valid" | 400 | "Return to your MCP client and reconnect" |
| User sub mismatch | "Your account doesn't match the authentication request" | 403 | "Sign out and try again" |
| Tenant membership revoked mid-wizard | "Your access has changed" | 403 | "Reload and try again" |
| Picker-result signing failed (internal) | Generic error | 500 | "Try again in a few minutes" |
| Knobby web ↔ Keycloak network error | Generic error | 502 | "Service temporarily unavailable" |

All errors:
- Log structured event server-side with error category and (where safe) jti
- Never log raw tokens or HMAC key
- Never reveal internal stack traces to users

---

## 9. Testing

### 9.1 Unit tests

Cover:
- `McpConsentService`: token validation (HMAC, expiry, replay), token signing
- `KeycloakAdminClient`: mock Keycloak responses, verify request shape
- `HmacKeyProvider`: missing key, malformed key, rotation
- `AgentActivityRecorder`: event payload shape
- `PermissionMappingRegistry`: registry lookup, affirmative/negative list generation

### 9.2 Integration tests

- Spin up Knobby web in a test environment with a mock Keycloak Admin API
- Exercise the full wizard flow programmatically (POSTs to `/api/mcp/consent/authorize` with valid and invalid tokens)
- Verify replay rejection
- Verify membership changes mid-flow are caught

### 9.3 End-to-end tests

- Cypress / Playwright against a deployed dev environment
- Real Keycloak (dev realm), real Knobby web (dev), real DCR-registered test client
- Walk through the full flow, decode the resulting access token, verify claims
- Covered by smoke test Test 33 (manual) for now; can be automated once stable

### 9.4 Cross-system contract tests

A small set of tests that verify Knobby web and Keycloak SPI agree on the JWT contract:
- Knobby signs a picker-result; the SPI's `HandoffTokenValidator` accepts it (validates from the SPI's side)
- The SPI signs a picker-request; Knobby's `validatePickerRequest` accepts it (validates from Knobby's side)
- These run in CI as part of the SPI's integration tests (the SPI repo includes a small Knobby-style validator implementation) AND as part of Knobby's integration tests (Knobby includes a small SPI-style signer implementation)

This is the contract enforcement that prevents version-drift bugs between the two systems.

---

## 10. Configuration

### 10.1 Environment variables

| Variable | Required | Description |
|---|---|---|
| `KNOBBY_MCP_HANDOFF_HMAC_KEY` | Yes | Current HMAC key (base64-encoded 32 bytes). Same key as SPI uses. |
| `KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS` | No | Previous key during rotation |
| `KEYCLOAK_REALM_BASE` | Yes | e.g., `https://auth.knobby.io/realms/knobby-prod` |
| `KEYCLOAK_ADMIN_CLIENT_ID` | Yes | `knobby-prod-admin-api` |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | Yes | Service account secret |
| `MCP_RESOURCE_URI` | Yes | `https://prod.knobby.io/mcp` — used in `/.well-known/oauth-protected-resource` |

### 10.2 Feature flags

- `mcp.enabled` — master toggle. Until true, all MCP routes return 404 (cleanly hide the feature in environments not ready).
- `mcp.admin_consent_required_for_third_party` — future toggle to require tenant-admin approval for non-first-party DCR clients to be useable in this tenant.

---

## 11. Threat model

Knobby-web-side threats beyond what the Keycloak PRD §16.10 covers:

| Threat | Defense |
|---|---|
| User session fixation: attacker tricks user into completing consent with attacker's session | `user_sub_echo` cross-check in picker-result token; Knobby web also verifies the picker-request's `knobby_sub` matches the current session user |
| Cross-tenant leak: attacker fakes a tenant_id the user doesn't belong to | RBAC membership validated server-side at both wizard start (Step 1) and final authorize (POST /api/mcp/consent/authorize); both checks query the authoritative knobby.io data model |
| CSRF on the authorize POST | Standard CSRF token validation (assume knobby.io's existing CSRF middleware applies) |
| Wizard state tampering: user modifies tenant_id or scopes in client-side JS | Server-side state holds the picker-request token throughout the wizard; final POST re-validates everything against the authoritative state |
| HMAC key leak via knobby.io logs / errors | Key handled only by `HmacKeyProvider`; never logged; key loaded from Secret Manager with audit logging |
| Replay of picker-result emission | Server-side replay cache on picker-result jti (in addition to the SPI's own cache on its side) |
| Tenant-admin force-disconnect mistakes | Admin actions require explicit confirmation dialog ("Disconnect Claude Code for user@acme.corp?"); admin actions emit dedicated audit event |
| MCP server endpoint accepts tokens from wrong env | Knobby's MCP server validates `iss` matches expected env's realm; this is a server-side defense outside the wizard's scope |

---

## 12. Implementation order

Suggested phased delivery:

### Phase 1 — Foundation (no end-to-end yet)

- HmacKeyProvider with Secret Manager integration
- McpConsentService skeleton (validatePickerRequest, signPickerResult, replayCache)
- Unit tests
- Auth migration to Keycloak completed (prerequisite per `KEYCLOAK_AUTH_PRD.md` §16.1.5)

### Phase 2 — Routes and backend

- `GET /.well-known/oauth-protected-resource` (trivial; can launch separately)
- `GET /mcp/consent` route handler + silent SSO bootstrap
- `POST /api/mcp/consent/authorize`
- `POST /api/mcp/consent/cancel`
- KeycloakAdminClient with the needed methods

### Phase 3 — Wizard UI

- Step 1 (client identity + tenant cards)
- Step 2 (bundle selection)
- Step 3 (review + authorize)
- Empty-membership state
- Routing between steps

### Phase 4 — PermissionMappingRegistry extension

- Schema additions
- Affirmative/negative list generation
- CI validation that RBAC roles are referenced

### Phase 5 — Connected Agents

- `/connected-agents` user view
- User-menu entry
- Disconnect API
- Audit event emission

### Phase 6 — Tenant admin view

- `/tenant-admin/mcp-connections` view
- Force-disconnect API + confirmation dialog
- Aggregate listing performance optimization

### Phase 7 — Integration & E2E

- Wire up to deployed dev Keycloak realm
- Run smoke test Test 33 manually
- Iterate on UX issues found
- Automate the E2E test

---

## 13. References

- `KEYCLOAK_AUTH_PRD.md` §16 — MCP support architecture (the contract this implementation satisfies)
- `KEYCLOAK_MCP_SPI_DESIGN.md` — the SPI side of the cross-system handoff
- `keycloak_mcp.md` — original brainstorm output (path iii decision, scope vocabulary, wizard UX)
- RFC 7591 — Dynamic Client Registration
- RFC 9728 — OAuth 2.0 Protected Resource Metadata
- knobby.io Access Control PRD — RBAC model that scopes cap
- knobby.io Audit Trail ADRs 001/002/003 — audit event conventions
