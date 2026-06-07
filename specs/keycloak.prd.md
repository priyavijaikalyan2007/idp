# Authentication & Identity Brokering PRD

**Status:** Draft v1.6
**Owner:** PVSS
**Last Updated:** 2026-06-02
**Related Specs:** Access Control PRD (Zanzibar RBAC), Audit Trail ADR-001/002/003, Approval System Requirements, Pathfinder PRD (agent session management), **Keycloak Theming Guide** (companion document)

**Changelog:**
- v1.0–v1.4: see prior changelogs (Microsoft Entra strategy, runbook corrections, naming conventions, integration reference expansions, Apple Sign In addition).
- v1.5 (2026-06-02): Apple Sign In deferred to Future Work; theming detail moved to companion guide.
- v1.6 (2026-06-02): Significant cleanup driven by manual-setup learnings and a return to the "thin IdP broker" architectural charter. Seven themes:
  1. **Keycloak Organizations dropped entirely.** §5 rewritten — tenancy is owned by the knobby.io application layer; Keycloak is purely a federation broker. §11 sections for "Enable Organizations Feature" and "Configure Organizations" removed. The `org` token claim removed from §8.3. All Organizations operations removed from §8.7. §13 OpenTofu structure no longer includes an organizations module.
  2. **Application persistence reframed as requirements, not schema.** §8.4 and §12 stop prescribing table names, columns, or SQL DDL. Instead each persistent-state requirement is described as logical fields with lifecycle and trust properties, with an explicit implementation note directing implementers to align with knobby.io's existing data conventions.
  3. **Microsoft alias convention corrected to `microsoft-oidc`** across §6.3, §8.1, §10.8, §11.9 — reflects the fact that the alias is immutable in Keycloak and disambiguates from the (unused) built-in `microsoft` provider.
  4. **Entra app registration conventions clarified.** §6.3 and §11.9 note correct capitalization (`Keycloak`, not `KeyCloak`), no env suffix on prod displayName, publisherDomain set to `knobby.io` (not a per-env subdomain), and the publisher domain hosting requirement (`.well-known/microsoft-identity-association.json` at the apex).
  5. **Admin API role list corrected.** §11.13 (was §11.15) drops the non-existent `view-organizations`/`manage-organizations` role names. `manage-realm` not required (no longer needed without Organizations). Note added that the role list has evolved across PRD revisions.
  6. **§11 sections renumbered** to close gaps from removed sections. §11.18 (verification checklist) is now §11.16; smoke test references updated accordingly.
  7. **Deployment topology clarified.** Apex `knobby.io` and `www.knobby.io` are marketing/publisher surfaces only. The prod application is deployed at `prod.knobby.io`; dev at `dev.knobby.io`. §8.1 redirect URI table and §10.8 naming convention updated. §12.2 Microsoft admin consent example URL updated. This was confirmed during manual federation testing — Keycloak's authorization endpoint rejection of PKCE-deficient test URLs surfaced the URL bar bouncing through `prod.knobby.io`, revealing the topology disconnect from earlier PRD assumptions about the apex hosting the app.

---

## Reader's Guide

This PRD addresses several audiences:

- **Architects / decision review** → §§1–10.
- **Operators setting up a Keycloak realm by hand** → §11 (runbook).
- **knobby.io app implementers (including Claude Code)** → §8 (integration reference) and §12 (tenant onboarding requirements). §10.8 is the authoritative naming-convention table. **Do not assume specific database tables exist** — the PRD describes *persistence requirements*; map to actual knobby.io schema by consulting the codebase.
- **Infra engineers building Keycloak IaC** → §13 (OpenTofu plan) and §10.8.
- **Frontend engineers building the Keycloak theme** → `KEYCLOAK_THEMING_GUIDE.md` (companion document).

§10.8 is the single source of truth for all naming. Any code, IaC, runbook step, or documentation that disagrees with §10.8 should be considered out of date.

---

## 1. Executive Summary

knobby.io will use Keycloak as a centralized identity broker that federates to all upstream identity providers (Google Workspace, Microsoft Entra, GitHub, enterprise SAML 2.0). Users will never directly interact with Keycloak. All login, profile management, account operations, and tenancy management occur within knobby.io. Keycloak operates as invisible infrastructure: it terminates federation, mints tokens, and exposes an Admin REST API that knobby.io consumes server-side.

Tenancy is a knobby.io application-layer concept. knobby.io's data model owns the Organization concept; Keycloak does not. Per-customer SAML IdPs are registered at the realm level with a stable naming convention and mapped to knobby.io organizations in the application layer.

Enterprise customer onboarding is a first-class concern. Each enterprise customer tenant must be explicitly *connected* to knobby.io before its users can sign in. For Microsoft Entra, this means a tenant admin grants OAuth admin consent via a dedicated knobby.io onboarding flow. For Google Workspace, this means Workspace admin allowlisting. For SAML customers, this means the customer configures their IdP against knobby.io's SP metadata and knobby.io provisions a corresponding IdP entry via Keycloak Admin REST API.

This PRD establishes the durable invariants, the target architecture, the application-layer tenant model, the per-IdP configuration, the per-customer onboarding pattern, naming conventions, application integration reference, and a step-by-step setup runbook for fresh realm configuration in any of the three environments. It also commits to OpenTofu as the IaC tool for automated realm setup. The Keycloak theme is documented in the companion `KEYCLOAK_THEMING_GUIDE.md`.

---

## 2. Context

### 2.1 Business Drivers

knobby.io is a B2B enterprise SaaS platform targeting software/IT organizations. Customer organizations expect:

- SSO integration with their existing IdP (Google Workspace, Microsoft Entra, custom SAML 2.0).
- No additional credentials for knobby.io itself.
- A consistent, branded experience that never breaks the "knobby.io product" illusion.
- Compliance with their internal identity governance (MFA, session policies, deprovisioning).
- IT-controlled onboarding: an enterprise admin explicitly approves knobby.io for the organization before users can sign in.
- Optional social sign-in (GitHub) for individual contributors.

### 2.2 knobby.io Platform Needs

- One integration surface (Keycloak as OIDC IdP) regardless of how many upstream IdPs are configured.
- Consistent JWT claims across users from any source.
- Centralized session management, logout coordination, and revocation.
- A path to support local users (B2C, contractors, service accounts) without re-architecting.
- First-class AI agent principals (per Access Control PRD).
- A clean tenant-onboarding model where the application layer owns tenancy semantics.

### 2.3 Why Keycloak

Keycloak is the established open-source identity broker with mature support for OIDC and SAML 2.0. Its built-in support for upstream IdP federation is the value we want; its tenancy features (Organizations) are not.

---

## 3. Invariants

### Invariant 1 — No local username/password authentication in production flows

The realm does not expose a username/password form. All human users authenticate via an upstream IdP. The capability to support local credentials remains present in the realm configuration so it can be re-enabled later by modifying the browser flow.

### Invariant 2 — Upstream IdP policies are authoritative for authentication assurance

Keycloak does not enforce additional MFA, password policies, or session policies on top of what the upstream IdP requires.

### Invariant 3 — Users never see Keycloak

Keycloak's user-facing surfaces are either replaced, bypassed, disabled, or themed beyond recognition. The Keycloak hostname is `auth.knobby.io` (or `localhost:8080` for the developer-local `test` environment). Theming is documented in `KEYCLOAK_THEMING_GUIDE.md`.

### Invariant 4 — knobby.io is a single OIDC client of Keycloak per environment

The knobby.io application integrates with Keycloak as one OIDC client per environment (`knobby-prod-web`, `knobby-dev-web`, `knobby-test-web`).

### Invariant 5 — Per-environment IdP credentials

Every upstream IdP integration (Google OAuth client, Microsoft Entra app registration, GitHub OAuth app, customer SAML SP entry) is registered separately per environment.

### Invariant 6 — Convention-based naming

All Keycloak resources and associated secrets follow a deterministic naming convention so that automation, scripts, runbooks, and human operators can derive any name from the environment alone. See §10.8.

### Invariant 7 — Realm configuration as code

Once the OpenTofu IaC for realm setup is in place (per §13), manual changes to realm configuration through the Keycloak admin console are not permitted in `prod` or `dev`.

### Invariant 8 — Tenancy lives in knobby.io, not Keycloak

knobby.io's application data model is the single source of truth for organizations, organization membership, customer↔IdP mapping, tenant connection state, and consent state. Keycloak does not use its Organizations feature. The realm is purely an IdP broker.

---

## 4. Architecture

### 4.1 Topology

```
                              ┌──────────────────────────────┐
                              │     Upstream IdPs            │
                              │  • Google Workspace          │
                              │  • Microsoft Entra           │
                              │  • GitHub                    │
                              │  • Customer SAML IdPs (N)    │
                              └──────────────┬───────────────┘
                                             │ OIDC / SAML 2.0
                                             │
   ┌─────────────────────────────────────────▼────────────────────────────────┐
   │  Keycloak (auth.knobby.io)                                               │
   │  ┌────────────────────────────┐  ┌────────────────────────────┐         │
   │  │  Realm: knobby-prod        │  │  Realm: knobby-dev         │         │
   │  └────────────────────────────┘  └────────────────────────────┘         │
   │           ▲                                ▲                              │
   │           │ OIDC / Admin REST API          │                              │
   └───────────┼────────────────────────────────┼──────────────────────────────┘
               │                                │
   ┌───────────▼────────────┐         ┌─────────▼────────────┐
   │  knobby.io (prod)      │         │  knobby.io (dev)     │
   │  • Tenancy owner       │         │  • Tenancy owner     │
   └────────────────────────┘         └──────────────────────┘

   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
                                                        (developer machine)

                       ┌────────────────────────────┐
                       │  Keycloak (localhost:8080) │
                       │  Realm: knobby-test        │
                       └──────────────┬─────────────┘
                                      │
                       ┌──────────────▼─────────────┐
                       │  knobby.io (local dev)     │
                       └────────────────────────────┘
```

**Production-facing topology:** one Keycloak instance hosted at `https://auth.knobby.io` serves both the `knobby-prod` and `knobby-dev` realms.

**Test environment:** the `knobby-test` realm runs on each developer's local machine.

### 4.2 Component Responsibilities

**Keycloak**
- Terminates federation to upstream IdPs.
- Maintains the canonical federated user record (one per (subject, IdP) pair, linked via email).
- Issues OIDC tokens to knobby.io's web client.
- Exposes Admin REST API for user lookup and IdP CRUD.
- Hosts SAML SP metadata endpoint.
- Does **not** manage organizations or tenancy.

