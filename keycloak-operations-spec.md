# YourApp Identity Provider Operations Spec — Self-Hosted Keycloak (Thin IdP)

**Status:** Draft v2 (thin IdP rewrite)
**Layer:** Cross-cutting. Authentication only — authorization and tenancy remain in yourapp.com.
**Target Keycloak version:** 26.6.x or later (for MCP/CIMD support).
**Supersedes:** Draft v1, which positioned Keycloak as the owner of tenants, roles, and user profiles. That positioning is rejected; see §4.

---

## 0. Why this spec exists

YourApp today uses Auth0 as its identity provider. Three forces drive migration:

1. **Auth0 free tier does not support Dynamic Client Registration**, required by the MCP authorization spec.
2. **Auth0 paid tiers start above $1,500/month**, not justifiable pre-revenue.
3. **Migrating identity providers later, at scale, is high-risk surgery.** Now — small user count, bounded commitment — is the right time.

This spec describes how to migrate from Auth0 to self-hosted Keycloak as a **thin IdP**: Keycloak authenticates, yourapp.com does everything else. It should ship before — or concurrent with — the Layer 1 MCP server work.

---

## 1. Why Keycloak

Selected over Authentik, Zitadel, SuperTokens, Cognito, Firebase for:

- **Battle-tested.** A decade-plus in enterprise production. Edge cases are mostly known and resolved.
- **Real DCR + MCP support.** Keycloak 26.5+ ships documented MCP authorization server support; 26.6 includes experimental CIMD. Genuine MCP integration, not aspiration.
- **Standards compliance.** OAuth 2.1, OIDC, SAML, RFC 7591/7592 DCR. Migrations between standards-compliant IdPs are bounded work — important for the §11 future-migration plan.
- **Open source, Apache 2.0.** No license-trap concerns.
- **Forward migration path.** Managed Keycloak vendors exist (Phase Two, Cloud-IAM, Red Hat SSO). Architecture stays the same; only the operator changes.

The trade-off is operational burden. This spec keeps it minimal: single container, managed Postgres, automated backups, defined patching cadence. Target steady-state: 1–2 hours/month plus incident response.

---

## 2. Architecture

### 2.1 The thin IdP boundary

The architectural commitment that drives every decision in this spec:

> **Keycloak authenticates. yourapp.com authorizes.**

Keycloak's responsibilities are bounded to four things:
1. Run the login ceremony (SSO redirect to Google/Microsoft/enterprise SAML, optionally email+password).
2. Issue OIDC tokens with a stable `sub` claim that yourapp.com uses as the foreign key into its own user table.
3. Federate SSO so yourapp.com only ever speaks OIDC regardless of customer IdP.
4. Be the OAuth 2.1 authorization server for MCP clients: Dynamic Client Registration, authorization code flow with PKCE, token issuance, introspection, revocation.

Everything else — tenants, RBAC/FGAC, user profiles, role assignments, agent principals, approval workflows, audit, organizational hierarchy — stays in yourapp.com. Section 4 covers the boundary in detail.

### 2.2 Deployment topology

- **One Keycloak container** (`quay.io/keycloak/keycloak:26.6` or later).
- **One managed PostgreSQL database** (Cloud SQL on GCP, RDS on AWS). The database is the durability boundary; managed services handle backup, PITR, and failover better than self-managed.
- **TLS termination** in front of Keycloak (built-in or via load balancer/ingress).
- **Object storage** for periodic realm config exports (defense-in-depth beyond DB backups).

Multi-instance clustering is supported (JDBC-ping) but unnecessary at YourApp's current scale.

### 2.3 Deployment platform

Two reasonable platforms — **Cloud Run + Cloud SQL** or **small VM + managed Postgres**:

- **Cloud Run + Cloud SQL** is cleanest if YourApp is on GCP. Trade-off: cold starts (10–30s first-login latency). Mitigation: min instances ≥ 1.
- **VM + managed Postgres** is cheapest. €4–6/mo VM (Hetzner CX22, DO basic) + $7–15/mo managed Postgres. No cold starts; more OS ops responsibility.

Either fits the $10–20/month target. For YourApp's stated $10/month, VM wins on reliability per dollar. **Decision goes in the platform runbook so it's not implicit.**

### 2.4 Data flow

```
                 [ User Browser ]
                       |
                       | HTTPS (login)
                       v
              +-----------------+
              |   YourApp Web    |
              |   UI / MCP Svr  |
              +-----------------+
                       |
                       | OIDC redirect for login only
                       v
              +-----------------+         +-----------------+
              |    Keycloak     |<------->|  PostgreSQL DB  |
              |  (container)    |         |  (managed)      |
              +-----------------+         +-----------------+
                       |
                       | (federated SSO when configured)
                       v
              [ Google / Microsoft / Okta IdP ]
```

After login, yourapp.com receives a token, looks up the user via `sub`, and operates entirely from its own data. Keycloak is not in the hot path of authorization decisions.

---

## 3. Realm and Configuration Model

Keycloak organizes its world into **realms** — isolated identity universes.

### 3.1 Realm topology

**One realm per environment**: `yourapp-prod`, `yourapp-staging`, `yourapp-dev`.

Within each realm:
- **OIDC clients** — one per consumer:
  - `yourapp-web-ui` — web application (replaces Auth0 web app).
  - `yourapp-backend-api` — backend, registered as confidential OIDC client + resource server.
  - `yourapp-mcp-server` — MCP server (added with Layer 1 work).
- **Identity Providers** — federated IdPs. Minimum: Google. Others added as needed.
- **Users** — authentication records only (see §4.2). Migrated from Auth0 per §10.
- **Dynamic clients** — MCP clients registered at runtime via RFC 7591.

**Explicitly NOT used:**
- **Keycloak Organizations.** YourApp has its own tenant model. See §4.3.
- **Keycloak Roles.** YourApp has its own RBAC/FGAC. See §4.4.
- **Keycloak Groups.** Same reason.
- **Keycloak user attributes beyond authentication essentials.** See §4.2.

### 3.2 One Keycloak instance with multiple realms, or one per environment

Single instance with three realms is simpler operationally but couples staging/dev mistakes to prod (shared version, shared Postgres, shared admin). Pre-PMF, single instance + multiple realms is acceptable. **Mid-term goal: separate deployments per environment.** Document the current choice and the trigger for splitting.

### 3.3 Realm settings to verify on creation

- **SSL Required:** `external requests`. Default in recent versions; verify.
- **Access token lifespan:** 5 minutes for web UI (default); 1 hour for MCP clients (set per-client).
- **Login session:** 30 min idle / 10 hr max (defaults are reasonable).
- **Brute force detection:** ON. Lock after 5–10 failed attempts.
- **Password policy** (only if local passwords enabled): length ≥ 12, no recent reuse, length over complexity.
- **Disable user registration** (self-service signup) at the realm level. JIT provisioning on first valid login is handled by yourapp.com; we don't want strangers creating Keycloak users out-of-band.

---

## 4. The Thin IdP Boundary (Authoritative)

This section defines what lives where. **Where this section conflicts with anything else, this section wins.**

### 4.1 Identity model summary

| Concern | Owner | Notes |
|---|---|---|
| Credentials (passwords, MFA factors) | Keycloak | Authentication-only data. |
| Federated identity links (Google/MS/SAML) | Keycloak | Maintained per user in Keycloak. |
| Stable user identifier (`sub`) | Keycloak | Issued at user creation; immutable; FK into yourapp.com. |
| Email, email_verified | Keycloak (source of truth for verification) | Mirrored read-only into yourapp.com for display. |
| User profile (display name, avatar, preferences, locale, timezone) | yourapp.com | Keycloak knows the bare minimum. |
| Tenants and tenant memberships | yourapp.com | Keycloak has no tenant concept. |
| Roles and role assignments | yourapp.com | RBAC tuples in yourapp.com DB. |
| FGAC tuples (Zanzibar) | yourapp.com | Untouched by Keycloak. |
| ABAC policies (CEL) | yourapp.com | Untouched. |
| Approval workflows | yourapp.com | Untouched. |
| Audit events | yourapp.com (platform bus) | Keycloak emits its own events for IdP operations; see §6. |
| Agent principals (AI agents) | yourapp.com | First-class in the ontology. Keycloak doesn't know they exist. |
| MCP OAuth client record | Keycloak | Created via DCR. |
| MCP client *principal* record | yourapp.com | Permissions, tenant scope, approval requirements, attribution. |