**knobby.io frontend**
- Renders the login screen with IdP buttons (Google, Microsoft, GitHub, "Enterprise SSO").
- Initiates OIDC Authorization Code + PKCE flow against Keycloak with `kc_idp_hint=<alias>`.
- Renders all account, profile, organization, and tenant management UI.
- Renders the enterprise admin onboarding flow.
- Handles logout via RP-initiated logout.

**knobby.io backend**
- Validates OIDC tokens.
- Calls Keycloak Admin REST API for user CRUD and IdP CRUD operations.
- Maps Keycloak `sub` to knobby.io user identity (application persistence).
- Owns the organization data model and organization↔user membership.
- Owns the customer↔IdP-alias mapping (which Keycloak SAML IdP alias corresponds to which knobby.io Organization).
- Owns tenant-connection state (Microsoft consent records, Google Workspace connections, SAML IdP connections).
- Enforces RBAC/FGAC per the Access Control PRD.

**Agent runtime (future)**
- Authenticates via OAuth 2.0 Client Credentials with a per-agent client.

### 4.3 Data Flow — Human Login (happy path)

1. User opens `knobby.io`. App renders login screen.
2. User clicks "Sign in with Google" (or Microsoft / GitHub / Enterprise SSO). Frontend navigates to Keycloak's authorize endpoint with `kc_idp_hint=google` (or `microsoft-oidc`, `github`, `saml-<slug>`).
3. Keycloak 302s to the IdP. No Keycloak HTML rendered.
4. User authenticates at the IdP.
5. IdP 302s back to Keycloak's broker endpoint with authorization code.
6. Keycloak exchanges the code, reads identity claims.
7. Keycloak runs First Broker Login flow: looks up federated user; creates if needed.
8. Keycloak 302s back to `https://prod.knobby.io/auth/callback?code=...&state=...`.
9. knobby.io backend exchanges Keycloak's code for tokens, validates them, looks up the application user by `sub`, determines org context from its own data, establishes session.

### 4.4 Data Flow — Logout

RP-initiated logout from knobby.io frontend; hits Keycloak end-session endpoint; Keycloak terminates session and 302s back. Upstream IdP session is not terminated.

### 4.5 Data Flow — Enterprise Tenant Onboarding

See §12.

---

## 5. Tenant Model

### 5.1 Decision: Application-layer tenancy

Tenancy lives in knobby.io's application data model. Keycloak does not use its Organizations feature.

**Rationale:**
- knobby.io already has a first-class Organization concept in its data model (existed before this PRD).
- Duplicating that concept in Keycloak would require ongoing synchronization between two data stores.
- Keycloak's Organizations feature is relatively new (GA in 26.0) with known gaps (fine-grained admin permissions for Organizations not yet broken out in 26.x; known bugs interacting with the existing realm-management role surface).
- Invariant 3 says users never see Keycloak — there's no UX value in Keycloak Organizations for our use case.
- The only Keycloak feature where Organizations seemed to add value (domain-based home discovery) is handled in the knobby.io frontend anyway (§12.9 Strategy B).

**Mechanics:**
- Per-customer SAML IdPs registered at the realm level with naming pattern `saml-<customer-slug>` (per §6.5 and §10.8). No link to a Keycloak Organization.
- knobby.io's data model maintains the mapping from Keycloak IdP alias to knobby.io Organization (see §12 persistence requirements).
- Organization membership for users is determined by knobby.io on token validation (look up user by `sub`, determine org from application data).
- Tokens issued by Keycloak do not include an `org` claim; org context is derived in knobby.io after token validation.

---

## 6. Identity Provider Strategy

### 6.1 Common Configuration (all IdPs)

For every IdP added to a realm:
- **Alias** is stable, lowercase, follows the per-IdP convention in §10.8. Once set, the alias is immutable (Keycloak constraint) — choose carefully.
- **Sync Mode** = `force`.
- **Trust Email** = `On` (with per-IdP override for low-trust sources).
- **First Login Flow** = `first-broker-login-no-prompt` (custom; see §7). **Applies to every IdP — Google, Microsoft, GitHub, and every SAML entry.**
- **Store Tokens** = `Off`.
- **Per-environment credentials** per Invariant 5.

### 6.2 Google Workspace

- Built-in provider, alias `google`.
- Trust Google's 2FA enforcement.
- Per-environment Google OAuth clients.
- Redirect URIs (per §10.8):
  - Prod: `https://auth.knobby.io/realms/knobby-prod/broker/google/endpoint`
  - Dev: `https://auth.knobby.io/realms/knobby-dev/broker/google/endpoint`
  - Test: `http://localhost:8080/realms/knobby-test/broker/google/endpoint`
- Client secrets: `knobby-google-oauth-client-secret-{env}`.
- Enterprise onboarding: Workspace admin allowlists OAuth client ID in Google Admin Console (Security → API controls → App access control). See §12.10.

### 6.3 Microsoft Entra (Azure AD)

**Account types:** work/school accounts from any Entra tenant (enterprise) + personal Microsoft accounts (social). One Keycloak IdP entry handles both via Microsoft's `common` endpoint.

**Implementation:** generic **OpenID Connect v1.0** provider type — not the built-in "Microsoft" provider (which is hardcoded for single-tenant).

**Alias convention:** `microsoft-oidc` (the `-oidc` suffix disambiguates from the unused built-in `microsoft` provider and makes it explicit that this is the generic OIDC connector). Aliases are immutable in Keycloak, so this name persists.

**Per-environment Entra app registrations:**
- Prod: `knobby.io Keycloak Broker` (no env suffix; this name appears on customer admin consent screens)
- Dev: `knobby.io Keycloak Broker (dev)`
- Test: `knobby.io Keycloak Broker (test - {developer-name})`

**Capitalization:** the official spelling is `Keycloak` (capital K, lowercase c). `KeyCloak` is a common but incorrect rendering — customer admins reading the consent screen notice these things. Get it right at registration time; it cannot be changed without re-registering.

**Supported account types** in each Entra app: "Accounts in any organizational directory and personal Microsoft accounts."

**Discovery endpoint:** `https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration`.

**Issuer validation gotcha:** leave the **Issuer** field empty.

**Forwarded query parameters:** `login_hint,domain_hint,prompt`.

**Personal-account differentiation:** `tid` claim. Personal MSAs have `tid=9188040d-6c67-4c5b-b112-36a304b66dad`.

**Client secrets:** `knobby-entra-broker-client-secret-{env}`. Secret description in Entra: `keycloak-broker-{env}`.