### 4.2 What Keycloak stores about each user

The minimum needed to authenticate:
- `sub` (stable UUID, generated by Keycloak)
- `email` and `email_verified`
- `preferred_username` (often the email)
- Credentials (hashed password if local; nothing if SSO-only)
- Federated identity links (provider name + provider user ID)
- MFA enrollments (TOTP secrets, WebAuthn credentials)
- Login event metadata

**Not stored in Keycloak:** display name (beyond what came in the SSO assertion), avatar, role assignments, tenant memberships, custom profile fields, preferences, last-tenant-context, or any business attribute.

The principle: if it isn't needed to perform the next login, it doesn't belong in Keycloak.

### 4.3 Tenants stay in yourapp.com

YourApp already has a tenant model: tenant records, membership tables, tenant-scoped data partitioning, invite workflows, cross-tenant collaboration patterns, and a planned ontology in which a Tenant is an Asset node.

Keycloak's Organizations feature is a B2B convenience for apps **without** a tenant model. Using it for YourApp would force one of:
- **Dual-writing tenant state to both systems** — drift, sync bugs, ambiguous source of truth. Rejected.
- **Replacing yourapp.com's tenant model with Keycloak Organizations** — abandons the ontology-first architecture, sacrifices FGAC integration, and makes future IdP migration much harder. Rejected.

**Decision: Keycloak Organizations are not used.** The tenant claim is not in the token. Tenant context is resolved by yourapp.com per-request from session state.

### 4.4 Roles and authorization stay in yourapp.com

YourApp's authorization stack — RBAC tuples, FGAC (Zanzibar-style), ABAC overlay (CEL), approval workflows — is the single source of truth for "what can this principal do?" Keycloak Roles are a flat-ish RBAC primitive aimed at apps without sophisticated authorization. Using them would create the same dual-write/abandonment dilemma as §4.3.

**Decision: Keycloak Roles are not used.** No role claims in tokens. Authorization is computed in yourapp.com after token validation. If Keycloak's UI insists on showing a role, assign every authenticated user a single trivial `authenticated-user` realm role and never reference it.

### 4.5 Token shape

Tokens issued by Keycloak should be minimal. Standard OIDC claims only:

```json
{
  "iss": "https://auth.yourapp.com/realms/yourapp-prod",
  "sub": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "aud": "yourapp-backend-api",
  "azp": "yourapp-web-ui",
  "exp": 1735689600,
  "iat": 1735686000,
  "email": "user@example.com",
  "email_verified": true,
  "preferred_username": "user@example.com"
}
```

No `tenant`, no `organization`, no `roles`, no `groups`. yourapp.com derives all of that from `sub` on every request.

For MCP-issued tokens, `azp`/`client_id` identifies the MCP client; yourapp.com looks up the MCP client principal and applies composite authorization.

### 4.6 JIT provisioning on first login

When yourapp.com receives a token with a `sub` it doesn't know:

1. Verify the token signature against Keycloak's JWKS.
2. Verify `email_verified` is `true` (reject otherwise).
3. Create a yourapp.com user record keyed by `sub`.
4. Mirror `email` and `preferred_username` into the user record (read-only mirrors; Keycloak remains source of truth for these).
5. Route the user to onboarding: tenant selection, invite acceptance, or empty state, depending on context.
6. Audit-log the provisioning event on the platform bus.

This single seam handles new SSO users, new local-password users, and migrated users equally.

### 4.7 MCP clients: OAuth client in Keycloak, principal in yourapp.com

When an MCP client registers via DCR:
- Keycloak creates the OAuth client record (client_id, credentials, redirect URIs).
- On first authorized action against yourapp.com's MCP server, yourapp.com creates an MCP client **principal** in its ontology, keyed by Keycloak's `client_id`.
- The yourapp.com principal holds: owning user, tenant scope, granted permissions, approval policy, attribution metadata for audit.

**Composite authorization for MCP actions:** the action must be permitted for *both* the human (via `sub`) and the MCP client (via `client_id`) — intersection, not union. This matches the existing AI-agents-on-behalf-of-humans pattern.

**Lifecycle alignment:** disabling/revoking an MCP client must happen in both places. Define a single workflow in yourapp.com that revokes the principal and calls Keycloak's Admin API to disable the OAuth client atomically (with retry/reconciliation if one side fails).

---

## 5. Backend Token Validation

YourApp's backend treats Keycloak as a standard OIDC IdP:

1. Discover endpoints via `/.well-known/openid-configuration`.
2. Cache JWKS; refresh on `kid` miss or scheduled interval.
3. Validate every incoming token: signature, `iss`, `aud`, `exp`, `nbf`, `email_verified`.
4. Extract `sub` and `client_id`/`azp`.
5. Resolve yourapp.com user (and MCP client principal if applicable).
6. Run authorization in yourapp.com's existing stack.

No Keycloak-specific code beyond the OIDC discovery URL. This is what makes §11's future-migration plan feasible.

---

## 6. Audit Integration

Keycloak emits its own events (LOGIN, LOGOUT, LOGIN_ERROR, CLIENT_REGISTER, etc.). Two integration paths:

- **Short-term:** ship Keycloak events to log aggregation (Cloud Logging, Loki, whatever the platform uses). Searchable, alertable, retained per policy.
- **Mid-term:** an adapter consumes Keycloak's event SPI and emits Activity events onto yourapp.com's platform event bus, where they flow through the same audit pipeline as everything else. They land in the Activity graph with `actor = synthetic Keycloak system principal`, `verb = authenticated|logged_out|failed_login|registered_client`, and a link to the affected user/principal.

Mid-term is the goal; short-term is acceptable for v1.

---

## 7. Operations

### 7.1 Backups
- **Database:** managed PITR (Cloud SQL/RDS native), daily snapshot, 30-day retention minimum.
- **Realm exports:** weekly `kc.sh export` to object storage. Defense-in-depth against logical corruption of the live DB.
- **Restore drill:** quarterly. Restore into a scratch environment, log in as a test user. Untested backups are not backups.

### 7.2 Patching
Pin to a minor version (e.g., `26.6.x`). Upgrade quarterly, or immediately for CVEs rated high/critical against Keycloak. Test in dev/staging realm before prod.

### 7.3 Monitoring
- Uptime check on `/realms/yourapp-prod/.well-known/openid-configuration` (cheap, exercises full stack).
- Alert on login error rate spikes.
- Alert on DB connection pool exhaustion.
- Alert on token issuance latency p95 > 1s.

### 7.4 Forgotten admin password
1. `kc.sh bootstrap-admin` to create new admin (requires container shell access).
2. Log in, reset original.
3. Update secrets manager.
4. Postmortem the loss.

### 7.5 Scaling triggers
- DB CPU consistently > 50% → upgrade tier.
- Container CPU/memory consistently high → larger instance or clustering.
- Login latency p95 > 2s → investigate (usually DB or container starvation).

---

## 8. Security Hardening Checklist

- Admin console restricted to internal network or IP-allowlisted.
- All credentials in secrets manager; none in container env definitions or git.
- Brute force detection enabled.
- Realm self-registration disabled.
- Redirect URIs strictly whitelisted per client (no wildcards in prod).
- DCR for MCP behind initial access tokens or trusted-hosts list — open DCR is a public registration surface.
- WebAuthn/passkeys enabled for admin users (operator MFA).
- TLS 1.2 minimum; HSTS on the auth domain.
- Event logging on (login success, login failure, client register, admin actions).

---

## 9. Implementation Phases

### Phase 1 — Stand up Keycloak (1 week)
Platform choice, Keycloak container, managed Postgres, TLS, admin user, realm creation, realm settings per §3.3, backups, monitoring.

### Phase 2 — Replicate Auth0 client and federation setup (3–5 days)
Configure `yourapp-web-ui` and `yourapp-backend-api` clients. Configure Google federation (and any enterprise SAMLs). **No Organizations, no Roles, no Groups beyond a trivial `authenticated-user` role if needed.** Validate end-to-end login flow with test users in dev/staging.