**Publisher domain:** `knobby.io` (the company's primary domain — same value for all environments because the publisher is the company, not the deployment). Requires Microsoft Publisher Verification — see §10.7. Requires hosting `https://knobby.io/.well-known/microsoft-identity-association.json` at the apex.

**Trust posture:**
- Work/school accounts: equivalent trust tier to Google Workspace.
- Personal MSAs: lower trust tier. Rejected from enterprise-tier organizations at the application authorization layer.

### 6.4 GitHub

GitHub is a **lower-trust** IdP than Google or Microsoft work accounts.

**Implementation:** built-in provider, alias `github`.

**Per-environment GitHub OAuth Apps:**
- Prod: `knobby.io`
- Dev: `knobby.io (dev)`
- Test: `knobby.io (test - {developer-name})`

**Configuration on GitHub** (Developer Settings → OAuth Apps → New OAuth App):

| Field | Prod | Dev | Test |
|-------|------|-----|------|
| Application name | `knobby.io` | `knobby.io (dev)` | `knobby.io (test - {dev-name})` |
| Homepage URL | `https://knobby.io` | `https://knobby.io` | `http://localhost:3000` |
| Authorization callback URL | `https://auth.knobby.io/realms/knobby-prod/broker/github/endpoint` | `https://auth.knobby.io/realms/knobby-dev/broker/github/endpoint` | `http://localhost:8080/realms/knobby-test/broker/github/endpoint` |
| Enable Device Flow | Off | Off | Off |

**Scopes:** `user:email read:user`.

**Email handling caveat:** GitHub users can hide their email. Configure an attribute mapper that pulls the primary verified email from `/user/emails`. If still null after all mappers, the user can't federate via GitHub.

**Trust Email:** On.

**Client secrets:** `knobby-github-oauth-client-secret-{env}`.

### 6.5 Enterprise SAML 2.0 (per customer organization)

- One SAML IdP entry per customer. Alias pattern `saml-<customer-slug>`.
- Configuration imported from customer-supplied SAML metadata XML.
- Registered at the realm level (no Keycloak Organization linkage per Invariant 8).
- knobby.io's SP entity ID per env:
  - Prod: `https://auth.knobby.io/realms/knobby-prod`
  - Dev: `https://auth.knobby.io/realms/knobby-dev`
- ACS URL: `<SP-entity-id>/broker/saml-<customer-slug>/endpoint`.
- NameID format: `emailAddress` preferred.
- Signed AuthnRequests and signed assertions required.
- knobby.io's application data maintains the mapping from IdP alias to knobby.io Organization (§12).

---

## 7. Authentication Flows

### 7.1 Browser Flow — `browser-federated-only`

Duplicate of the built-in Browser flow with:

| Step | Action |
|------|--------|
| Cookie | Alternative |
| Kerberos | Disabled |
| Identity Provider Redirector | Required, no default IdP |
| Forms (Username Password Form, OTP) | Disabled |

Bound via the **Action → Bind flow** menu in Keycloak 26.x.

### 7.2 First Broker Login Flow — `first-broker-login-no-prompt`

Duplicate of the built-in `first broker login` with all interactive prompts disabled. Federated users are auto-linked by verified email or auto-created.

### 7.3 Required Actions

All Required Actions set to **Default = Off**.

---

## 8. knobby.io ↔ Keycloak Integration (Application Implementation Reference)

This section is the authoritative reference for the knobby.io application's integration with Keycloak.

**Implementation note throughout:** this section describes the *integration contract* — what Keycloak provides and what knobby.io must do with it. It does not prescribe knobby.io's internal data model. References to "knobby.io persists X" or "knobby.io's user record" are about *requirements*; the actual schema, table names, and column types are at the implementer's discretion and should align with the existing knobby.io codebase. Consult the codebase before assuming new persistence layers are needed.

### 8.1 Per-Environment URL & ID Reference

All URLs and identifiers needed for app configuration, parameterized by `{env}` ∈ `{prod, dev, test}`.

**Base URLs:**

| Setting | Prod / Dev | Test |
|---------|-----------|------|
| Keycloak base URL | `https://auth.knobby.io` | `http://localhost:8080` |
| Realm name | `knobby-{env}` | `knobby-test` |
| OIDC issuer | `https://auth.knobby.io/realms/knobby-{env}` | `http://localhost:8080/realms/knobby-test` |
| OIDC discovery | `<issuer>/.well-known/openid-configuration` | (same pattern) |
| Authorization endpoint | `<issuer>/protocol/openid-connect/auth` | (same) |
| Token endpoint | `<issuer>/protocol/openid-connect/token` | (same) |
| Userinfo endpoint | `<issuer>/protocol/openid-connect/userinfo` | (same) |
| JWKS endpoint | `<issuer>/protocol/openid-connect/certs` | (same) |
| End-session endpoint | `<issuer>/protocol/openid-connect/logout` | (same) |
| Admin REST API base | `<keycloak-base>/admin/realms/knobby-{env}` | (same pattern) |

**knobby.io application URLs** (registered as Valid Redirect URIs / Valid Post-Logout URIs on `knobby-{env}-web`):

**Deployment topology note:** apex `knobby.io` and `www.knobby.io` are marketing/publisher surfaces only — the actual prod application is deployed at `prod.knobby.io`. Dev application is at `dev.knobby.io`. This split keeps the marketing brand at the apex (where it's expected for SEO, customer trust, and Microsoft publisher domain verification) and the app at a subdomain.

| Purpose | Prod | Dev | Test |
|---------|------|-----|------|
| Sign-in callback | `https://prod.knobby.io/auth/callback` | `https://dev.knobby.io/auth/callback` | `http://localhost:3000/auth/callback` |
| Post-logout landing | `https://prod.knobby.io/` | `https://dev.knobby.io/` | `http://localhost:3000/` |
| Front-channel logout | `https://prod.knobby.io/auth/frontchannel-logout` | `https://dev.knobby.io/auth/frontchannel-logout` | `http://localhost:3000/auth/frontchannel-logout` |
| Back-channel logout | `https://prod.knobby.io/auth/backchannel-logout` | `https://dev.knobby.io/auth/backchannel-logout` | `http://localhost:3000/auth/backchannel-logout` |
| Microsoft admin consent callback | `https://prod.knobby.io/auth/microsoft/admin-consent-callback` | `https://dev.knobby.io/auth/microsoft/admin-consent-callback` | `http://localhost:3000/auth/microsoft/admin-consent-callback` |

### 8.2 OIDC Client Configuration

The `knobby-{env}-web` client in Keycloak has these settings:

| Setting | Value |
|---------|-------|
| Client type | OpenID Connect |
| Client authentication | On (confidential) |
| Authorization | Off (Zanzibar layer handles authz) |
| Standard flow | Enabled (Authorization Code) |
| Direct access grants | Disabled |
| Implicit / hybrid flows | Disabled |
| PKCE | `S256`, required |
| Front-channel logout | Disabled (browser iframes unreliable under modern third-party cookie policy; back-channel is authoritative) |
| Back-channel logout | Enabled, session required, URL set per §8.1 |

The client secret is in `knobby-keycloak-web-client-secret-{env}`.

### 8.3 Token Claims Contract

The ID token and access token issued by Keycloak to the `knobby-{env}-web` client carry these claims. The knobby.io backend MUST validate `iss`, `aud`, `exp`, signature; MAY rely on the rest.

| Claim | Type | Source | Notes |
|-------|------|--------|-------|
| `iss` | string | Keycloak | Equals `https://auth.knobby.io/realms/knobby-{env}` (or `http://localhost:8080/realms/knobby-test`). Validate. |
| `aud` | string | Keycloak | Equals `knobby-{env}-web`. Validate. |
| `exp` | int (unix) | Keycloak | Validate. |
| `iat` | int (unix) | Keycloak | Issuance time. |
| `sub` | string (UUID) | Keycloak | Stable knobby.io user identifier. The primary handle for user records. |
| `email` | string | IdP via Keycloak | Verified email. |
| `email_verified` | bool | IdP | Always `true` in normal flow (per Invariant 2). |
| `name` | string | IdP | Display name. |
| `given_name` | string | IdP | First name. May be missing for some IdPs. |
| `family_name` | string | IdP | Last name. Same caveat. |
| `preferred_username` | string | Keycloak | Usually equals `email`. |
| `idp` | string | Keycloak (session note) | Alias of the IdP that authenticated **this specific session**: `google`, `microsoft-oidc`, `github`, or `saml-<slug>`. **Session fact** — always reflects the current session. |
| `microsoftTenantId` | string (UUID) | Microsoft via Keycloak (user attribute) | Microsoft tenant association persisted on the user record from the most recent Microsoft federation. **User fact, not session fact.** Equals `9188040d-6c67-4c5b-b112-36a304b66dad` for personal MSAs. Present in tokens for any session of a user who has ever federated via Microsoft — including sessions authenticated by a different IdP (e.g., Google), when the user has linked accounts by email. See trust rules below. |
| `microsoftObjectId` | string (UUID) | Microsoft via Keycloak (user attribute) | Same persistence semantics as `microsoftTenantId`. |
| `googleHd` | string (domain) | Google via Keycloak (user attribute) | Google Workspace hosted-domain association persisted on the user record from the most recent Google Workspace federation. **User fact, not session fact** (same semantics as `microsoftTenantId`). Absent for personal Gmail accounts (Google does not emit `hd` for non-Workspace users). |

**Session facts vs. user facts.** The first-broker-login-no-prompt flow (§11.4) auto-links federated identities by email — one Keycloak user record can have Google, Microsoft, and GitHub federated identities all attached. Claims sourced from Keycloak session notes (`idp`) always tell the truth about the **current** session. Claims sourced from user attributes (`microsoftTenantId`, `microsoftObjectId`, and any future per-IdP attributes) reflect the **user's persistent associations**, which may have been set by a different IdP federation than the one driving the current session.

**No `org` claim.** Organization context is determined by knobby.io after token validation, by looking up the user (by `sub`) against application data.

**Trust rules for knobby.io backend:**
- `sub` is the stable user identifier. Never trust `email` alone for user lookup.
- `idp` is authoritative for the current session's authentication source. Use it for any session-scoped authorization decision.
- **`microsoftTenantId` must be combined with `idp == "microsoft-oidc"` for any session-scoped tenant authorization.** Trusting it without first checking `idp` would grant a user signed in via Google the privileges associated with their Microsoft tenant association — an authorization bug. Concretely:

```csharp
// CORRECT: trust microsoftTenantId only when the current session is Microsoft
if (claims["idp"] == "microsoft-oidc"
    && claims.TryGetValue("microsoftTenantId", out var tenantId))
{
    // Apply tenant-scoped logic
}

// WRONG: microsoftTenantId might be a stale association from a prior session
if (claims.TryGetValue("microsoftTenantId", out var tenantId))
{
    // This branch can run for a Google session of a user with a Microsoft history
}
```

- Use `idp` + application policy to gate joining enterprise-tier organizations (e.g., reject `idp=github` from joining an enterprise tier).
- Operations that are inherently Microsoft-scoped by their entry point (e.g., the admin consent callback flow — §12.4) can safely use `microsoftTenantId` without the `idp` check, since the entry point guarantees the session is Microsoft. Document this assumption at every such call site.

### 8.4 ASP.NET Core 10 Integration Pattern

knobby.io's backend integrates with Keycloak via the standard OpenID Connect middleware.

**NuGet packages:**
- `Microsoft.AspNetCore.Authentication.OpenIdConnect`
- `Microsoft.AspNetCore.Authentication.JwtBearer`
- `Microsoft.IdentityModel.Tokens`

**Configuration model** (e.g., `KeycloakOptions.cs`):

```csharp
public class KeycloakOptions
{
    public string Authority { get; set; }             // https://auth.knobby.io/realms/knobby-prod
    public string ClientId { get; set; }              // knobby-prod-web
    public string ClientSecret { get; set; }          // from GCP Secrets Manager
    public string AdminApiClientId { get; set; }      // knobby-prod-admin-api
    public string AdminApiClientSecret { get; set; }  // from GCP Secrets Manager
    public string CallbackPath { get; set; }          // /auth/callback
    public string SignedOutCallbackPath { get; set; } // /auth/logout-callback
    public string FrontChannelLogoutPath { get; set; }    // /auth/frontchannel-logout
    public string BackChannelLogoutPath { get; set; }     // /auth/backchannel-logout
}
```

Loaded from `appsettings.{env}.json` for non-secret values and from environment variables (which knobby.io's infra fills from GCP Secret Manager) for the secrets.

**Program.cs registration sketch:**

```csharp
var keycloak = builder.Configuration.GetSection("Keycloak").Get<KeycloakOptions>();

builder.Services.AddAuthentication(options =>
{
    options.DefaultScheme = CookieAuthenticationDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;
})
.AddCookie(options =>
{
    options.Cookie.Name = "knobby.auth";
    options.Cookie.HttpOnly = true;
    options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    options.Cookie.SameSite = SameSiteMode.Lax;
    options.ExpireTimeSpan = TimeSpan.FromHours(10); // matches Keycloak SSO Session Max
    options.SlidingExpiration = false;
})
.AddOpenIdConnect(options =>
{
    options.Authority = keycloak.Authority;
    options.ClientId = keycloak.ClientId;
    options.ClientSecret = keycloak.ClientSecret;
    options.ResponseType = "code";
    options.UsePkce = true;
    options.SaveTokens = true;
    options.GetClaimsFromUserInfoEndpoint = false;
    options.CallbackPath = keycloak.CallbackPath;
    options.SignedOutCallbackPath = keycloak.SignedOutCallbackPath;
    options.RemoteSignOutPath = keycloak.FrontChannelLogoutPath;

    options.Scope.Clear();
    options.Scope.Add("openid");
    options.Scope.Add("profile");
    options.Scope.Add("email");

    options.TokenValidationParameters = new TokenValidationParameters
    {
        NameClaimType = "preferred_username",
        RoleClaimType = "roles",
        ValidateIssuer = true,
        ValidIssuer = keycloak.Authority,
        ValidateAudience = true,
        ValidAudience = keycloak.ClientId,
        ValidateLifetime = true,
        ClockSkew = TimeSpan.FromSeconds(30)
    };

    options.Events = new OpenIdConnectEvents
    {
        OnTokenValidated = async context =>
        {
            // Required behavior:
            //   1. Read sub, email, idp claims from the validated principal.
            //   2. Look up or create the application-layer user record keyed by sub.
            //   3. Determine the user's organization context from application data
            //      (NOT from a Keycloak claim — see §5.1 and §8.3).
            //   4. Apply application policy (e.g., reject idp=github from
            //      joining enterprise-tier orgs).
            //
            // Implementation note: the user-lookup and org-context-derivation
            // mechanics are application-specific. Use knobby.io's existing user
            // persistence and organization-membership conventions; consult the
            // codebase before introducing new tables or service interfaces.
            var sub = context.Principal.FindFirst("sub")?.Value;
            var idp = context.Principal.FindFirst("idp")?.Value;
            // ... lookup/create application user, attach org context to claims principal
        },
        OnRedirectToIdentityProvider = context =>
        {
            // Forward kc_idp_hint from query string (e.g., set by the "Sign in
            // with Microsoft" button on the knobby.io login page).
            if (context.HttpContext.Request.Query.TryGetValue("idp", out var idp))
            {
                context.ProtocolMessage.SetParameter("kc_idp_hint", idp);
            }
            return Task.CompletedTask;
        }
    };
});
```

**For pure API endpoints** (called by SPA frontend with Bearer token):

```csharp
.AddJwtBearer("Bearer", options =>
{
    options.Authority = keycloak.Authority;
    options.Audience = keycloak.ClientId;
    options.RequireHttpsMetadata = !builder.Environment.IsEnvironment("test");
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidIssuer = keycloak.Authority,
        ValidateAudience = true,
        ValidAudience = keycloak.ClientId,
        ValidateLifetime = true,
        NameClaimType = "preferred_username"
    };
});
```

### 8.5 Backend Callback Endpoints

knobby.io's backend must expose:

**`GET /auth/callback`** — OIDC sign-in callback. Receives `code`, `state`. ASP.NET OIDC middleware handles automatically.

**`GET /auth/logout-callback`** — post-logout callback.

**`POST /auth/backchannel-logout`** — Keycloak-initiated back-channel logout. Receives a `logout_token` JWT. knobby.io validates the signature against the JWKS and the `sid` claim, then invalidates the local session. Implement explicitly. Reference: OIDC Back-Channel Logout 1.0 spec.

**`GET /auth/frontchannel-logout`** — Keycloak-initiated front-channel logout (hidden iframe).

**`GET /auth/microsoft/admin-consent-callback`** — Microsoft admin consent return. See §12.4.

### 8.6 Session & Token Lifecycle

| Token | Lifetime | Action when expired |
|-------|----------|---------------------|
| Access token | 5 minutes | knobby.io refreshes via refresh token. |
| ID token | 5 minutes | Refreshed alongside access token. |
| Refresh token | 30 days (sliding) | When expired, re-authenticate. |
| SSO session idle | 30 minutes | Keycloak invalidates if no activity. |
| SSO session max | 10 hours | Force re-authentication. |
| knobby.io session cookie | 10 hours | Matches SSO Session Max. |

### 8.7 Keycloak Admin REST API — knobby.io Usage Reference

knobby.io's backend authenticates via client credentials grant on `knobby-{env}-admin-api`. Acquire token per request batch (cache for ~4 minutes).

**Token acquisition:**

```
POST https://auth.knobby.io/realms/knobby-{env}/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=knobby-{env}-admin-api
&client_secret=<from knobby-keycloak-admin-api-client-secret-{env}>
```

**Operations** (`<base>` = `https://auth.knobby.io/admin/realms/knobby-{env}`):

| Operation | Method | URL |
|-----------|--------|-----|
| Get user by sub | GET | `<base>/users/{sub}` |
| Find user by email | GET | `<base>/users?email={email}&exact=true` |
| Update user attributes | PUT | `<base>/users/{sub}` |
| Delete user | DELETE | `<base>/users/{sub}` |
| List user sessions | GET | `<base>/users/{sub}/sessions` |
| Revoke specific session | DELETE | `<base>/sessions/{session-id}` |
| Revoke all user sessions | POST | `<base>/users/{sub}/logout` |
| List identity providers | GET | `<base>/identity-provider/instances` |
| Provision per-customer SAML IdP | POST | `<base>/identity-provider/instances` |
| Get specific IdP | GET | `<base>/identity-provider/instances/{alias}` |
| Delete an IdP | DELETE | `<base>/identity-provider/instances/{alias}` |

**No Organizations operations** — Keycloak Organizations is not used (per §5.1 / Invariant 8). Customer↔IdP mapping is persisted in knobby.io's application data, not via Keycloak Organization membership.

Full Keycloak Admin REST API documentation: https://www.keycloak.org/docs-api/latest/rest-api/.

### 8.8 Account Console Disablement

Both built-in account clients disabled per realm:
- `account` — Enabled = Off
- `account-console` — Enabled = Off

### 8.9 AI Agent Authentication (future, parked)

Per the Access Control PRD.

---

## 9. Theming

Per Invariant 3, Keycloak's rare user-facing fallback pages (no `kc_idp_hint`, errors, logout confirmation, session expiry, account linking) are themed to match knobby.io using **Keycloakify**.

**All detailed setup, customization, build, and deployment instructions are in the companion document `KEYCLOAK_THEMING_GUIDE.md`.**

Pages **not** themed: Account Console (disabled), Admin Console (internal-only), Registration/Forgot Password (disabled per Invariant 1).

---

## 10. Operational Considerations

### 10.1 Availability

Keycloak is tier-zero. Run on Cloud Run with `min-instances=2`. Postgres backend on Supabase with HA. Shared prod+dev instance means realm configuration changes flow through OpenTofu IaC (§13) and Keycloak version upgrades are tested in the dev realm in the same instance before reaching prod.

### 10.2 Token Lifetimes

Per §8.6.

### 10.3 Logout Coordination

RP-initiated logout from knobby.io frontend. Back-channel logout from Keycloak to knobby.io backend. Upstream IdP logout is not initiated by Keycloak.

### 10.4 Break-Glass Admin

Break-glass admin lives in the master realm with YubiKey-backed TOTP.

### 10.5 Secrets Management

All secrets follow the convention `knobby-<system>-<purpose>-<credential-type>-{env}` and are stored in GCP Secrets Manager (prod, dev) or developer-local `.env` (test).

| Secret name | Used by | Source |
|-------------|---------|--------|
| `knobby-keycloak-admin-api-client-secret-{env}` | knobby.io backend → Keycloak Admin REST API | Keycloak: `knobby-{env}-admin-api` client credentials |
| `knobby-keycloak-web-client-secret-{env}` | knobby.io backend → Keycloak token endpoint | Keycloak: `knobby-{env}-web` client credentials |
| `knobby-entra-broker-client-secret-{env}` | Keycloak → Microsoft Entra (broker auth) | Entra app registration: client secret (description: `keycloak-broker-{env}`) |
| `knobby-google-oauth-client-secret-{env}` | Keycloak → Google (broker auth) | Google Cloud OAuth client |
| `knobby-github-oauth-client-secret-{env}` | Keycloak → GitHub (broker auth) | GitHub OAuth App |
| `knobby-keycloak-db-password-{env}` | Keycloak → Postgres | Postgres user |

### 10.6 Audit

Keycloak emits events that feed the platform event bus: login success/failure, IdP federation events, user CRUD, session termination, Admin API operations. Custom SPI exporter (future work) pushes to the Postgres transactional outbox.

### 10.7 Microsoft Entra Publisher Verification

Microsoft's risk-based step-up consent policy (effective November 2020) means newly registered multitenant apps without verified-publisher status face cross-tenant consent friction. Mitigated by the admin consent flow (§12).

**Prerequisite — host the publisher domain verification file:**

Microsoft's verification process requires hosting a small JSON file at:

```
https://knobby.io/.well-known/microsoft-identity-association.json
```

with content provided by Microsoft during the verify step (an `associatedApplications` array with the Entra app's `applicationId`). This file proves ownership of `knobby.io` and authorizes the Entra app to claim it as publisher.

Same publisherDomain (`knobby.io`) for both prod and dev Entra apps — the publisher is the company, not the deployment. The file only needs to exist once at the apex; both apps verify against the same file.

**Hosting recommendation:** since the apex of `knobby.io` may not yet have a marketing site, the simplest path is a minimal Cloudflare Pages site (or Worker) serving at least `.well-known/microsoft-identity-association.json`. Same hosting later supports other `.well-known` files (Apple, security.txt, etc.).

**Verification steps:**
- Start Microsoft AI Cloud Partner Program enrollment (multi-day lead time).
- Once Partner One ID is issued, submit publisher verification on the prod Entra app registration.
- Skip for dev/test.

### 10.8 Naming Convention Reference

Authoritative table. The OpenTofu IaC (§13) reads from this table.

| Resource | Convention | Example (prod) |
|----------|-----------|----------------|
| Realm name | `knobby-{env}` | `knobby-prod` |
| Web OIDC client ID | `knobby-{env}-web` | `knobby-prod-web` |
| Admin API client ID | `knobby-{env}-admin-api` | `knobby-prod-admin-api` |
| Keycloak hostname (prod, dev) | `auth.knobby.io` | `auth.knobby.io` |
| Keycloak hostname (test) | `localhost:8080` (HTTP) | `localhost:8080` |
| Realm OIDC issuer (prod, dev) | `https://auth.knobby.io/realms/knobby-{env}` | `https://auth.knobby.io/realms/knobby-prod` |
| Realm OIDC issuer (test) | `http://localhost:8080/realms/knobby-test` | `http://localhost:8080/realms/knobby-test` |
| Google IdP alias | `google` | `google` |
| Microsoft IdP alias | `microsoft-oidc` | `microsoft-oidc` |
| GitHub IdP alias | `github` | `github` |
| SAML IdP alias pattern | `saml-<customer-slug>` | `saml-acme-corp` |
| Google broker redirect URI | `<issuer>/broker/google/endpoint` | `https://auth.knobby.io/realms/knobby-prod/broker/google/endpoint` |
| Microsoft broker redirect URI | `<issuer>/broker/microsoft-oidc/endpoint` | `https://auth.knobby.io/realms/knobby-prod/broker/microsoft-oidc/endpoint` |
| GitHub broker redirect URI | `<issuer>/broker/github/endpoint` | `https://auth.knobby.io/realms/knobby-prod/broker/github/endpoint` |
| Keycloak admin API secret | `knobby-keycloak-admin-api-client-secret-{env}` | `knobby-keycloak-admin-api-client-secret-prod` |
| Keycloak web client secret | `knobby-keycloak-web-client-secret-{env}` | `knobby-keycloak-web-client-secret-prod` |
| Entra broker secret | `knobby-entra-broker-client-secret-{env}` | `knobby-entra-broker-client-secret-prod` |
| Google OAuth secret | `knobby-google-oauth-client-secret-{env}` | `knobby-google-oauth-client-secret-prod` |
| GitHub OAuth secret | `knobby-github-oauth-client-secret-{env}` | `knobby-github-oauth-client-secret-prod` |
| Keycloak DB password | `knobby-keycloak-db-password-{env}` | `knobby-keycloak-db-password-prod` |
| Entra app displayName (prod) | `knobby.io Keycloak Broker` (no env suffix; capital K, lowercase c in Keycloak) | `knobby.io Keycloak Broker` |
| Entra app displayName (dev/test) | `knobby.io Keycloak Broker ({env}[ - {dev}])` | `knobby.io Keycloak Broker (dev)` |
| Entra publisherDomain | `knobby.io` (same for all envs) | `knobby.io` |
| Entra secret description | `keycloak-broker-{env}` | `keycloak-broker-prod` |
| knobby.io app hostname (prod) | `prod.knobby.io` | `prod.knobby.io` |
| knobby.io app hostname (dev) | `dev.knobby.io` | `dev.knobby.io` |
| knobby.io app hostname (test) | `localhost:3000` | `localhost:3000` |
| knobby.io marketing hostname | `knobby.io` (apex; also `www.knobby.io`) — used only as publisher domain identity, not for OAuth callbacks | `knobby.io` |
| knobby.io OIDC callback URL | `https://{app-hostname}/auth/callback` | `https://prod.knobby.io/auth/callback` |
| knobby.io backchannel logout URL | `https://{app-hostname}/auth/backchannel-logout` | `https://prod.knobby.io/auth/backchannel-logout` |
| knobby.io MS admin consent callback | `https://{app-hostname}/auth/microsoft/admin-consent-callback` | `https://prod.knobby.io/auth/microsoft/admin-consent-callback` |
| Keycloak theme name | `knobby` | `knobby` |

---

## 11. Setup Runbook — Fresh Realm Configuration

Currently manual; will be superseded by the OpenTofu IaC per §13 once available.

Prerequisites: Keycloak 26.x deployed; per-environment IdP credentials created per §10.8; for the theme, the `knobby` theme JAR baked into the Keycloak image per `KEYCLOAK_THEMING_GUIDE.md`.

Execute in **dev first**, then **prod**. Test setup per §11.15 on each developer's machine.

**Ordering note:** flows (§11.4–11.6) and Required Actions (§11.7) before IdPs (§11.8–11.11).

### 11.1 Create the Realm

1. Log into Keycloak admin console as master realm admin.
2. Realm dropdown → **Create realm**.
3. Realm name: `knobby-{env}`.
4. Enabled: On. Click **Create**.

### 11.2 Configure Realm Settings

**Realm settings → Login tab:** User registration Off, Forgot password Off, Remember me Off, Email as username On, Login with email On, Duplicate emails Off, Verify email Off, Edit username Off.

**Realm settings → Email tab:** Leave unconfigured.

**Realm settings → Themes tab:** Login `keycloak` for now (will switch to `knobby` after theme is built per §11.14). Admin `keycloak.v2`.

**Realm settings → Tokens tab:** Access Token 5 min; SSO Idle 30 min; SSO Max 10 hrs; Revoke Refresh Token On; Refresh Token Max Reuse 0.

**Realm settings → Security defenses:** Brute Force Detection On; X-Frame-Options DENY; HSTS Max Age 31536000 (skip HSTS for test).

**Organizations:** leave **Off** (per Invariant 8). The realm does not use Keycloak Organizations.

### 11.3 Create OIDC Web Client

1. **Clients → Create client**. Client type: OIDC. Client ID: `knobby-{env}-web`.
2. Client authentication: On. Authorization: Off. Standard flow only.
3. Root URL, redirect URIs, post-logout URIs per §8.1.
4. **Credentials tab:** copy secret to `knobby-keycloak-web-client-secret-{env}`.
5. **Settings tab → Logout settings (near bottom of Settings tab in Keycloak 26.x):**
   - **Front channel logout: Off** (intentionally — browser third-party cookie policies make front-channel iframe logout unreliable; back-channel is the authoritative mechanism)
   - Toggling Front channel logout to Off causes the panel to switch to back-channel fields. If they don't appear, that's a UI bug in your Keycloak version; fall back to the Admin REST API.
   - Backchannel logout URL: per §8.1 (e.g., `https://prod.knobby.io/auth/backchannel-logout`)
   - Backchannel logout session required: On (so the `logout_token` carries the `sid` claim, enabling precise session targeting)
   - Backchannel logout revoke offline sessions: Off (this realm doesn't issue offline tokens to interactive users)
6. **Advanced tab → Proof Key for Code Exchange Code Challenge Method:** `S256`.

### 11.3b Configure Protocol Mappers on `knobby-{env}-web`

Keycloak's default token output doesn't include the claims §8.3 specifies. Three mappers must be added to the client's dedicated client scope (`knobby-{env}-web-dedicated`) to produce the expected token shape.

**Navigation:** Clients → `knobby-{env}-web` → Client scopes tab → click `knobby-{env}-web-dedicated` → Mappers tab → Add mapper → By configuration.

**Mapper 1 — Audience** (fixes `aud=account` quirk; without this, the access_token's audience won't include the client and ASP.NET Core JWT validation will reject it):

| Field | Value |
|---|---|
| Mapper Type | Audience |
| Name | `knobby-{env}-web-audience` |
| Included Client Audience | `knobby-{env}-web` |
| Included Custom Audience | *(blank)* |
| Add to ID token | Off (id_token's `aud` is set by OIDC protocol) |
| Add to access token | **On** |
| Add to lightweight access token | Off |
| Add to token introspection | On |

**Mapper 2 — `idp` claim** (User Session Note mapper that exposes which IdP brokered the user):

| Field | Value |
|---|---|
| Mapper Type | User Session Note |
| Name | `idp-claim` |
| User Session Note | `identity_provider` |
| Token Claim Name | `idp` |
| Claim JSON Type | String |
| Add to ID token | **On** |
| Add to access token | **On** |
| Add to token introspection | On |

**Mapper 3 — `microsoftTenantId` claim** (User Attribute mapper; pairs with the `tid` Attribute Importer on the Microsoft IdP from §11.9):

| Field | Value |
|---|---|
| Mapper Type | User Attribute |
| Name | `microsoft-tenant-id-claim` |
| User Attribute | `microsoftTenantId` |
| Token Claim Name | `microsoftTenantId` |
| Claim JSON Type | String |
| Add to ID token | **On** |
| Add to access token | **On** |
| Add to userinfo | On |
| Add to token introspection | On |
| Multivalued | Off |
| Aggregate attribute values | Off |

This claim is present in tokens for any user who has **ever** federated via Microsoft (because the `microsoftTenantId` user attribute is persisted on their Keycloak user record). It is **not** a session-level claim — if the same user later signs in via Google with the same email, the auto-linking flow (§11.4) attaches the Google identity to the existing user, and tokens from that Google session will still carry `microsoftTenantId` from the prior Microsoft federation. See §8.3 trust rules for the application-level interpretation discipline this requires.

**Mapper 4 — `googleHd` claim** (User Attribute mapper; pairs with the `hd` Attribute Importer on the Google IdP from §11.8):

| Field | Value |
|---|---|
| Mapper Type | User Attribute |
| Name | `google-hd-claim` |
| User Attribute | `googleHd` |
| Token Claim Name | `googleHd` |
| Claim JSON Type | String |
| Add to ID token | **On** |
| Add to access token | **On** |
| Add to userinfo | On |
| Add to token introspection | On |
| Multivalued | Off |
| Aggregate attribute values | Off |

Same user-fact-not-session-fact semantics as Mapper 3 — `googleHd` is persisted on the user record from any prior Google Workspace federation, so it can appear in tokens from non-Google sessions of cross-IdP-linked users. The §8.3 trust rules require combining `idp == "google"` AND `googleHd` for session-scoped tenant authorization.

### 11.4 Create `first-broker-login-no-prompt` Authentication Flow

Duplicate the built-in `first broker login` flow. The default flow's structure (with the sub-flows expanded) is roughly:

```
first broker login
├── Review Profile                          [Required]
└── User Creation Or Linking                [Required, sub-flow]
    ├── Create User If Unique               [Alternative]
    └── Handle Existing Account             [Alternative, sub-flow]
        ├── Confirm Link Existing Account   [Required]
        └── Account Verification Options    [Required, sub-flow]
            ├── Verify Existing Account By Email           [Alternative]
            └── Verify Existing Account By Re-auth         [Alternative]
```

Modify the duplicate so the final structure is:

```
first-broker-login-no-prompt
├── Review Profile                          [Disabled]    ← change from Required
├── Conditional 2FA                         [Disabled]    ← change from Conditional (Invariant 2: upstream IdP authoritative for MFA)
├── Conditional Organization                [Disabled]    ← change from Conditional (Invariant 8: Keycloak Organizations not used)
└── User Creation Or Linking                [Required, sub-flow]
    ├── Create User If Unique               [Alternative]
    └── Handle Existing Account             [Alternative, sub-flow]
        ├── Automatically Set Existing User [Required]    ← ADD this step inside Handle Existing Account
        ├── Confirm Link Existing Account   [Disabled]    ← change from Required
        └── Account Verification Options    [Disabled, sub-flow]
            ├── Verify Existing Account By Email           [Disabled]
            └── Verify Existing Account By Re-auth         [Disabled]
```

**Notes on the Conditional sub-flows:**

In Keycloak 26.x, the default `first broker login` flow includes two `Conditional` sub-flows that didn't exist in older versions: `Conditional 2FA` and `Conditional Organization`. "Conditional" means the sub-flow runs only if its inner `Condition - User Configured` step evaluates true. In our setup, both conditions would naturally evaluate false (we don't manage OTP at Keycloak; we don't use Organizations), so leaving them as Conditional would be functionally fine. **We still set them to Disabled** to make the architectural intent explicit — a future operator (or `tofu plan`) should not have to reason about whether some condition might fire; they should see "this is off" and move on.

**Critical: `Automatically Set Existing User` must be added INSIDE the `Handle Existing Account` sub-flow, not at the top level.** This authenticator runs after a previous step has identified that an existing user matches the federated identity by email — it then auto-links without prompting. Placed at the top level for a brand-new federated login (no existing match yet), it has nothing to do and will fail the flow because it's Required.

Resulting behavior:
- **New user (no email match)**: `Create User If Unique` runs (Alternative), succeeds by creating a new user, the parent sub-flow completes. `Handle Existing Account` is skipped (Alternative-after-success).
- **Existing user (email match)**: `Create User If Unique` runs, fails (user already exists), Keycloak tries the next Alternative which is `Handle Existing Account`. Inside that, `Automatically Set Existing User` auto-links the federated identity to the existing local user without prompting.

Either path completes silently — that's the "no prompt" promise of the flow name.

### 11.5 Create `browser-federated-only` Authentication Flow

Duplicate the built-in `browser` flow. The picker UI (the IdP buttons) lives in the `login.ftl` template, which is rendered by the **Forms** authenticator. If Forms is Disabled, the template never renders and there is no picker — the flow fails with "Invalid username or password" when no IdP hint is supplied. So we keep Forms enabled but rely on the fact that no user in this realm has a password (every user is federated) to make username/password authentication impossible in practice.

Final structure:

```
browser-federated-only
├── Cookie                                [Alternative]
├── Kerberos                              [Disabled]
├── Identity Provider Redirector          [Alternative]   (was Required in default; Alternative lets Forms be the fallback)
├── Browser - Conditional Organization    [Disabled]      (Invariant 8: Keycloak Organizations not used)
└── Forms                                 [Alternative, sub-flow]
    ├── Username Password Form            [Required]      (leave as-is; no user has a password, so this can never succeed)
    └── Browser - Conditional OTP / 2FA   [Disabled]      (Invariant 2: upstream IdP authoritative for MFA)
```

Like in §11.4, the Conditional sub-flows in Keycloak 26.x's default browser flow would skip naturally at runtime (their inner Condition checks evaluate false in our setup). We disable them explicitly for the same reason: easier to audit, no implicit behavior to reason about.

**How this routes:**
- With `kc_idp_hint=<provider>` in the URL: Identity Provider Redirector succeeds by redirecting to that IdP. Flow ends. (This is the normal knobby.io-initiated path.)
- Without any hint (fallback): Identity Provider Redirector returns ATTEMPTED (neutral — no hint, no default). Flow tries the next Alternative — Forms — which renders the standard Keycloak login template. That template includes the IdP buttons in the social section. User clicks one → goes through Identity Provider Login → federation proceeds. The username/password fields visible on the page are cosmetic dead weight; no user has a password to submit.
- Until the Keycloakify theme is installed, the fallback page will show those visible-but-useless username/password fields alongside the IdP buttons. That's acceptable — clicking an IdP button works.

### 11.5b Make `firstName` and `lastName` Optional in User Profile

Keycloak 26.x's User Profile feature requires `firstName` and `lastName` on every user by default. Federated identities from upstream IdPs (especially Microsoft personal accounts) often omit these claims, which triggers a `UPDATE_PROFILE` required action that prompts the user with an "Update Account Information" form — a violation of Invariant 3 (users never see Keycloak).

knobby.io stores user names in its own database (Invariant 8), so Keycloak doesn't need these fields. Make them optional:

1. Realm settings → User Profile tab → Attributes
2. Edit `firstName` → Permission → uncheck **Required** for both User and Admin contexts → Save
3. Edit `lastName` → same change → Save

After this, federated users with no name claims are created silently with empty `firstName`/`lastName`, and Keycloak does not prompt them.

### 11.6 Bind the Custom Browser Flow

Open `browser-federated-only` → Action menu → Bind flow → Browser flow → Save.

### 11.7 Configure Required Actions

All actions → Default Action Off (Configure OTP, Update Password, Update Profile, Verify Email, Verify Profile, Terms and Conditions, Delete Account, etc.).

### 11.8 Add Google as IdP

1. **Identity Providers → Add → Google.** Alias `google`.
2. Client ID, Client Secret from `knobby-google-oauth-client-secret-{env}`.
3. **Settings → Advanced:** Trust Email On, **First Login Flow `first-broker-login-no-prompt`**, Sync Mode `force`, Store Tokens Off, Hide on Login Page Off.
4. **Mappers tab → Add mapper:**

| Field | Value |
|---|---|
| Name | `google-hd` |
| Sync Mode Override | `inherit` |
| Mapper Type | Attribute Importer |
| Claim | `hd` |
| User Attribute Name | `googleHd` |

This captures Google's `hd` (hosted domain) claim and stores it as user attribute `googleHd` on the Keycloak user record. Google emits `hd` only for Google Workspace accounts; personal Gmail logins don't set this attribute. The §11.3b client-side User Attribute mapper (Mapper 4) exposes this attribute as the `googleHd` token claim.

### 11.9 Add Microsoft Entra as IdP

Per §6.3. Configured via generic OpenID Connect v1.0 provider (not built-in Microsoft). **Alias: `microsoft-oidc`** (immutable once set — choose carefully).

**Entra app registration:**
1. Entra admin center → App registrations → New registration.
2. Name per §6.3 / §10.8 — confirm spelling `Keycloak` (not `KeyCloak`); no env suffix on prod.
3. Multitenant + personal MSAs ("Accounts in any organizational directory and personal Microsoft accounts").
4. Redirect URI per §10.8 (`<issuer>/broker/microsoft-oidc/endpoint`).
5. **Branding & properties:** add logo, **publisherDomain `knobby.io`** (NOT a per-env subdomain), TOS URL, Privacy URL.
6. **Certificates & secrets → New client secret.** Description: `keycloak-broker-{env}`. Expiry 24 months. Store value as `knobby-entra-broker-client-secret-{env}`.
7. **API permissions:** Microsoft Graph delegated → `openid`, `profile`, `email`, `offline_access`, `User.Read`. Grant admin consent.
8. **Publisher domain verification:** before Microsoft can verify `knobby.io` as the publisher, the file `https://knobby.io/.well-known/microsoft-identity-association.json` must be hosted at the apex with the JSON contents Microsoft provides during verify. See §10.7.

**Keycloak config:**
9. Identity Providers → Add → OpenID Connect v1.0. **Alias `microsoft-oidc`**.
10. Discovery endpoint: `https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration`.
11. Client ID, secret from Entra (from steps 1 and 6).
12. Default Scopes: `openid profile email`.
13. **Issuer field: empty** (multi-tenant `{tenantid}` placeholder workaround).
14. Validate Signatures On. Use JWKS URL On. Allowed clock skew 0.
15. Accepts prompt=none forward On.
16. **Forwarded Query Parameters: `login_hint,domain_hint,prompt`**.
17. Trust Email On. **First Login Flow `first-broker-login-no-prompt`**. Sync Mode `force`.

**Mappers:**
18. Attribute Importer: claim `tid` → user attribute `microsoftTenantId`.
19. Attribute Importer: claim `oid` → user attribute `microsoftObjectId`.
20. Username Template Importer: template `${CLAIM.email}` (avoids `#EXT#` suffix for guest users).

### 11.10 Add GitHub as IdP

**Prerequisite — GitHub OAuth App (per environment):**

1. GitHub → Settings → Developer settings → OAuth Apps → New OAuth App.
2. Configure per §6.4.
3. Register, generate client secret, store as `knobby-github-oauth-client-secret-{env}`.

**Keycloak config:**

4. **Identity Providers → Add → GitHub.** Alias `github`.
5. Client ID and Client Secret from steps 1 and 3.
6. **Settings tab → Advanced:**
   - Default Scopes: `user:email read:user`
   - Trust Email: On
   - **First Login Flow: `first-broker-login-no-prompt`**
   - Sync Mode: `force`
   - Store Tokens: Off
   - Hide on Login Page: Off

**Mapper:** Attribute Importer: claim `email` → user attribute `email`.

### 11.11 Add Customer SAML IdP (template, per customer)

Performed once per enterprise customer, ideally via Admin API automation. Manual:

1. Obtain customer's SAML metadata XML.
2. Identity Providers → Add → SAML v2.0. Alias `saml-<customer-slug>`.
3. Use entity descriptor: Import metadata XML.
4. NameID policy format: `emailAddress`.
5. Want AuthnRequests Signed On, Want Assertions Signed On, Validate Signature On.
6. **First Login Flow: `first-broker-login-no-prompt`**. Sync Mode `force`.
7. **No link to a Keycloak Organization** (Invariant 8). The mapping from this IdP alias to a knobby.io Organization is recorded in knobby.io's application data (see §12.10).

### 11.12 Disable Account Console

Clients → `account-console` Enabled Off; `account` Enabled Off. Verify URLs return 404.

### 11.13 Create Admin API Service Account Client

1. **Clients → Create client.** Client ID: `knobby-{env}-admin-api`. Client authentication On. Service accounts roles On. All flows Off.
2. **Service accounts roles tab → Assign role** → modal **Filter by clients** → search `realm-management` → assign the following client roles:

   ```
   view-users
   manage-users
   view-realm
   view-clients
   query-users
   query-groups
   view-identity-providers
   manage-identity-providers
   ```

3. **Credentials tab:** copy secret to `knobby-keycloak-admin-api-client-secret-{env}`.

**Notes on the role list:**
- This list has evolved across PRD revisions. If updating an existing service account from an earlier PRD version, re-check that all the above roles are assigned (in particular `view-identity-providers`, `manage-identity-providers`, and `view-clients` were added in later revisions).
- `view-clients` is read-only and is needed for: (a) the smoke test's client configuration validation (Tests 11–12), (b) future OpenTofu drift detection (`tofu plan` needs to read current client state), (c) general realm administration via the Admin API. It does not grant write access; the corresponding write role `manage-clients` is intentionally not assigned because knobby.io's backend does not manage clients at runtime — clients are static IaC.
- **Do not assign** `view-organizations` or `manage-organizations` — these role names do not exist as standalone client roles in current Keycloak 26.x. Earlier PRD revisions listed them in error.
- **Do not assign** `manage-realm` — not needed without Keycloak Organizations (which we don't use per §5.1 / Invariant 8). If a 403 surfaces from any Admin API call knobby.io makes, the fix is to identify the specific missing role from the realm-management role list, not to escalate to `manage-realm`.
- **Do not assign** `manage-clients`, `create-client`, or `realm-admin` — over-privileged for our use case; the smoke test Test 12 will warn if any of these are present.

### 11.14 Apply the knobby Theme

After the theme JAR has been built and deployed per `KEYCLOAK_THEMING_GUIDE.md`:

1. **Realm settings → Themes → Login Theme:** select `knobby`.
2. Save.
3. Verify by hitting a fallback Keycloak-rendered page.

### 11.15 Test Environment Setup (Developer Local)

The `test` environment runs on each developer's machine.

**1. Docker Compose** at `docker-compose.test.yml`:

```yaml
version: '3.9'
services:
  postgres-keycloak:
    image: postgres:16
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
    volumes:
      - postgres-keycloak-data:/var/lib/postgresql/data
    ports:
      - "5433:5432"

  keycloak:
    build:
      context: ./keycloak
      dockerfile: Dockerfile
    command: start-dev
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres-keycloak:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
      KC_HOSTNAME_STRICT: false
      KC_HOSTNAME: localhost
      KC_HTTP_ENABLED: true
    ports:
      - "8080:8080"
    depends_on:
      - postgres-keycloak

volumes:
  postgres-keycloak-data:
```

(Note: no `--features=organization` flag — Organizations is not used.)

**2. Dockerfile** at `keycloak/Dockerfile`:

```dockerfile
FROM quay.io/keycloak/keycloak:26.0 AS builder

# (Future) knobby Keycloakify theme JAR added here per KEYCLOAK_THEMING_GUIDE.md.
# COPY --chown=keycloak:keycloak ./themes/knobby-theme.jar /opt/keycloak/providers/

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
EXPOSE 8080
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

**3. Developer-local `.env` file** (gitignored):

```
KEYCLOAK_DB_PASSWORD=<random>
KEYCLOAK_ADMIN_PASSWORD=<random>
KNOBBY_KEYCLOAK_ADMIN_API_CLIENT_SECRET_TEST=<from-keycloak-after-setup>
KNOBBY_KEYCLOAK_WEB_CLIENT_SECRET_TEST=<from-keycloak-after-setup>
KNOBBY_ENTRA_BROKER_CLIENT_SECRET_TEST=<from-entra-app-registration>
KNOBBY_GOOGLE_OAUTH_CLIENT_SECRET_TEST=<from-gcp-oauth-client>
KNOBBY_GITHUB_OAUTH_CLIENT_SECRET_TEST=<from-github-oauth-app>
```

**4. Per-developer IdP OAuth registrations** with `http://localhost:8080/...` redirect URIs.

**5. Run:**

```bash
docker-compose -f docker-compose.test.yml up -d --build
```

Then follow §§11.1–11.14 substituting `knobby-test` and `localhost:8080` URLs. Skip §11.9 step 8 (publisher domain verification) — Microsoft does not verify localhost.

**6. Smoke test:**

```bash
export KNOBBY_ENV=test
export ADMIN_CLIENT_SECRET="$KNOBBY_KEYCLOAK_ADMIN_API_CLIENT_SECRET_TEST"
./keycloak-smoke-test.sh
```

### 11.16 Verification Checklist

The smoke-test script `keycloak-smoke-test.sh` automates server-side tests (1–13) and prints URLs for browser-driven federation tests (14–19).

Automated coverage:
- Test 1: realm liveness via `.well-known/openid-configuration`
- Test 2–3: account console disabled (`/realms/knobby-{env}/account` returns 4xx)
- Test 4: admin API client credentials grant works (functional)
- Test 5: admin API list users (validates `view-users`/`query-users` roles)
- Test 6: list IdPs (validates `view-identity-providers` role; classifies IdPs by `providerId` + URL pattern so the generic-OIDC Microsoft setup is recognized regardless of alias)
- Test 7: browser flow binding is `browser-federated-only`
- Test 8: no Required Actions set as Default
- Test 9: GCP Secrets Manager — every expected secret name from §10.8 exists; warning on misnamed orphans
- Test 10: Microsoft Entra app registration — displayName matches convention, signInAudience is multi-tenant + MSA, redirect URI registered, publisherDomain is `knobby.io`, Graph API permissions present, client secret not expired (warn within 30 days), secret description follows convention
- Test 11: `knobby-{env}-web` client configuration — protocol/confidentiality/flow flags per §8.2, PKCE method = S256, front-channel + back-channel logout configured, expected redirect URI registered
- Test 12: `knobby-{env}-admin-api` client configuration — flow flags (service accounts on; all interactive flows off), service-account user present, exact realm-management role list assigned per §11.13 (no missing roles, no over-privileged roles like `realm-admin`/`manage-realm`/`manage-clients`/`create-client`)
- Test 13: PKCE enforcement (behavioral) — sends auth request without `code_challenge`, verifies Keycloak rejects it with the expected `error=invalid_request` referencing `code_challenge_method`; catches the case where the PKCE attribute is set in config but not actually enforced

Manual coverage:
- Test 14: fallback IdP picker (no `kc_idp_hint`) — themed login page with all configured IdP buttons
- Tests 15–17: direct-to-IdP routing per alias for Google, Microsoft work account, Microsoft personal MSA
- Test 18: GitHub federation
- Test 19: token exchange — decode resulting id_token, verify claim contract per §8.3

---

## 12. Enterprise Tenant Onboarding

For each enterprise customer, three things must happen: a knobby.io Organization exists, the customer's IdP is connected (via Microsoft admin consent / Google Workspace allowlist / SAML metadata exchange), and users can then sign in.

**Implementation note throughout this section:** sub-sections describe the *required behavior and persisted state* for tenant onboarding. They do not prescribe specific table names, column types, or storage choices. Map each requirement to knobby.io's existing data model. Consult the codebase before introducing new persistence — knobby.io may already have organization, user, or tenant-connection structures that should be extended rather than duplicated.

### 12.1 Pattern & Rationale

1. **A knobby.io Organization exists** (created during customer signup).
2. **The customer's IdP is connected to that Organization.** Mechanics differ per IdP family:
   - Microsoft Entra: admin consent.
   - Google Workspace: customer Workspace admin allowlists OAuth client.
   - SAML: customer configures knobby.io's SP metadata; knobby.io provisions a SAML IdP entry in Keycloak via Admin REST API.
3. **Users from the customer's IdP can sign in.**

### 12.2 Microsoft Admin Consent Endpoint

```
https://login.microsoftonline.com/{tenant}/adminconsent
  ?client_id={knobby-prod-entra-app-id}
  &state={knobby-state-token}
  &redirect_uri=https://prod.knobby.io/auth/microsoft/admin-consent-callback
```

`{tenant}` is typically `organizations` (unknown tenant) or the tenant GUID/domain. Not `common`.

### 12.3 State Token Persistence Requirement

knobby.io's backend must persist short-lived state for each in-flight Microsoft admin consent attempt.

**Required logical fields:**

| Field | Purpose |
|---|---|
| state token | High-entropy random value (≥32 bytes base64url). Used as the OAuth `state` parameter for CSRF protection and callback correlation. Serves as the lookup key. |
| initiating organization | Reference to the knobby.io Organization on whose behalf consent is being granted. |
| initiating user | Reference to the knobby.io user who clicked Connect (for audit trail). |
| expected tenant ID | Optional. If the customer has supplied their Microsoft tenant in advance, store it here to validate the callback's `tenant` parameter against it. |
| created at | Timestamp. |
| expires at | Timestamp. Records are short-lived (10 minutes from creation). |
| consumed at | Timestamp, nullable. Set when the callback successfully completes consent. Prevents replay. |

**Lifecycle:**
- Created when an org admin clicks "Connect Microsoft 365" in knobby.io.
- Read once on callback receipt; validated for non-expiry, non-consumption, and (if `expected tenant ID` set) tenant match.
- On successful processing: `consumed at` set; the durable tenant connection (§12.4) is created.
- Expired/unused records can be cleaned up periodically.

*Implementation note: storage choice (relational, KV, cache) and naming are at the implementer's discretion. The records are short-lived and not historically interesting — relational storage with periodic cleanup is fine; a TTL-based KV is also fine.*

### 12.4 Tenant Connection Persistence Requirement

After a successful admin consent, knobby.io's backend must persist a durable record linking the knobby.io Organization to the Microsoft tenant.

**Required logical fields:**

| Field | Purpose |
|---|---|
| knobby organization | Reference to the knobby.io Organization. |
| Microsoft tenant ID | The tenant GUID received from Microsoft's callback. |
| consent granted at | Timestamp. |
| consent granted by | Identifier (email or user reference) of the admin who consented. |
| consent revoked at | Timestamp, nullable. Soft-delete marker when consent is withdrawn (either via Microsoft-side revocation detected reactively, or via knobby.io self-service disconnect). |

**Identity:** the natural key is (knobby organization, Microsoft tenant ID). One knobby.io Organization may be associated with multiple Microsoft tenants (subsidiaries, M&A). The reverse lookup — given a Microsoft tenant ID, find the connected knobby.io Organization — is the hot path during sign-in routing (§12.9).

**Lifecycle:**
- Created on successful admin consent callback.
- `consent revoked at` set when revocation is detected or initiated.
- Records are not hard-deleted (audit history preservation).

*Implementation note: storage choice and naming at implementer's discretion. Active-only queries should be indexed on Microsoft tenant ID with `consent revoked at IS NULL`.*

### 12.5 Callback Handler Requirements

The endpoint `GET /auth/microsoft/admin-consent-callback` receives two response shapes from Microsoft.

**Success:** `?admin_consent=True&tenant=<guid>&state=<token>`.

**Failure:** `?error=<code>&error_description=<text>&error_subcode=<sub>&state=<token>`.

Handler behavior:

1. Parse `state`. Look up the corresponding in-flight consent record (§12.3).
2. Reject (400) if: record absent, already consumed, or expired.
3. If `error` present: mark consumed, log with full context, render error page to the admin with a user-friendly message based on the error code (§12.7).
4. If `admin_consent=True`:
   - Validate `tenant` is a valid GUID. If the in-flight record had an `expected tenant ID`, confirm it matches.
   - In a transaction: create or upsert the tenant connection record (§12.4); mark the in-flight record consumed.
   - Emit `OrganizationMicrosoftTenantConnected` Activity to the platform event bus.
5. Redirect admin to the Organization Settings → Identity page with a success confirmation.

### 12.6 End-to-End Flow

Admin in Organization Settings → Identity → "Connect Microsoft 365" → Continue → knobby.io creates in-flight consent record, redirects to Microsoft admin consent → admin signs in and accepts → redirect back to knobby.io callback → state validated → tenant connection persisted → success page shown. Subsequent sign-ins from any user in that Microsoft tenant work silently through the standard login flow.

### 12.7 Error Handling

| Scenario | Detection | UX |
|----------|-----------|-----|
| Admin not Global Admin | `error=access_denied&error_subcode=user_consent_required` | "Ask your Global Administrator to complete this step." |
| Admin clicks Cancel | `error=access_denied` | "Connection canceled." |
| State token expired (>10 min) | knobby.io detects via §12.3 record `expires at` | "Consent session expired. Try again." |
| State already consumed | knobby.io detects via §12.3 record `consumed at` set | "Link already used. Start over." Log warning. |
| Tenant mismatch | knobby.io detects when §12.3 `expected tenant ID` set and doesn't match callback | "Sign in with an account from {expected-domain}." |
| Customer tenant blocks consent | Various Microsoft errors | "Your tenant's policies prevent third-party consent. Contact IT." |
| Microsoft endpoint timeout | knobby.io timeout | "Couldn't complete connection. Try again." |

### 12.8 Consent Revocation

Microsoft does not notify on revocation. Detect reactively when federation fails for a known-connected tenant (`microsoft_tenant_id` matches a §12.4 record with no `consent revoked at`); mark `consent revoked at`, emit `OrganizationMicrosoftTenantDisconnected` Activity.

knobby.io should also provide self-service disconnect in Organization Settings → Identity, which calls Microsoft Graph to revoke the service principal in the customer tenant and marks the §12.4 record revoked.

### 12.9 Sign-in Routing

Strategy B (email-first home discovery) is the production target. Requires:
- A background job that fetches verified domains for each connected Microsoft tenant via Graph API (`GET /organization` + `GET /domains`), persisted in knobby.io application data linked to the §12.4 tenant connection. Refresh cadence ~24 hours.
- The login screen email-first flow.
- The Microsoft IdP's Forwarded Query Parameters set to `login_hint,domain_hint,prompt` per §11.9 step 16.
- Fallback to "Sign in with personal Microsoft account" button for users whose domain doesn't match any connected tenant.

*Implementation note: the verified-domain cache is application-layer state. Storage choice (table, columns, indexing) is at the implementer's discretion. The hot-path query is "given an email domain, find the connected Microsoft tenant and the corresponding knobby.io Organization."*

**Personal MSA handling.** Personal Microsoft accounts (`microsoftTenantId == 9188040d-6c67-4c5b-b112-36a304b66dad`) are not associated with any enterprise tenant. They sign in via the Microsoft IdP but are rejected at the application authorization layer when attempting to join an enterprise Organization.

### 12.10 Analogous Patterns for Other IdPs

**Google Workspace.**

Customer Workspace admin allowlists the per-env knobby.io Google OAuth client ID in their Google Admin Console (Security → API controls → App access control → Configure new app). No OAuth-protocol-level admin consent flow exists — it's a manual setup step in the customer's admin UI.

*Persistence requirement:* knobby.io must record the connection between a knobby.io Organization and the customer's Google Workspace, with: knobby organization, Workspace domain, verified-at timestamp, verified-by reference. Lifecycle: created when an admin self-attests the allowlisting is done and knobby.io confirms via a successful test sign-in by the admin. Soft-delete on disconnect.

**SAML enterprise customers.**

Two-way metadata exchange. knobby.io provides the customer with its SP metadata (downloadable from Organization Settings → Identity → SAML, or via direct link to Keycloak's metadata endpoint). The customer configures their IdP, then provides knobby.io with their IdP metadata XML (uploaded via the settings UI). knobby.io backend then calls Keycloak Admin REST API (§8.7) to provision a SAML IdP entry with alias `saml-<customer-slug>` at the realm level (not linked to a Keycloak Organization per Invariant 8).

*Persistence requirement:* knobby.io must record the connection between a knobby.io Organization and the provisioned Keycloak SAML IdP alias, with: knobby organization, Keycloak IdP alias (`saml-<slug>`), customer IdP entity ID, connected-at timestamp, lifecycle state (active/revoked). This mapping is the bridge between Keycloak's per-alias IdP entries and knobby.io's Organization model. The hot-path query is "given a knobby.io Organization, find the Keycloak IdP alias to use for sign-in routing."

*Implementation note for all three (Microsoft, Google, SAML):* the connection records may map to a single unified "tenant connection" abstraction in knobby.io's data model, or to three separate per-provider records, or some hybrid. The choice is for the implementer to make based on the existing data model and the rest of the application's domain model. The PRD specifies only the required behavior and logical fields per provider.

---

## 13. Realm Configuration Automation — OpenTofu

### 13.1 Decision

**Tool: OpenTofu** (https://opentofu.org). Compatible with the Terraform Keycloak provider.

**Out of scope:**
- IdP credentials at the source (Google Cloud OAuth client, Entra app registration, GitHub OAuth App).
- GCP Secrets Manager entries.
- Per-customer SAML IdPs — runtime, via Keycloak Admin REST API by knobby.io.
- Keycloak deployment itself.

**In scope:**
- Realm creation and settings (excluding Organizations, which we don't use).
- Custom authentication flows and bindings.
- Required Actions configuration.
- Built-in IdPs (Google, Microsoft via generic OIDC with alias `microsoft-oidc`, GitHub).
- The `knobby-{env}-web` and `knobby-{env}-admin-api` clients.
- Account console disablement.
- Theme selection.

### 13.2 Repository Structure

```
knobby-infra-keycloak/
├── modules/
│   ├── knobby-realm/
│   ├── knobby-realm-google-idp/
│   ├── knobby-realm-microsoft-idp/         # alias: microsoft-oidc
│   ├── knobby-realm-github-idp/
│   ├── knobby-realm-web-client/
│   └── knobby-realm-admin-api-client/
├── environments/
│   ├── prod/
│   ├── dev/
│   └── test/
├── scripts/
│   └── keycloak-init.sh
└── README.md
```

(No `knobby-realm-organizations` module — Organizations is not used per Invariant 8.)

### 13.3 The `keycloak-init.sh` Wrapper

```bash
./scripts/keycloak-init.sh --env prod
```

Responsibilities:
1. Validate `KNOBBY_ENV` ∈ `{prod, dev, test}`.
2. Verify required tooling.
3. Fetch all required secrets from GCP Secrets Manager (per §10.8).
4. Initialize OpenTofu against the env-specific backend.
5. Run `tofu plan` with explicit confirmation before apply.
6. Run `tofu apply`.
7. Run `keycloak-smoke-test.sh` to validate.

### 13.4 Implementation Phases

**Phase 1:** core realm + clients.
**Phase 2:** Google + Microsoft IdPs.
**Phase 3:** GitHub IdP.
**Phase 4:** theme binding (assumes JAR pre-deployed).
**Phase 5:** IaC drift detection in CI.

### 13.5 Migration from Manual Setup

The current `knobby-prod` realm will be `tofu import`-ed rather than recreated. Procedure:

1. Write OpenTofu modules to match current state exactly (including alias `microsoft-oidc`, role list per §11.13, etc.).
2. `tofu import` each existing resource.
3. `tofu plan` should show zero changes.
4. Going forward, all changes flow through OpenTofu (Invariant 7).

### 13.6 State Management

Per-environment OpenTofu state in GCS buckets with object versioning:
- `gs://knobby-tofu-state-prod/keycloak/`
- `gs://knobby-tofu-state-dev/keycloak/`
- `gs://knobby-tofu-state-test/keycloak/` (or developer-local)

### 13.7 Tracked in v1.6

Section commits to OpenTofu and reflects v1.6's drop of Organizations. Actual `.tf` files and `keycloak-init.sh` are the next deliverable.

---

## 14. Open Questions

1. **Single-org-per-user constraint** — does knobby.io enforce that a user belongs to exactly one Organization? Affects the tenant-connection data model.
2. **Service account model for AI agents** — parked.
3. **Step-up authentication for sensitive operations** — `acr` claim enforcement timing.
4. **Customer SAML self-service** — via knobby.io admin UI or manual?
5. **CASB-managed tenants** — manual escalation path.
6. **Microsoft tenant domain refresh cadence** — 24h proposed.
7. **Event bus integration timeline** — parked.
8. **Personal MSA in enterprise orgs** — confirm policy.
9. **GCS state bucket retention** — Object Versioning enabled? Standard practice yes; confirm.
10. **Theme deployment cadence** — see `KEYCLOAK_THEMING_GUIDE.md`.

---

## 15. Future Work (Tracked, Out of Scope for v1.6)

- **OpenTofu IaC implementation** (per §13 — next major session).
- **Microsoft Publisher Verification application** (multi-day lead time).
- **Step-up authentication** via `acr` claim enforcement.
- **Token Exchange** for AI agent delegation.
- **Custom Keycloak event listener SPI** for the platform event bus.
- **Themed account management UI** inside knobby.io.
- **Customer self-service onboarding UI** for all IdP families.
- **Microsoft tenant domain background job** for email-domain home discovery.
- **Email-first login routing** (Strategy B in §12.9).
- **Consent revocation detection** for Microsoft tenants.
- **Local username/password tier** (B2C / contractor) — feature flag.
- **Apple Sign In** — deferred. When revived, configure via the `klausbetz/apple-identity-provider-keycloak` extension.

---

## 16. References

- Keycloak Server Administration Guide (v26): https://www.keycloak.org/docs/latest/server_admin/
- Keycloakify: https://keycloakify.dev (see `KEYCLOAK_THEMING_GUIDE.md`)
- Microsoft Entra publisher verification: https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview
- Microsoft admin consent endpoint: https://learn.microsoft.com/en-us/entra/identity-platform/v2-admin-consent
- Microsoft Entra app registration (multitenant): https://learn.microsoft.com/en-us/entra/identity-platform/howto-convert-app-to-be-multi-tenant
- GitHub OAuth Apps: https://docs.github.com/en/apps/oauth-apps
- OpenTofu: https://opentofu.org
- Terraform Keycloak provider: https://registry.terraform.io/providers/keycloak/keycloak
- OIDC Back-Channel Logout 1.0: https://openid.net/specs/openid-connect-backchannel-1_0.html
- knobby.io Access Control PRD.
- knobby.io Audit Trail ADRs 001/002/003.
- knobby.io Approval System Requirements.
- knobby.io Infrastructure Hardening Plan.
- `KEYCLOAK_THEMING_GUIDE.md` (companion document).