### Phase 3 — Application code updates (1 week)
- Add Keycloak as a second OIDC issuer behind a feature flag.
- Backend accepts tokens from either issuer during transition.
- Implement JIT provisioning per §4.6 (idempotent — must safely handle pre-existing yourapp.com user records keyed by Auth0 `sub` during migration; see §10).
- MCP server wiring (when Layer 1 lands): JWKS validation, MCP client principal creation.

### Phase 4 — User migration (2–3 days)
SSO-only via Google; no password hashes to transfer. See §10 for the detailed plan. The work is dominated by the pre-create + federated-identity-link script and its validation pass, not by any per-user friction.

### Phase 5 — Cutover (1 week, with comms and gradual rollout)
- T-2 weeks: user-facing comms.
- Internal team cuts over first.
- Gradual user batches across the week.
- Monitor error rates; rollback ready (flip the issuer feature flag).
- Disable Auth0 once stable.

### Phase 6 — Post-migration cleanup (30 days after stable)
Remove Auth0 fallback code paths. Cancel Auth0 account. Archive migration artifacts.

### Phase 7 — Security hardening completion
Complete §8 checklist. Incident response rehearsal. Establish quarterly ops cadence.

---

## 10. Migration Plan: Auth0 → Keycloak (Google SSO Only, ~5 Users)

All current YourApp users authenticate via Google SSO through Auth0. There are no local-password users and no other federations. User count is small (~5 — founders and early team).

These two facts together collapse the migration. There are no password hashes to transfer, no one-time reset cohort, no MFA migration, and at this scale, no need for a bulk pre-creation script via Keycloak's Admin API. Migration is: stand up Keycloak with Google federation, ask everyone to log in once, let Keycloak create their user record on first login, and let yourapp.com's JIT seam bind that record to the existing yourapp_user.

### 10.1 The mechanism: bridging via Google's `sub`

When a user logs in via Auth0 → Google today, Auth0 stores its own `sub` (e.g., `google-oauth2|112233445566778899000`) and exposes Google's underlying `sub` in the user's `identities[0].user_id` field.

When the same user logs in via Keycloak → Google after migration, Keycloak issues a different `sub` (a UUID), and the underlying Google `sub` appears in the federated identity link Keycloak creates for that user.

Same Google account, same Google `sub`, two different IdP `sub`s on top of it. The `external_identity` table holds the indirection.

### 10.2 The external_identity table

```
external_identity (
  user_id        uuid    references yourapp_user(id),
  issuer         text    not null,   -- 'auth0' or 'keycloak'
  subject        text    not null,   -- the IdP's sub for this user
  google_sub     text,               -- Google's underlying sub, used as the bridge
  primary_at     timestamptz,        -- non-null = active mapping
  created_at     timestamptz,
  primary key (issuer, subject)
)
```

`google_sub` is the join key across IdPs.

### 10.3 Pre-migration: instrument yourapp.com

1. Create the `external_identity` table.
2. Backfill from Auth0 (see §10A for extraction): for each YourApp user, insert one row — `issuer='auth0'`, `subject=<auth0 sub>`, `google_sub=<google sub from identities[0].user_id>`, `primary_at=now()`.
3. Refactor authentication code: key on `(issuer, subject)` via `external_identity` → resolve `user_id`. No-op functionally.
4. Modify JIT provisioning (§4.6) for the migration case: when a Keycloak token arrives with an unknown `sub`, before creating a fresh yourapp_user, look up the Google `sub` from the token's federated identity claim and check `external_identity.google_sub`. If a row exists, this is a migrating user — bind the new Keycloak `external_identity` row to the existing `user_id` and mark it primary. If not, this is genuinely new — standard JIT provisioning.
5. Ship, verify with a test login in dev/staging.

### 10.4 The actual migration (one afternoon)

1. Verify Keycloak is up with Google federation configured (Phase 2 of §9).
2. Frontend feature flag flipped to route to Keycloak.
3. Slack the team: "We're switching IdPs. Please log out and log back in. Same Google account, you'll see one extra consent screen, that's it."
4. Each person logs in. On their first login:
   - Keycloak handles the Google handshake, creates a Keycloak user, stores the federated identity link with Google's `sub`.
   - Keycloak issues a token to yourapp.com.
   - yourapp.com sees an unknown Keycloak `sub`, runs the migration-aware JIT logic from §10.3 step 4, finds the matching `google_sub` in `external_identity`, binds, marks the Keycloak row primary, demotes the Auth0 row.
5. Watch the audit log to confirm each person migrated cleanly.
6. Once everyone has logged in (a day or two of elapsed time, not work time), validate per §10.5, then disable Auth0.

Rollback: flip the feature flag back to Auth0. The Auth0 rows in `external_identity` are still there, still valid. No data loss either way.

### 10.5 Validation before disabling Auth0

- Every team member has a Keycloak `external_identity` row with `primary_at` set.
- Login error rates back to baseline.
- 7–14 days of stable operation (at this scale, 30 days is overkill).
- Audit shows expected `authenticated` events from the Keycloak adapter.

Then disable the Auth0 application; cancel the account after a further week.

### 10.6 Edge cases

- **Someone's Google account changed `sub`.** Vanishingly unlikely (Google `sub` is stable for the life of the account), but if it happens, manual re-link via direct DB update.
- **Auth0 user without a Google identity in `identities[]`.** Shouldn't exist given SSO-only assumption; if it does, flag for manual handling.
- **Someone forgets to log in for weeks.** Their Auth0 row stays primary; they still work via the (still-running) Auth0 flow if you've kept it as a fallback during transition. If you've already cut Auth0 off, they hit Keycloak fresh and the migration-aware JIT in §10.3 step 4 picks them up. Either way, no breakage.

---

## 10A. Extracting Data From Auth0

This section is the practical "where do I click and what do I run" guide for getting the migration inputs out of Auth0.

### 10A.1 What you need

For each user, two things:

- The user's **Auth0 `sub`** (e.g., `google-oauth2|112233445566778899000`) — to populate `external_identity.subject` for the Auth0 row.
- The user's **Google `sub`** (the bare numeric ID, e.g., `112233445566778899000`) — to populate `external_identity.google_sub`.

For Google SSO connections, the Auth0 `sub` is literally `google-oauth2|` + the Google `sub`. You can in principle derive one from the other by string-splitting. Worth verifying for each user against the Auth0 record rather than assuming.

Email is also worth grabbing as a sanity check.

### 10A.2 Option A: Auth0 Dashboard (manual, recommended for 5 users)

For a handful of users, this is the path of least resistance.

1. Log into the Auth0 dashboard at `manage.auth0.com`.
2. Select your tenant (top-left dropdown).
3. **User Management → Users.** This lists all users.
4. For each user:
   - Click into their record.
   - The top of the page shows their `user_id` (this is the Auth0 `sub`). Copy it.
   - Scroll to **Identity Provider Attributes** or **Raw JSON** view (toggle at top-right). The raw JSON shows the `identities` array; `identities[0].user_id` is Google's `sub` for that user. For Google connections this should match the numeric portion of the Auth0 `sub`.
   - Note their email.
5. Drop these into a CSV: `email, auth0_sub, google_sub`. You now have your backfill input.

For 5 users, this takes 10 minutes and avoids any tooling.

### 10A.3 Option B: Management API (scripted, recommended if 20+ users or for future re-use)

The Auth0 Management API exposes everything programmatically.

**One-time setup:**

1. **Dashboard → Applications → APIs → Auth0 Management API.**
2. Go to the **Machine to Machine Applications** tab.
3. Authorize a new M2M app (or create one under Applications first) with at minimum the `read:users` scope.
4. Copy the Client ID and Client Secret for that M2M app.

**Get a token:**

```bash
curl --request POST \
  --url https://YOUR_TENANT.auth0.com/oauth/token \
  --header 'content-type: application/json' \
  --data '{
    "client_id": "YOUR_M2M_CLIENT_ID",
    "client_secret": "YOUR_M2M_CLIENT_SECRET",
    "audience": "https://YOUR_TENANT.auth0.com/api/v2/",
    "grant_type": "client_credentials"
  }'
```

Capture `access_token` from the response.

**List users:**

```bash
curl --request GET \
  --url 'https://YOUR_TENANT.auth0.com/api/v2/users?per_page=100&page=0' \
  --header 'authorization: Bearer YOUR_ACCESS_TOKEN'
```

For each user in the response, the fields you care about are:
- `user_id` → Auth0 sub
- `email`
- `identities[0].user_id` → Google sub (for the Google connection)
- `identities[0].provider` → should be `google-oauth2` for SSO users

A trivial `jq` to extract the CSV you need:

```bash
curl -s 'https://YOUR_TENANT.auth0.com/api/v2/users?per_page=100&page=0' \
  -H "authorization: Bearer YOUR_ACCESS_TOKEN" \
  | jq -r '.[] | [.email, .user_id, .identities[0].user_id] | @csv' \
  > auth0-users.csv
```

### 10A.4 Option C: Bulk user export job (recommended if 1000+ users)

For larger user bases the export job is the right tool (it streams to a downloadable file rather than paginating the live API). At YourApp's scale this is overkill, but documenting for future reference:

1. **POST to `/api/v2/jobs/users-exports`** with the M2M token, specifying the connection (`connection_id` for the Google SSO connection) and the fields you want (`user_id`, `email`, `identities`).
2. Poll **GET `/api/v2/jobs/{job_id}`** until status is `completed`.
3. Download the resulting NDJSON or CSV from the URL in the response. URL is time-limited (typically 60 seconds).
4. Parse and transform.

### 10A.5 Sanity checks before backfilling

Before committing the data to `external_identity`:

- Every user has a non-null `email`, `auth0_sub`, and `google_sub`.
- Every `auth0_sub` starts with `google-oauth2|`.
- The portion after the pipe equals `google_sub` for every row. (If this ever doesn't hold, stop and investigate — it means an assumption is broken.)
- Row count matches the number of users in the Auth0 dashboard.

If any row fails these checks, fix or remove it before proceeding. A few minutes of validation here saves debugging a stuck login later.

### 10A.6 What you don't need to extract

Explicitly out of scope:
- Passwords or password hashes (no local-password users).
- MFA enrollments (none configured).
- Custom `app_metadata` or `user_metadata` (yourapp.com owns user data; nothing in Auth0 metadata that yourapp.com doesn't already have).
- Roles or permissions (none in Auth0 by §4 principles).
- Audit logs (Auth0 audit doesn't migrate into Keycloak; archive separately if retention required).

If any of these assumptions turn out to be wrong on inspection, stop and reconsider before proceeding with the migration.

---

## 11. Future Migration: Keycloak → Red Hat SSO (or Any OIDC-Compliant IdP)

The thin IdP architecture in §4 and the `external_identity` indirection in §10.1 make future IdP migrations a **bounded, repeatable** operation rather than a rewrite.

### 11.1 What makes the next migration easier

- **No Keycloak-specific data in yourapp.com.** No Keycloak role IDs, no Keycloak org IDs, no Keycloak group IDs — none of those exist in our model. Tenants, roles, permissions, profiles all live in yourapp.com and are IdP-agnostic.
- **Standards-only integration surface.** Backend speaks OIDC discovery, JWKS, OAuth 2.1, DCR. Anything that implements those works.
- **`external_identity` table already exists.** Adding a new issuer is one new row per migrated user.
- **Token shape is minimal and standards-only.** No Keycloak-proprietary claims to translate.

### 11.2 The standard playbook

For Keycloak → Red Hat SSO (which is Keycloak with a vendor wrapper, so trivially easy) or Keycloak → Authentik, Zitadel, Cognito, Okta, Entra, anything OIDC:

1. **Stand up the new IdP** in parallel with Keycloak. Same realm topology, same client topology, same federations configured.
2. **Export Keycloak users.** Keycloak's export is realm-level and well-documented. Same fields as §10.3.
3. **Import into the new IdP.** Mechanics vary by target:
   - **Red Hat SSO:** trivial — same `kc.sh import` format. Likely a configuration swap rather than data migration.
   - **Other OIDC IdPs:** transform export to target's user format, import via target's admin API. Federated identity links transfer if target supports per-user federated identity linking (most do).
   - **Password hashes:** transferable if both sides use compatible hash schemes (Keycloak's PBKDF2 → most targets). Otherwise, one-time reset cohort as in §10.4.
4. **Backfill `external_identity`** with the new IdP's `sub` per user. `primary_at=null` initially.
5. **Update OIDC discovery URL** in backend config. Backend now accepts tokens from both issuers behind the feature flag.
6. **Per-user cutover** identical to §10.5.
7. **Decommission Keycloak** after 30 days stable.

### 11.3 What could complicate it

- **Proprietary token claims you came to depend on.** Avoided by §4.5 keeping the token minimal.
- **IdP-managed tenants or roles.** Avoided by §4.3 and §4.4 keeping them in yourapp.com.
- **Custom flows or themes.** Themes are cosmetic and easy to re-implement; custom authentication flows (if added later) need re-implementation on the new IdP. Document any custom flows so the cost is known.
- **MCP DCR semantics.** Target IdP must support RFC 7591 with compatible policy. Verify before committing.

### 11.4 Cost estimate for future migration

If the thin IdP discipline holds: **roughly the same effort as the Auth0 → Keycloak migration described here**, minus the password hash drama (we control the source IdP this time). 2–3 weeks of focused work for a small user base, scaling linearly with user count and number of enterprise SAML integrations.

If the discipline doesn't hold — i.e., someone over time pushes tenant data or role data into Keycloak — the cost is much higher. **Section 4 is therefore not just architectural preference; it is a long-term cost control mechanism.** Treat changes to it accordingly.

---

## 12. Success Criteria

The migration is complete when:

1. All users authenticate via Keycloak; Auth0 disabled and account terminated.
2. All users log in via Keycloak → Google federation transparently; no user re-registration or password reset.
3. Enterprise SAML customers updated and verified.
4. Token shape matches §4.5 — no tenant, role, or organization claims present.
5. Tenant resolution, RBAC/FGAC, and approvals all operate from yourapp.com state as before. Zero regressions in authorization behavior.
6. MCP DCR works end-to-end: client registers, obtains user-delegated token, yourapp.com creates the principal, composite authorization applies.
7. Backups running daily; restore drill completed.
8. Monitoring alerting on the right signals.
9. No security issues in 30 days post-migration.
10. `external_identity` table populated and queryable; ready for §11.

---

## 13. Out of Scope

- Specific Terraform/Pulumi for Keycloak. Manage-as-code is good; tool choice is left to the team.
- Multi-region Keycloak. Premature.
- Custom login themes. Cosmetic; ship default first, brand later.
- WebAuthn/passkeys for end users. Worth enabling later; not v1 blocking. Admin WebAuthn is in §8.
- Post-quantum readiness.

---

## 14. Coding Agent Instructions

- **Treat Section 4 as inviolable.** Any change that pushes tenant data, role data, or rich user profile data into Keycloak must STOP and confirm with the user before proceeding. This is the single most important constraint in the spec.
- **Treat the IdP as production-critical from day one.** Backups, monitoring, patching are not "phase 7 polish."
- **Pin Keycloak version** (e.g., `26.6.x`); upgrade deliberately.
- **Configuration-as-code.** Even Bash scripts hitting the Admin REST API beat undocumented manual clicks. Reproducibility is a feature.
- **Secrets handling.** No Keycloak credentials, client secrets, or admin passwords in git, env definitions, or deployment configs. Always secrets manager.
- **Migration testing.** Every user-impacting step tested end-to-end in staging with a real Google account before prod.
- **Rollback plan.** Every cutover phase has a rollback. The dual-issuer feature flag is the rollback for Auth0 → Keycloak; same pattern applies in §11.
- **JIT provisioning idempotency.** Must safely handle pre-existing yourapp_user records keyed via `external_identity`. STOP and confirm with user if the design diverges.
- **Documentation discipline.** Operational changes documented in the ops runbook in-repo.

---

## 15. References

- Keycloak documentation: https://www.keycloak.org/documentation
- Keycloak MCP guide (26.5+): https://www.keycloak.org/docs/latest/server_admin (search "Model Context Protocol")
- RFC 7591 — OAuth 2.0 Dynamic Client Registration: https://datatracker.ietf.org/doc/html/rfc7591
- RFC 7592 — Dynamic Client Management: https://datatracker.ietf.org/doc/html/rfc7592
- MCP authorization spec: https://modelcontextprotocol.io/specification/basic/authorization
- OIDC Core 1.0: https://openid.net/specs/openid-connect-core-1_0.html

---

*End of Keycloak Operations Spec, v2 (thin IdP).*
