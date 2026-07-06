# Authentication & Identity Brokering PRD

**Status:** Draft v1.6
**Owner:** PVSS
**Last Updated:** 2026-06-02
**Related Specs:** Access Control PRD (Zanzibar RBAC), Audit Trail ADR-001/002/003, Approval System Requirements, Pathfinder PRD (agent session management), **Keycloak Theming Guide** (companion document)

**Changelog:**
- v1.0–v1.4: see prior changelogs (Microsoft Entra strategy, runbook corrections, naming conventions, integration reference expansions, Apple Sign In addition).
- v1.5 (2026-06-02): Apple Sign In deferred to Future Work; theming detail moved to companion guide.
- v1.6 (2026-06-02): Significant cleanup driven by manual-setup learnings and a return to the "thin IdP broker" architectural charter. Seven themes:
  1. **Keycloak Organizations dropped entirely.** §5 rewritten — tenancy is owned by the yourapp.com application layer; Keycloak is purely a federation broker. §11 sections for "Enable Organizations Feature" and "Configure Organizations" removed. The `org` token claim removed from §8.3. All Organizations operations removed from §8.7. §13 OpenTofu structure no longer includes an organizations module.
  2. **Application persistence reframed as requirements, not schema.** §8.4 and §12 stop prescribing table names, columns, or SQL DDL. Instead each persistent-state requirement is described as logical fields with lifecycle and trust properties, with an explicit implementation note directing implementers to align with yourapp.com's existing data conventions.
  3. **Microsoft alias convention corrected to `microsoft-oidc`** across §6.3, §8.1, §10.8, §11.9 — reflects the fact that the alias is immutable in Keycloak and disambiguates from the (unused) built-in `microsoft` provider.
  4. **Entra app registration conventions clarified.** §6.3 and §11.9 note correct capitalization (`Keycloak`, not `KeyCloak`), no env suffix on prod displayName, publisherDomain set to `yourapp.com` (not a per-env subdomain), and the publisher domain hosting requirement (`.well-known/microsoft-identity-association.json` at the apex).
  5. **Admin API role list corrected.** §11.13 (was §11.15) drops the non-existent `view-organizations`/`manage-organizations` role names. `manage-realm` not required (no longer needed without Organizations). Note added that the role list has evolved across PRD revisions.
  6. **§11 sections renumbered** to close gaps from removed sections. §11.18 (verification checklist) is now §11.16; smoke test references updated accordingly.
  7. **Deployment topology clarified.** Apex `yourapp.com` and `www.yourapp.com` are marketing/publisher surfaces only. The prod application is deployed at `prod.yourapp.com`; dev at `dev.yourapp.com`. §8.1 redirect URI table and §10.8 naming convention updated. §12.2 Microsoft admin consent example URL updated. This was confirmed during manual federation testing — Keycloak's authorization endpoint rejection of PKCE-deficient test URLs surfaced the URL bar bouncing through `prod.yourapp.com`, revealing the topology disconnect from earlier PRD assumptions about the apex hosting the app.

---

## Reader's Guide

This PRD addresses several audiences:

- **Architects / decision review** → §§1–10.
- **Operators setting up a Keycloak realm by hand** → §11 (runbook).
- **yourapp.com app implementers (including Claude Code)** → §8 (integration reference) and §12 (tenant onboarding requirements). §10.8 is the authoritative naming-convention table. **Do not assume specific database tables exist** — the PRD describes *persistence requirements*; map to actual yourapp.com schema by consulting the codebase.
- **Infra engineers building Keycloak IaC** → §13 (OpenTofu plan) and §10.8.
- **Frontend engineers building the Keycloak theme** → `KEYCLOAK_THEMING_GUIDE.md` (companion document).

§10.8 is the single source of truth for all naming. Any code, IaC, runbook step, or documentation that disagrees with §10.8 should be considered out of date.

---

## 1. Executive Summary

yourapp.com will use Keycloak as a centralized identity broker that federates to all upstream identity providers (Google Workspace, Microsoft Entra, GitHub, enterprise SAML 2.0). Users will never directly interact with Keycloak. All login, profile management, account operations, and tenancy management occur within yourapp.com. Keycloak operates as invisible infrastructure: it terminates federation, mints tokens, and exposes an Admin REST API that yourapp.com consumes server-side.

Tenancy is a yourapp.com application-layer concept. yourapp.com's data model owns the Organization concept; Keycloak does not. Per-customer SAML IdPs are registered at the realm level with a stable naming convention and mapped to yourapp.com organizations in the application layer.

Enterprise customer onboarding is a first-class concern. Each enterprise customer tenant must be explicitly *connected* to yourapp.com before its users can sign in. For Microsoft Entra, this means a tenant admin grants OAuth admin consent via a dedicated yourapp.com onboarding flow. For Google Workspace, this means Workspace admin allowlisting. For SAML customers, this means the customer configures their IdP against yourapp.com's SP metadata and yourapp.com provisions a corresponding IdP entry via Keycloak Admin REST API.

This PRD establishes the durable invariants, the target architecture, the application-layer tenant model, the per-IdP configuration, the per-customer onboarding pattern, naming conventions, application integration reference, and a step-by-step setup runbook for fresh realm configuration in any of the three environments. It also commits to OpenTofu as the IaC tool for automated realm setup. The Keycloak theme is documented in the companion `KEYCLOAK_THEMING_GUIDE.md`.

---

## 2. Context

### 2.1 Business Drivers

yourapp.com is a B2B enterprise SaaS platform targeting software/IT organizations. Customer organizations expect:

- SSO integration with their existing IdP (Google Workspace, Microsoft Entra, custom SAML 2.0).
- No additional credentials for yourapp.com itself.
- A consistent, branded experience that never breaks the "yourapp.com product" illusion.
- Compliance with their internal identity governance (MFA, session policies, deprovisioning).
- IT-controlled onboarding: an enterprise admin explicitly approves yourapp.com for the organization before users can sign in.
- Optional social sign-in (GitHub) for individual contributors.

### 2.2 yourapp.com Platform Needs

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

Keycloak's user-facing surfaces are either replaced, bypassed, disabled, or themed beyond recognition. The Keycloak hostname is `auth.yourapp.com` (or `localhost:8080` for the developer-local `test` environment). Theming is documented in `KEYCLOAK_THEMING_GUIDE.md`.

### Invariant 4 — yourapp.com is a single OIDC client of Keycloak per environment

The yourapp.com application integrates with Keycloak as one OIDC client per environment (`yourapp-prod-web`, `yourapp-dev-web`, `yourapp-test-web`).

### Invariant 5 — Per-environment IdP credentials

Every upstream IdP integration (Google OAuth client, Microsoft Entra app registration, GitHub OAuth app, customer SAML SP entry) is registered separately per environment.

### Invariant 6 — Convention-based naming

All Keycloak resources and associated secrets follow a deterministic naming convention so that automation, scripts, runbooks, and human operators can derive any name from the environment alone. See §10.8.

### Invariant 7 — Realm configuration as code

Once the OpenTofu IaC for realm setup is in place (per §13), manual changes to realm configuration through the Keycloak admin console are not permitted in `prod` or `dev`.

### Invariant 8 — Tenancy lives in yourapp.com, not Keycloak

yourapp.com's application data model is the single source of truth for organizations, organization membership, customer↔IdP mapping, tenant connection state, and consent state. Keycloak does not use its Organizations feature. The realm is purely an IdP broker.

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
   │  Keycloak (auth.yourapp.com)                                               │
   │  ┌────────────────────────────┐  ┌────────────────────────────┐         │
   │  │  Realm: yourapp-prod        │  │  Realm: yourapp-dev         │         │
   │  └────────────────────────────┘  └────────────────────────────┘         │
   │           ▲                                ▲                              │
   │           │ OIDC / Admin REST API          │                              │
   └───────────┼────────────────────────────────┼──────────────────────────────┘
               │                                │
   ┌───────────▼────────────┐         ┌─────────▼────────────┐
   │  yourapp.com (prod)      │         │  yourapp.com (dev)     │
   │  • Tenancy owner       │         │  • Tenancy owner     │
   └────────────────────────┘         └──────────────────────┘

   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
                                                        (developer machine)

                       ┌────────────────────────────┐
                       │  Keycloak (localhost:8080) │
                       │  Realm: yourapp-test        │
                       └──────────────┬─────────────┘
                                      │
                       ┌──────────────▼─────────────┐
                       │  yourapp.com (local dev)     │
                       └────────────────────────────┘
```

**Production-facing topology:** one Keycloak instance hosted at `https://auth.yourapp.com` serves both the `yourapp-prod` and `yourapp-dev` realms.

**Test environment:** the `yourapp-test` realm runs on each developer's local machine.

### 4.2 Component Responsibilities

**Keycloak**
- Terminates federation to upstream IdPs.
- Maintains the canonical federated user record (one per (subject, IdP) pair, linked via email).
- Issues OIDC tokens to yourapp.com's web client.
- Exposes Admin REST API for user lookup and IdP CRUD.
- Hosts SAML SP metadata endpoint.
- Does **not** manage organizations or tenancy.

**yourapp.com frontend**
- Renders the login screen with IdP buttons (Google, Microsoft, GitHub, "Enterprise SSO").
- Initiates OIDC Authorization Code + PKCE flow against Keycloak with `kc_idp_hint=<alias>`.
- Renders all account, profile, organization, and tenant management UI.
- Renders the enterprise admin onboarding flow.
- Handles logout via RP-initiated logout.

**yourapp.com backend**
- Validates OIDC tokens.
- Calls Keycloak Admin REST API for user CRUD and IdP CRUD operations.
- Maps Keycloak `sub` to yourapp.com user identity (application persistence).
- Owns the organization data model and organization↔user membership.
- Owns the customer↔IdP-alias mapping (which Keycloak SAML IdP alias corresponds to which yourapp.com Organization).
- Owns tenant-connection state (Microsoft consent records, Google Workspace connections, SAML IdP connections).
- Enforces RBAC/FGAC per the Access Control PRD.

**Agent runtime (future)**
- Authenticates via OAuth 2.0 Client Credentials with a per-agent client.

### 4.3 Data Flow — Human Login (happy path)

1. User opens `yourapp.com`. App renders login screen.
2. User clicks "Sign in with Google" (or Microsoft / GitHub / Enterprise SSO). Frontend navigates to Keycloak's authorize endpoint with `kc_idp_hint=google` (or `microsoft-oidc`, `github`, `saml-<slug>`).
3. Keycloak 302s to the IdP. No Keycloak HTML rendered.
4. User authenticates at the IdP.
5. IdP 302s back to Keycloak's broker endpoint with authorization code.
6. Keycloak exchanges the code, reads identity claims.
7. Keycloak runs First Broker Login flow: looks up federated user; creates if needed.
8. Keycloak 302s back to `https://prod.yourapp.com/auth/callback?code=...&state=...`.
9. yourapp.com backend exchanges Keycloak's code for tokens, validates them, looks up the application user by `sub`, determines org context from its own data, establishes session.

### 4.4 Data Flow — Logout

RP-initiated logout from yourapp.com frontend; hits Keycloak end-session endpoint; Keycloak terminates session and 302s back. Upstream IdP session is not terminated.

### 4.5 Data Flow — Enterprise Tenant Onboarding

See §12.

---

## 5. Tenant Model

### 5.1 Decision: Application-layer tenancy

Tenancy lives in yourapp.com's application data model. Keycloak does not use its Organizations feature.

**Rationale:**
- yourapp.com already has a first-class Organization concept in its data model (existed before this PRD).
- Duplicating that concept in Keycloak would require ongoing synchronization between two data stores.
- Keycloak's Organizations feature is relatively new (GA in 26.0) with known gaps (fine-grained admin permissions for Organizations not yet broken out in 26.x; known bugs interacting with the existing realm-management role surface).
- Invariant 3 says users never see Keycloak — there's no UX value in Keycloak Organizations for our use case.
- The only Keycloak feature where Organizations seemed to add value (domain-based home discovery) is handled in the yourapp.com frontend anyway (§12.9 Strategy B).

**Mechanics:**
- Per-customer SAML IdPs registered at the realm level with naming pattern `saml-<customer-slug>` (per §6.5 and §10.8). No link to a Keycloak Organization.
- yourapp.com's data model maintains the mapping from Keycloak IdP alias to yourapp.com Organization (see §12 persistence requirements).
- Organization membership for users is determined by yourapp.com on token validation (look up user by `sub`, determine org from application data).
- Tokens issued by Keycloak do not include an `org` claim; org context is derived in yourapp.com after token validation.

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
  - Prod: `https://auth.yourapp.com/realms/yourapp-prod/broker/google/endpoint`
  - Dev: `https://auth.yourapp.com/realms/yourapp-dev/broker/google/endpoint`
  - Test: `http://localhost:8080/realms/yourapp-test/broker/google/endpoint`
- Client secrets: `yourapp-google-oauth-client-secret-{env}`.
- Enterprise onboarding: Workspace admin allowlists OAuth client ID in Google Admin Console (Security → API controls → App access control). See §12.10.

### 6.3 Microsoft Entra (Azure AD)

**Account types:** work/school accounts from any Entra tenant (enterprise) + personal Microsoft accounts (social). One Keycloak IdP entry handles both via Microsoft's `common` endpoint.

**Implementation:** generic **OpenID Connect v1.0** provider type — not the built-in "Microsoft" provider (which is hardcoded for single-tenant).

**Alias convention:** `microsoft-oidc` (the `-oidc` suffix disambiguates from the unused built-in `microsoft` provider and makes it explicit that this is the generic OIDC connector). Aliases are immutable in Keycloak, so this name persists.

**Per-environment Entra app registrations:**
- Prod: `yourapp.com Keycloak Broker` (no env suffix; this name appears on customer admin consent screens)
- Dev: `yourapp.com Keycloak Broker (dev)`
- Test: `yourapp.com Keycloak Broker (test - {developer-name})`

**Capitalization:** the official spelling is `Keycloak` (capital K, lowercase c). `KeyCloak` is a common but incorrect rendering — customer admins reading the consent screen notice these things. Get it right at registration time; it cannot be changed without re-registering.

**Supported account types** in each Entra app: "Accounts in any organizational directory and personal Microsoft accounts."

**Discovery endpoint:** `https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration`.

**Issuer validation gotcha:** leave the **Issuer** field empty.

**Forwarded query parameters:** `login_hint,domain_hint,prompt`.

**Personal-account differentiation:** `tid` claim. Personal MSAs have `tid=9188040d-6c67-4c5b-b112-36a304b66dad`.

**Client secrets:** `yourapp-entra-broker-client-secret-{env}`. Secret description in Entra: `keycloak-broker-{env}`.

**Publisher domain:** `yourapp.com` (the company's primary domain — same value for all environments because the publisher is the company, not the deployment). Requires Microsoft Publisher Verification — see §10.7. Requires hosting `https://yourapp.com/.well-known/microsoft-identity-association.json` at the apex.

**Trust posture:**
- Work/school accounts: equivalent trust tier to Google Workspace.
- Personal MSAs: lower trust tier. Rejected from enterprise-tier organizations at the application authorization layer.

### 6.4 GitHub

GitHub is a **lower-trust** IdP than Google or Microsoft work accounts.

**Implementation:** built-in provider, alias `github`.

**Per-environment GitHub OAuth Apps:**
- Prod: `yourapp.com`
- Dev: `yourapp.com (dev)`
- Test: `yourapp.com (test - {developer-name})`

**Configuration on GitHub** (Developer Settings → OAuth Apps → New OAuth App):

| Field | Prod | Dev | Test |
|-------|------|-----|------|
| Application name | `yourapp.com` | `yourapp.com (dev)` | `yourapp.com (test - {dev-name})` |
| Homepage URL | `https://yourapp.com` | `https://yourapp.com` | `http://localhost:3000` |
| Authorization callback URL | `https://auth.yourapp.com/realms/yourapp-prod/broker/github/endpoint` | `https://auth.yourapp.com/realms/yourapp-dev/broker/github/endpoint` | `http://localhost:8080/realms/yourapp-test/broker/github/endpoint` |
| Enable Device Flow | Off | Off | Off |

**Scopes:** `user:email read:user`.

**Email handling caveat:** GitHub users can hide their email. Configure an attribute mapper that pulls the primary verified email from `/user/emails`. If still null after all mappers, the user can't federate via GitHub.

**Trust Email:** On.

**Client secrets:** `yourapp-github-oauth-client-secret-{env}`.

### 6.5 Enterprise SAML 2.0 (per customer organization)

- One SAML IdP entry per customer. Alias pattern `saml-<customer-slug>`.
- Configuration imported from customer-supplied SAML metadata XML.
- Registered at the realm level (no Keycloak Organization linkage per Invariant 8).
- yourapp.com's SP entity ID per env:
  - Prod: `https://auth.yourapp.com/realms/yourapp-prod`
  - Dev: `https://auth.yourapp.com/realms/yourapp-dev`
- ACS URL: `<SP-entity-id>/broker/saml-<customer-slug>/endpoint`.
- NameID format: `emailAddress` preferred.
- Signed AuthnRequests and signed assertions required.
- yourapp.com's application data maintains the mapping from IdP alias to yourapp.com Organization (§12).

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

## 8. yourapp.com ↔ Keycloak Integration (Application Implementation Reference)

This section is the authoritative reference for the yourapp.com application's integration with Keycloak.

**Implementation note throughout:** this section describes the *integration contract* — what Keycloak provides and what yourapp.com must do with it. It does not prescribe yourapp.com's internal data model. References to "yourapp.com persists X" or "yourapp.com's user record" are about *requirements*; the actual schema, table names, and column types are at the implementer's discretion and should align with the existing yourapp.com codebase. Consult the codebase before assuming new persistence layers are needed.

### 8.1 Per-Environment URL & ID Reference

All URLs and identifiers needed for app configuration, parameterized by `{env}` ∈ `{prod, dev, test}`.

**Base URLs:**

| Setting | Prod / Dev | Test |
|---------|-----------|------|
| Keycloak base URL | `https://auth.yourapp.com` | `http://localhost:8080` |
| Realm name | `yourapp-{env}` | `yourapp-test` |
| OIDC issuer | `https://auth.yourapp.com/realms/yourapp-{env}` | `http://localhost:8080/realms/yourapp-test` |
| OIDC discovery | `<issuer>/.well-known/openid-configuration` | (same pattern) |
| Authorization endpoint | `<issuer>/protocol/openid-connect/auth` | (same) |
| Token endpoint | `<issuer>/protocol/openid-connect/token` | (same) |
| Userinfo endpoint | `<issuer>/protocol/openid-connect/userinfo` | (same) |
| JWKS endpoint | `<issuer>/protocol/openid-connect/certs` | (same) |
| End-session endpoint | `<issuer>/protocol/openid-connect/logout` | (same) |
| Admin REST API base | `<keycloak-base>/admin/realms/yourapp-{env}` | (same pattern) |

**yourapp.com application URLs** (registered as Valid Redirect URIs / Valid Post-Logout URIs on `yourapp-{env}-web`):

**Deployment topology note:** apex `yourapp.com` and `www.yourapp.com` are marketing/publisher surfaces only — the actual prod application is deployed at `prod.yourapp.com`. Dev application is at `dev.yourapp.com`. This split keeps the marketing brand at the apex (where it's expected for SEO, customer trust, and Microsoft publisher domain verification) and the app at a subdomain.

| Purpose | Prod | Dev | Test |
|---------|------|-----|------|
| Sign-in callback | `https://prod.yourapp.com/auth/callback` | `https://dev.yourapp.com/auth/callback` | `http://localhost:3000/auth/callback` |
| Post-logout landing | `https://prod.yourapp.com/` | `https://dev.yourapp.com/` | `http://localhost:3000/` |
| Front-channel logout | `https://prod.yourapp.com/auth/frontchannel-logout` | `https://dev.yourapp.com/auth/frontchannel-logout` | `http://localhost:3000/auth/frontchannel-logout` |
| Back-channel logout | `https://prod.yourapp.com/auth/backchannel-logout` | `https://dev.yourapp.com/auth/backchannel-logout` | `http://localhost:3000/auth/backchannel-logout` |
| Microsoft admin consent callback | `https://prod.yourapp.com/auth/microsoft/admin-consent-callback` | `https://dev.yourapp.com/auth/microsoft/admin-consent-callback` | `http://localhost:3000/auth/microsoft/admin-consent-callback` |

### 8.2 OIDC Client Configuration

The `yourapp-{env}-web` client in Keycloak has these settings:

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

The client secret is in `yourapp-keycloak-web-client-secret-{env}`.

### 8.3 Token Claims Contract

The ID token and access token issued by Keycloak to the `yourapp-{env}-web` client carry these claims. The yourapp.com backend MUST validate `iss`, `aud`, `exp`, signature; MAY rely on the rest.

| Claim | Type | Source | Notes |
|-------|------|--------|-------|
| `iss` | string | Keycloak | Equals `https://auth.yourapp.com/realms/yourapp-{env}` (or `http://localhost:8080/realms/yourapp-test`). Validate. |
| `aud` | string | Keycloak | Equals `yourapp-{env}-web`. Validate. |
| `exp` | int (unix) | Keycloak | Validate. |
| `iat` | int (unix) | Keycloak | Issuance time. |
| `sub` | string (UUID) | Keycloak | Stable yourapp.com user identifier. The primary handle for user records. |
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

**No `org` claim.** Organization context is determined by yourapp.com after token validation, by looking up the user (by `sub`) against application data.

**Trust rules for yourapp.com backend:**
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

#### 8.3.1 Implementation requirement — cross-IdP claim contamination (app team action)

> **Status:** Confirmed observed in production (yourapp-prod, 2026-07-01). This is not a theoretical risk — a real token exhibits it. The app team must implement and test the guard below.

**Observed evidence.** A production ID token for a user who authenticated via **Google** carried a **Microsoft** user attribute:

```
idp: "google"                     ← session fact: this session is Google
microsoftTenantId: "9188040d-6c67-4c5b-b112-36a304b66dad"   ← user fact: from a PRIOR Microsoft federation
email: "…@gmail.com"
aud: "yourapp-prod-web"
```

The user had previously signed in via Microsoft (a personal MSA, hence the well-known personal-MSA tenant constant) with the same email; the auto-linking flow (§11.4) attached both identities to one Keycloak user, and `microsoftTenantId` now persists on that record and rides along in **every** session including Google ones. This is the session-fact-vs-user-fact hazard made concrete.

**Required behavior.** Every backend code path that reads `microsoftTenantId`, `microsoftObjectId`, or `googleHd` for a session-scoped authorization decision MUST first confirm the current session's `idp` matches the claim's origin IdP:

| Claim | May be trusted for session-scoped authorization only when |
|---|---|
| `microsoftTenantId` | `idp == "microsoft-oidc"` |
| `microsoftObjectId` | `idp == "microsoft-oidc"` |
| `googleHd` | `idp == "google"` |

The AND-condition is mandatory. Reading the claim without the paired `idp` check is an authorization bug: it lets a Google (or GitHub) session inherit privileges tied to the user's Microsoft (or Google Workspace) association.

**Recommended implementation — centralize, don't scatter.** Rather than repeating the `idp` check at every call site (error-prone), expose the origin-checked values through a single accessor so the raw attribute claims are never read directly for authorization:

```csharp
// Single source of truth. Returns the Microsoft tenant ID ONLY for a Microsoft session.
public string? SessionMicrosoftTenantId(ClaimsPrincipal user) =>
    user.FindFirst("idp")?.Value == "microsoft-oidc"
        ? user.FindFirst("microsoftTenantId")?.Value
        : null;

// Returns the Google Workspace hosted domain ONLY for a Google session.
public string? SessionGoogleHd(ClaimsPrincipal user) =>
    user.FindFirst("idp")?.Value == "google"
        ? user.FindFirst("googleHd")?.Value
        : null;
```

Authorization code calls `SessionMicrosoftTenantId(...)` / `SessionGoogleHd(...)` and never touches the raw `microsoftTenantId` / `googleHd` claims. A `null` return means "not applicable to this session" — the caller treats it identically to "no tenant association," which is the correct, safe default. This makes the trust rule structurally enforced rather than dependent on every developer remembering to write the AND-condition.

**Exception (document at each site):** entry points that are inherently Microsoft-scoped (e.g. the admin-consent callback, §12.4) may read `microsoftTenantId` directly because the entry point itself guarantees a Microsoft session. Any such direct read must carry a comment explaining why the `idp` check is unnecessary there.

**Test cases the app team must add:**
1. A token with `idp=google` + `microsoftTenantId=<any>` → `SessionMicrosoftTenantId` returns `null`; no Microsoft-tenant-scoped authorization is granted.
2. A token with `idp=microsoft-oidc` + `microsoftTenantId=<org uuid>` → `SessionMicrosoftTenantId` returns the UUID; Microsoft-tenant authorization proceeds.
3. Symmetric pair for `googleHd` with `idp=google` vs `idp=github`.
4. The personal-MSA case: `idp=microsoft-oidc` + `microsoftTenantId=9188040d-6c67-4c5b-b112-36a304b66dad` → treated as "no enterprise tenant" per §12's personal-MSA handling (the AND-condition passes, but personal MSAs are rejected from enterprise Organizations at the authorization layer — a separate, additional check).

This requirement is a prerequisite for the directory-binding tenancy model (§15), which resolves tenant context by matching the current session's `(idp, tenant-identifier)` tuple against active bindings — that matching is only correct if the tenant-identifier is read with the origin-IdP guard specified here.

### 8.4 ASP.NET Core 10 Integration Pattern

yourapp.com's backend integrates with Keycloak via the standard OpenID Connect middleware.

**NuGet packages:**
- `Microsoft.AspNetCore.Authentication.OpenIdConnect`
- `Microsoft.AspNetCore.Authentication.JwtBearer`
- `Microsoft.IdentityModel.Tokens`

**Configuration model** (e.g., `KeycloakOptions.cs`):

```csharp
public class KeycloakOptions
{
    public string Authority { get; set; }             // https://auth.yourapp.com/realms/yourapp-prod
    public string ClientId { get; set; }              // yourapp-prod-web
    public string ClientSecret { get; set; }          // from GCP Secrets Manager
    public string AdminApiClientId { get; set; }      // yourapp-prod-admin-api
    public string AdminApiClientSecret { get; set; }  // from GCP Secrets Manager
    public string CallbackPath { get; set; }          // /auth/callback
    public string SignedOutCallbackPath { get; set; } // /auth/logout-callback
    public string FrontChannelLogoutPath { get; set; }    // /auth/frontchannel-logout
    public string BackChannelLogoutPath { get; set; }     // /auth/backchannel-logout
}
```

Loaded from `appsettings.{env}.json` for non-secret values and from environment variables (which yourapp.com's infra fills from GCP Secret Manager) for the secrets.

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
    options.Cookie.Name = "yourapp.auth";
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
            // mechanics are application-specific. Use yourapp.com's existing user
            // persistence and organization-membership conventions; consult the
            // codebase before introducing new tables or service interfaces.
            var sub = context.Principal.FindFirst("sub")?.Value;
            var idp = context.Principal.FindFirst("idp")?.Value;
            // ... lookup/create application user, attach org context to claims principal
        },
        OnRedirectToIdentityProvider = context =>
        {
            // Forward kc_idp_hint from query string (e.g., set by the "Sign in
            // with Microsoft" button on the yourapp.com login page).
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

yourapp.com's backend must expose:

**`GET /auth/callback`** — OIDC sign-in callback. Receives `code`, `state`. ASP.NET OIDC middleware handles automatically.

**`GET /auth/logout-callback`** — post-logout callback.

**`POST /auth/backchannel-logout`** — Keycloak-initiated back-channel logout. Receives a `logout_token` JWT. yourapp.com validates the signature against the JWKS and the `sid` claim, then invalidates the local session. Implement explicitly. Reference: OIDC Back-Channel Logout 1.0 spec.

**`GET /auth/frontchannel-logout`** — Keycloak-initiated front-channel logout (hidden iframe).

**`GET /auth/microsoft/admin-consent-callback`** — Microsoft admin consent return. See §12.4.

### 8.6 Session & Token Lifecycle

| Token | Lifetime | Action when expired |
|-------|----------|---------------------|
| Access token | 5 minutes | yourapp.com refreshes via refresh token. |
| ID token | 5 minutes | Refreshed alongside access token. |
| Refresh token | 30 days (sliding) | When expired, re-authenticate. |
| SSO session idle | 30 minutes | Keycloak invalidates if no activity. |
| SSO session max | 10 hours | Force re-authentication. |
| yourapp.com session cookie | 10 hours | Matches SSO Session Max. |

#### 8.6.1 Implementation requirement — session/token concurrency (app team action)

> **Status:** Confirmed in production (yourapp-prod, 2026-07-02/03). Two independent concurrency bugs surfaced during Keycloak cutover: (1) a token-refresh race and refresh storm, and (2) a session-row update race that invalidates sessions. **Important context:** the *primary* production trigger of the logout cascade turned out to be an infrastructure misconfiguration — Keycloak's DB backend behind the Supabase transaction pooler returning HTTP 500 on the token endpoint ("prepared statement does not exist"; see KEYCLOAK_SETUP_GUIDE.md §A.2.3). Fixing the pooler removes the trigger. The two app bugs below are real amplifiers that made a transient IdP 500 fatal to the session, and should still be fixed so the app is resilient to IdP hiccups — but they are not the root cause of the original incident.

**Background.** When the realm has refresh-token rotation on (`Revoke Refresh Token = true`, `Refresh Token Max Reuse = 0`, §16.5 / setup guide D.9), each use of a refresh token issues a new one and invalidates the old. This is required for the MCP clients (public, tokens on the user's machine). It applies realm-wide, so the confidential web client is subject to it too.

**Observed failure.** After login, the SPA fires several authenticated calls near-simultaneously (`/auth/profile`, `/users/me/settings`, `/users/me/ui-state`, `/auth/me`). With an expired access token, each request independently refreshes using the *same* stored refresh token. The cascade:

1. First request wins → Keycloak 200, rotates the refresh token.
2. Concurrent requests send the now-rotated token → `400 invalid_grant: Maximum allowed refresh token reuse exceeded`.
3. Reuse detection (Revoke Refresh Token) revokes the session's client binding → subsequent refreshes get `400 invalid_grant: Session doesn't have required client`.
4. Concurrent session-row writes collide in Postgres → `DbUpdateConcurrencyException` (one flow invalidated the row while another updated it).
5. Net: session invalidated → `401 "invalid session"` on every in-flight request.

**Required behavior.** Token refresh MUST be single-flight per session:

- When a session's access token needs refreshing, exactly **one** refresh executes. Concurrent requests for the same session must **await the in-flight refresh and reuse its result**, not each issue their own refresh call.
- Implement with a per-session async lock / mutex (keyed by session id), or a single-flight/coalescing primitive (e.g. a per-session `Lazy<Task<Tokens>>` / `SemaphoreSlim`, or a distributed lock if the app is multi-instance — yourapp.com already uses Redis, which can back this).
- After a successful refresh, **persist the rotated refresh token atomically** and make it the value all waiters read.
- A `Maximum allowed refresh token reuse exceeded` response must **not** immediately invalidate the session — first re-read the stored refresh token (a concurrent flow may have just rotated it) and retry once with the current value before giving up.

**Second failure mode — session-row update concurrency (independent of rotation).** Distinct from the refresh race above, and confirmed to persist even with refresh-token rotation turned *off*: `UpdateSessionAccessAsync` (and `GetSessionAsync`) write the session row on every authenticated request under EF Core optimistic concurrency. When the initial page load fires its burst of authenticated calls for one session, they race on that single row — one wins and bumps the concurrency token, the others' `UPDATE ... WHERE id=@id AND version=@stale` matches 0 rows and throws `DbUpdateConcurrencyException` ("expected to affect 1 row(s), but actually affected 0"). The app treats this as a session failure and invalidates → `401 "invalid session"` within seconds of login. **This is a separate bug from the refresh race and must be fixed independently — turning off rotation does not address it.** Fix: update last-access-time via a non-tracked, non-optimistic-concurrency write (e.g. a direct `UPDATE ... SET last_access = now() WHERE id = @id`), or throttle it to at most once per N seconds per session, or drop the write entirely on read-only requests. Last-access is advisory; it does not need optimistic-concurrency protection, and the session's *validity* must not depend on that write succeeding. More broadly: a failed last-access bookkeeping write must never invalidate an otherwise-valid session.

**Multi-instance note.** If yourapp.com runs more than one API instance, the single-flight lock must be **distributed** (Redis), since an in-memory per-session lock only coalesces within one process. Two instances refreshing the same session concurrently would reproduce the race across the cluster.

**Sequencing.** Until single-flight refresh ships, keep the realm with **`Revoke Refresh Token = Off`**. A `Refresh Token Max Reuse` grace window is **not a reliable mitigation** for this problem: it only addresses the "Maximum allowed refresh token reuse exceeded" error, but concurrent rotation *also* triggers a separate "Session doesn't have required client" error from Keycloak's own client-session handling under concurrency, which the reuse counter does not govern. Observed in production: setting `Max Reuse = 5` did not stop the logouts; only turning rotation off did. Re-enable strict rotation (`Revoke Refresh Token = On`, `Max Reuse = 0`) only after single-flight refresh is deployed and verified. Smoke Test 19 checks for strict rotation; treat its failure as "not yet safe to enable" until this requirement is met, rather than a gap to close immediately.

**Test cases the app team must add:**
1. Fire N concurrent authenticated requests on a session with an expired access token → exactly one Keycloak refresh call is made; all N requests succeed; the session remains valid.
2. Simulate a rotated-token response on a losing flow → the flow re-reads the stored token and retries rather than invalidating the session.
3. (Multi-instance) two instances, concurrent requests on the same session → still one refresh, session stays valid.

#### 8.6.2 Deployment constraint — Keycloak DB connection mode (infra)

The *primary* trigger of the 2026-07-03 logout incident was not app or realm configuration — it was Keycloak's database connection mode. Keycloak uses **server-side named prepared statements**, which require statement-affinity to a single physical Postgres connection. Behind a **transaction-mode connection pooler** (Supabase's PgBouncer on port 6543, or any equivalent), each statement can land on a different backend connection, producing intermittent `prepared statement "S_NNN" does not exist` → transaction rollback → **HTTP 500 on the token endpoint** → app-side session invalidation and logout. The failure is intermittent and easily misattributed to rotation, session timeouts, or app code (all of which were investigated and cleared).

**Requirement:** Keycloak's `KC_DB_URL` MUST use a connection mode that preserves prepared statements — a **session-mode pooler** or a **direct connection** — and SHOULD additionally set **`prepareThreshold=0`** to disable server-side prepared statements as defense-in-depth. It MUST NOT point at a transaction-mode pooler without `prepareThreshold=0`.

This is a "how" detail owned by the setup guide (§A.2.3, including the Cloud Run IPv6 constraint that dictates *which* endpoint to use) and verified by the smoke suite's **Token endpoint stability** check (hammers `/token` and fails on any intermittent 500). It is recorded here because it is an architectural deployment invariant, not a one-time setup step: it must hold for every environment (prod, dev, staging) and survive the future Cloud Run → Hetzner migration.

### 8.7 Keycloak Admin REST API — yourapp.com Usage Reference

yourapp.com's backend authenticates via client credentials grant on `yourapp-{env}-admin-api`. Acquire token per request batch (cache for ~4 minutes).

**Token acquisition:**

```
POST https://auth.yourapp.com/realms/yourapp-{env}/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=yourapp-{env}-admin-api
&client_secret=<from yourapp-keycloak-admin-api-client-secret-{env}>
```

**Operations** (`<base>` = `https://auth.yourapp.com/admin/realms/yourapp-{env}`):

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

**No Organizations operations** — Keycloak Organizations is not used (per §5.1 / Invariant 8). Customer↔IdP mapping is persisted in yourapp.com's application data, not via Keycloak Organization membership.

Full Keycloak Admin REST API documentation: https://www.keycloak.org/docs-api/latest/rest-api/.

### 8.8 Account Console Disablement

Both built-in account clients disabled per realm:
- `account` — Enabled = Off
- `account-console` — Enabled = Off

### 8.9 AI Agent Authentication (future, parked)

Per the Access Control PRD.

---

## 9. Theming

Per Invariant 3, Keycloak's rare user-facing fallback pages (no `kc_idp_hint`, errors, logout confirmation, session expiry, account linking) are themed to match yourapp.com using **Keycloakify**.

**All detailed setup, customization, build, and deployment instructions are in the companion document `KEYCLOAK_THEMING_GUIDE.md`.**

Pages **not** themed: Account Console (disabled), Admin Console (internal-only), Registration/Forgot Password (disabled per Invariant 1).

---

## 10. Operational Considerations

### 10.1 Availability

Keycloak is tier-zero. Run on Cloud Run with `min-instances=2`. Postgres backend on Supabase with HA. Shared prod+dev instance means realm configuration changes flow through OpenTofu IaC (§13) and Keycloak version upgrades are tested in the dev realm in the same instance before reaching prod.

### 10.2 Token Lifetimes

Per §8.6.

### 10.3 Logout Coordination

RP-initiated logout from yourapp.com frontend. Back-channel logout from Keycloak to yourapp.com backend. Upstream IdP logout is not initiated by Keycloak.

### 10.4 Break-Glass Admin

Break-glass admin lives in the master realm with YubiKey-backed TOTP.

### 10.5 Secrets Management

All secrets follow the convention `yourapp-<system>-<purpose>-<credential-type>-{env}` and are stored in GCP Secrets Manager (prod, dev) or developer-local `.env` (test).

| Secret name | Used by | Source |
|-------------|---------|--------|
| `yourapp-keycloak-admin-api-client-secret-{env}` | yourapp.com backend → Keycloak Admin REST API | Keycloak: `yourapp-{env}-admin-api` client credentials |
| `yourapp-keycloak-web-client-secret-{env}` | yourapp.com backend → Keycloak token endpoint | Keycloak: `yourapp-{env}-web` client credentials |
| `yourapp-entra-broker-client-secret-{env}` | Keycloak → Microsoft Entra (broker auth) | Entra app registration: client secret (description: `keycloak-broker-{env}`) |
| `yourapp-google-oauth-client-secret-{env}` | Keycloak → Google (broker auth) | Google Cloud OAuth client |
| `yourapp-github-oauth-client-secret-{env}` | Keycloak → GitHub (broker auth) | GitHub OAuth App |
| `yourapp-keycloak-db-password-{env}` | Keycloak → Postgres | Postgres user |
| `yourapp-mcp-handoff-hmac-key-{env}` | Keycloak SPI ↔ yourapp.com backend (path iii handoff) | Generated; 256-bit random, base64. Rotated quarterly with two-key overlap (§16.8.5). |

### 10.6 Audit

Keycloak emits events that feed the platform event bus: login success/failure, IdP federation events, user CRUD, session termination, Admin API operations. Custom SPI exporter (future work) pushes to the Postgres transactional outbox.

### 10.7 Microsoft Entra Publisher Verification

Microsoft's risk-based step-up consent policy (effective November 2020) means newly registered multitenant apps without verified-publisher status face cross-tenant consent friction. Mitigated by the admin consent flow (§12).

**Prerequisite — host the publisher domain verification file:**

Microsoft's verification process requires hosting a small JSON file at:

```
https://yourapp.com/.well-known/microsoft-identity-association.json
```

with content provided by Microsoft during the verify step (an `associatedApplications` array with the Entra app's `applicationId`). This file proves ownership of `yourapp.com` and authorizes the Entra app to claim it as publisher.

Same publisherDomain (`yourapp.com`) for both prod and dev Entra apps — the publisher is the company, not the deployment. The file only needs to exist once at the apex; both apps verify against the same file.

**Hosting recommendation:** since the apex of `yourapp.com` may not yet have a marketing site, the simplest path is a minimal Cloudflare Pages site (or Worker) serving at least `.well-known/microsoft-identity-association.json`. Same hosting later supports other `.well-known` files (Apple, security.txt, etc.).

**Verification steps:**
- Start Microsoft AI Cloud Partner Program enrollment (multi-day lead time).
- Once Partner One ID is issued, submit publisher verification on the prod Entra app registration.
- Skip for dev/test.

### 10.8 Naming Convention Reference

Authoritative table. The OpenTofu IaC (§13) reads from this table.

| Resource | Convention | Example (prod) |
|----------|-----------|----------------|
| Realm name | `yourapp-{env}` | `yourapp-prod` |
| Web OIDC client ID | `yourapp-{env}-web` | `yourapp-prod-web` |
| Admin API client ID | `yourapp-{env}-admin-api` | `yourapp-prod-admin-api` |
| Keycloak hostname (prod, dev) | `auth.yourapp.com` | `auth.yourapp.com` |
| Keycloak hostname (test) | `localhost:8080` (HTTP) | `localhost:8080` |
| Realm OIDC issuer (prod, dev) | `https://auth.yourapp.com/realms/yourapp-{env}` | `https://auth.yourapp.com/realms/yourapp-prod` |
| Realm OIDC issuer (test) | `http://localhost:8080/realms/yourapp-test` | `http://localhost:8080/realms/yourapp-test` |
| Google IdP alias | `google` | `google` |
| Microsoft IdP alias | `microsoft-oidc` | `microsoft-oidc` |
| GitHub IdP alias | `github` | `github` |
| SAML IdP alias pattern | `saml-<customer-slug>` | `saml-acme-corp` |
| Google broker redirect URI | `<issuer>/broker/google/endpoint` | `https://auth.yourapp.com/realms/yourapp-prod/broker/google/endpoint` |
| Microsoft broker redirect URI | `<issuer>/broker/microsoft-oidc/endpoint` | `https://auth.yourapp.com/realms/yourapp-prod/broker/microsoft-oidc/endpoint` |
| GitHub broker redirect URI | `<issuer>/broker/github/endpoint` | `https://auth.yourapp.com/realms/yourapp-prod/broker/github/endpoint` |
| Keycloak admin API secret | `yourapp-keycloak-admin-api-client-secret-{env}` | `yourapp-keycloak-admin-api-client-secret-prod` |
| Keycloak web client secret | `yourapp-keycloak-web-client-secret-{env}` | `yourapp-keycloak-web-client-secret-prod` |
| Entra broker secret | `yourapp-entra-broker-client-secret-{env}` | `yourapp-entra-broker-client-secret-prod` |
| Google OAuth secret | `yourapp-google-oauth-client-secret-{env}` | `yourapp-google-oauth-client-secret-prod` |
| GitHub OAuth secret | `yourapp-github-oauth-client-secret-{env}` | `yourapp-github-oauth-client-secret-prod` |
| Keycloak DB password | `yourapp-keycloak-db-password-{env}` | `yourapp-keycloak-db-password-prod` |
| Entra app displayName (prod) | `yourapp.com Keycloak Broker` (no env suffix; capital K, lowercase c in Keycloak) | `yourapp.com Keycloak Broker` |
| Entra app displayName (dev/test) | `yourapp.com Keycloak Broker ({env}[ - {dev}])` | `yourapp.com Keycloak Broker (dev)` |
| Entra publisherDomain | `yourapp.com` (same for all envs) | `yourapp.com` |
| Entra secret description | `keycloak-broker-{env}` | `keycloak-broker-prod` |
| yourapp.com app hostname (prod) | `prod.yourapp.com` | `prod.yourapp.com` |
| yourapp.com app hostname (dev) | `dev.yourapp.com` | `dev.yourapp.com` |
| yourapp.com app hostname (test) | `localhost:3000` | `localhost:3000` |
| yourapp.com marketing hostname | `yourapp.com` (apex; also `www.yourapp.com`) — used only as publisher domain identity, not for OAuth callbacks | `yourapp.com` |
| yourapp.com OIDC callback URL | `https://{app-hostname}/auth/callback` | `https://prod.yourapp.com/auth/callback` |
| yourapp.com backchannel logout URL | `https://{app-hostname}/auth/backchannel-logout` | `https://prod.yourapp.com/auth/backchannel-logout` |
| yourapp.com MS admin consent callback | `https://{app-hostname}/auth/microsoft/admin-consent-callback` | `https://prod.yourapp.com/auth/microsoft/admin-consent-callback` |
| Keycloak theme name | `yourapp` | `yourapp` |
| **MCP — DCR Client Registration Policy name** | `mcp-dcr-policy` (one per realm) | `mcp-dcr-policy` |
| **MCP — default Client Scope (audience binding)** | `mcp-default` (one per realm) | `mcp-default` |
| **MCP — atomic Client Scope names** | `yourapp:{verb}` for each of the 6 atoms (§16.3.1) | `yourapp:read`, `yourapp:write`, `yourapp:admin`, etc. |
| **MCP — resource server audience** | `yourapp-mcp-api` (constant; not per-env — env isolation via realm separation) | `yourapp-mcp-api` |
| **MCP — DCR endpoint** | `<issuer>/clients-registrations/openid-connect` | `https://auth.yourapp.com/realms/yourapp-prod/clients-registrations/openid-connect` |
| **MCP — authentication flow name** | `browser-mcp-tenant-pick` (one per realm; appended SPI step) | `browser-mcp-tenant-pick` |
| **MCP — Realm Resource Provider callback** | `<issuer>/mcp-picker-callback` | `https://auth.yourapp.com/realms/yourapp-prod/mcp-picker-callback` |
| **MCP — consent wizard URL (yourapp.com side)** | `https://{app-hostname}/mcp/consent` | `https://prod.yourapp.com/mcp/consent` |
| **MCP — SPI JAR name** | `yourapp-keycloak-mcp-spi-{version}.jar` | `yourapp-keycloak-mcp-spi-1.0.0.jar` |
| **MCP — handoff HMAC key secret** | `yourapp-mcp-handoff-hmac-key-{env}` | `yourapp-mcp-handoff-hmac-key-prod` |
| **MCP — DCR'd client IDs** | Auto-generated UUIDs by Keycloak (no convention; tracked via DCR metadata `client_name`) | `9a8b7c6d-...` |

**Note on MCP:** there is intentionally **no static `yourapp-{env}-mcp-server` OIDC client.** DCR creates first-class Keycloak clients per MCP-client-install (one per `Claude Code on user X's laptop`, one per `Cursor on user Y's laptop`, etc.). The yourapp.com MCP server itself is a *resource server*, not a Keycloak client — identified by the audience string `yourapp-mcp-api` set via the `mcp-default` Client Scope. See §16.4 for the full architecture.

---

## 11. Setup Runbook — Fresh Realm Configuration

Currently manual; will be superseded by the OpenTofu IaC per §13 once available.

Prerequisites: Keycloak 26.x deployed; per-environment IdP credentials created per §10.8; for the theme, the `yourapp` theme JAR baked into the Keycloak image per `KEYCLOAK_THEMING_GUIDE.md`.

Execute in **dev first**, then **prod**. Test setup per §11.15 on each developer's machine.

**Ordering note:** flows (§11.4–11.6) and Required Actions (§11.7) before IdPs (§11.8–11.11).

### 11.1 Create the Realm

1. Log into Keycloak admin console as master realm admin.
2. Realm dropdown → **Create realm**.
3. Realm name: `yourapp-{env}`.
4. Enabled: On. Click **Create**.

### 11.2 Configure Realm Settings

**Realm settings → Login tab:** User registration Off, Forgot password Off, Remember me Off, Email as username On, Login with email On, Duplicate emails Off, Verify email Off, Edit username Off.

**Realm settings → Email tab:** Leave unconfigured.

**Realm settings → Themes tab:** Login `keycloak` for now (will switch to `yourapp` after theme is built per §11.14). Admin `keycloak.v2`.

**Realm settings → Sessions tab** (⚠️ **not** the Tokens tab — SSO/session timeouts moved to their own Sessions tab in 26.x): SSO Session Idle **30 min**; SSO Session Max **10 hrs**. **Leave Client Session Idle and Client Session Max at `0`** (unset) so they inherit the SSO values — setting them shorter than the SSO timeouts causes premature client-session expiry and the "logged out after a short time" class of bug. Leave the offline-session and login-timeout fields at defaults.

**Realm settings → Tokens tab:** Access Token Lifespan **5 min**. Refresh-token rotation (Revoke Refresh Token / Refresh Token Max Reuse) is configured per §16.5 / setup guide D.9 — **keep rotation OFF until the app implements single-flight refresh (§8.6.1)**; do not enable it here as part of baseline realm setup.

**Realm settings → Security defenses → Brute force detection:** enable, strategy **Lockout temporarily**, with explicit values (do not rely on defaults):
- Max login failures: **30**
- Wait increment: **1 minute**
- Max wait: **15 minutes**
- Failure reset time: **12 hours**
- Quick login check milliseconds: **1000**
- Minimum quick login wait: **1 minute**
- Max temporary lockouts: default

Note: brute-force detection only protects **Keycloak-local password authentication**. yourapp.com is federated-only (no local user passwords — auth happens at Google/Microsoft/GitHub), so this is near-inert for the normal login path. Enable it anyway to protect the admin console and any future local accounts, but it is not load-bearing for federated users.

**Realm settings → Security defenses → Headers:**
- **X-Frame-Options: `SAMEORIGIN`** (the default — do **not** force `DENY`). ⚠️ **This header governs framing of *Keycloak's own* login/consent pages, NOT the yourapp.com app.** Whether the yourapp.com app can be embedded in an iframe (relevant to the future browser-plugin work) is controlled entirely by the **app server's** `Content-Security-Policy: frame-ancestors` / `X-Frame-Options`, set in the .NET app — not here. `SAMEORIGIN` is chosen over `DENY` because it is the more compatible default and avoids breaking any Keycloak-hosted iframe mechanism (e.g. the OIDC check-session iframe), while still preventing cross-origin embedding of Keycloak pages, which have no legitimate reason to be framed. yourapp.com uses back-channel logout, not the check-session iframe, so either value is functionally safe — default `SAMEORIGIN` is the deliberate choice.
- **Content-Security-Policy:** leave Keycloak's default (`frame-src 'self'; frame-ancestors 'self'; object-src 'none';`).
- HSTS (`Strict-Transport-Security`): Max Age **31536000** in prod; skip for local/test.

**Organizations:** the realm does not use Keycloak Organizations (per Invariant 8). If created without Organizations enabled, there is **no Organizations toggle in Realm settings — that absence is expected, not a misconfiguration.** ⚠️ **26.6.0 caveat:** the 26.6.0 migration may auto-inject a `Conditional Organization` sub-flow into custom browser flows. Confirm this sub-flow is set to **Disabled** (not Conditional) in `browser-federated-only` and any other custom flow — see §11.6 flow structure. Leaving it Conditional while Organizations is unused can add an unwanted step to the login flow.

### 11.3 Create OIDC Web Client

1. **Clients → Create client**. Client type: OIDC. Client ID: `yourapp-{env}-web`.
2. Client authentication: On. Authorization: Off. Standard flow only.
3. Root URL, redirect URIs, post-logout URIs per §8.1.
4. **Credentials tab:** copy secret to `yourapp-keycloak-web-client-secret-{env}`.
5. **Settings tab → Logout settings (near bottom of Settings tab in Keycloak 26.x):**
   - **Front channel logout: Off** (intentionally — browser third-party cookie policies make front-channel iframe logout unreliable; back-channel is the authoritative mechanism)
   - Toggling Front channel logout to Off causes the panel to switch to back-channel fields. If they don't appear, that's a UI bug in your Keycloak version; fall back to the Admin REST API.
   - Backchannel logout URL: per §8.1 (e.g., `https://prod.yourapp.com/auth/backchannel-logout`)
   - Backchannel logout session required: On (so the `logout_token` carries the `sid` claim, enabling precise session targeting)
   - Backchannel logout revoke offline sessions: Off (this realm doesn't issue offline tokens to interactive users)
6. **Advanced tab → Proof Key for Code Exchange Code Challenge Method:** `S256`.

### 11.3b Configure Protocol Mappers on `yourapp-{env}-web`

Keycloak's default token output doesn't include the claims §8.3 specifies. Three mappers must be added to the client's dedicated client scope (`yourapp-{env}-web-dedicated`) to produce the expected token shape.

**Navigation:** Clients → `yourapp-{env}-web` → Client scopes tab → click `yourapp-{env}-web-dedicated` → Mappers tab → Add mapper → By configuration.

**On the "Add to lightweight access token" toggle (all mappers): leave OFF.** The lightweight access token is a Keycloak feature (per-client, off by default) that strips most claims from the access token to keep it small. The web client does **not** use lightweight access tokens, so this toggle is inert — Off is correct. You would only turn it On for these mappers *if* you deliberately switched the client to lightweight tokens; otherwise the `idp` / `microsoftTenantId` / `googleHd` / audience claims the app depends on would be dropped from the token. Every mapper below uses **Add to access token = On, Add to lightweight access token = Off.**

**Mapper 1 — Audience** (fixes `aud=account` quirk; without this, the access_token's audience won't include the client and ASP.NET Core JWT validation will reject it):

| Field | Value |
|---|---|
| Mapper Type | Audience |
| Name | `yourapp-{env}-web-audience` |
| Included Client Audience | `yourapp-{env}-web` |
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
- With `kc_idp_hint=<provider>` in the URL: Identity Provider Redirector succeeds by redirecting to that IdP. Flow ends. (This is the normal yourapp.com-initiated path.)
- Without any hint (fallback): Identity Provider Redirector returns ATTEMPTED (neutral — no hint, no default). Flow tries the next Alternative — Forms — which renders the standard Keycloak login template. That template includes the IdP buttons in the social section. User clicks one → goes through Identity Provider Login → federation proceeds. The username/password fields visible on the page are cosmetic dead weight; no user has a password to submit.
- Until the Keycloakify theme is installed, the fallback page will show those visible-but-useless username/password fields alongside the IdP buttons. That's acceptable — clicking an IdP button works.

### 11.5b Make `firstName` and `lastName` Optional in User Profile

Keycloak 26.x's User Profile feature requires `firstName` and `lastName` on every user by default. Federated identities from upstream IdPs (especially Microsoft personal accounts) often omit these claims, which triggers a `UPDATE_PROFILE` required action that prompts the user with an "Update Account Information" form — a violation of Invariant 3 (users never see Keycloak).

yourapp.com stores user names in its own database (Invariant 8), so Keycloak doesn't need these fields. Make them optional:

1. Realm settings → User Profile tab → Attributes
2. Edit `firstName` → Permission → uncheck **Required** for both User and Admin contexts → Save
3. Edit `lastName` → same change → Save

After this, federated users with no name claims are created silently with empty `firstName`/`lastName`, and Keycloak does not prompt them.

### 11.6 Bind the Custom Browser Flow

Open `browser-federated-only` → Action menu → Bind flow → Browser flow → Save.

### 11.7 Configure Required Actions

All actions → Default Action Off (Configure OTP, Update Password, Update Profile, Verify Email, Verify Profile, Terms and Conditions, Delete Account, etc.).

### 11.7a IdP settings page — what to change vs. leave at defaults

Each IdP's **Settings** page (Google §11.8, Microsoft §11.9, GitHub §11.10, SAML §11.11) exposes ~20 toggles. **Leave the vast majority at their defaults.** Only the following are load-bearing for yourapp.com's design — several already default to the right value, and are called out here so they aren't flipped off by accident:

| Setting | Value | Why it matters |
|---|---|---|
| **First login flow override** | `first-broker-login-no-prompt` | The custom auto-linking flow (§11.4). Must be set on **every** IdP, or a returning federated user hits the default review-profile prompts. Smoke-verified per IdP. |
| **Sync mode** | `Force` | Re-syncs mapped attributes (`hd`→`googleHd`, `tid`→`microsoftTenantId`, profile fields) from the IdP on **every** login, keeping them current. `Import` (first-login-only) would let `microsoftTenantId`/`googleHd` go stale if a user's tenant/domain ever changed. The IdP is the source of truth (thin-broker model), so `Force` is correct — with the implication that manual edits to those user attributes in Keycloak are overwritten on next login. |
| **Trust Email** | `On` (Google, Microsoft) | Trusts the IdP's `email_verified` and skips Keycloak-side verification. This is what makes email-based auto-linking (§11.4) work without a verification round-trip. **Deliberately On for Google/Microsoft** (authoritative for their users' email). Reconsider per-IdP only for a *low-trust* generic OIDC provider. |
| **Accepts `prompt=none` forward from client** | `On` | Lets the silent-SSO check pass through to the upstream IdP. The MCP consent flow and the app's `prompt=none` re-auth in the callback depend on it. |
| **Send `id_token_hint` in logout requests** | `On` | Correct logout behavior against the upstream IdP. |

**Leave at defaults (do not change):** Store tokens / Stored tokens readable (Off), Access Token is JWT (Off), Disable user info / Disable nonce / Disable type claim check (Off), Account linking only (Off), Hide on login page (Off), Case-sensitive username (Off), Verify essential claim (Off), Supports client assertions (Off), Post login flow (None), Pass login_hint / max_age (Off), Allowed clock skew (0 unless you observe time-sync issues).

⚠️ **The two things that silently break claims if wrong** — verify both on each IdP:
1. **Sync mode = Force** (above), and
2. the **attribute-importer mappers on the Mappers tab** (`hd`→`googleHd` §11.8, `tid`→`microsoftTenantId` §11.9). These live on a *separate* Mappers tab from the Settings page. If either the mapper is missing or sync mode isn't Force, the `googleHd`/`microsoftTenantId` claims never populate — and then the §8.3.1 cross-IdP gating has nothing to gate on. Fails silently (no error, just absent claims).

### 11.8 Add Google as IdP

1. **Identity Providers → Add → Google.** Alias `google`.
2. Client ID, Client Secret from `yourapp-google-oauth-client-secret-{env}`.
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
5. **Branding & properties:** add logo, **publisherDomain `yourapp.com`** (NOT a per-env subdomain), TOS URL, Privacy URL.
6. **Certificates & secrets → New client secret.** Description: `keycloak-broker-{env}`. Expiry 24 months. Store value as `yourapp-entra-broker-client-secret-{env}`.
7. **API permissions:** Microsoft Graph delegated → `openid`, `profile`, `email`, `offline_access`, `User.Read`. Grant admin consent.
8. **Publisher domain verification:** before Microsoft can verify `yourapp.com` as the publisher, the file `https://yourapp.com/.well-known/microsoft-identity-association.json` must be hosted at the apex with the JSON contents Microsoft provides during verify. See §10.7.

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
3. Register, generate client secret, store as `yourapp-github-oauth-client-secret-{env}`.

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
7. **No link to a Keycloak Organization** (Invariant 8). The mapping from this IdP alias to a yourapp.com Organization is recorded in yourapp.com's application data (see §12.10).

### 11.12 Disable Account Console

Clients → `account-console` Enabled Off; `account` Enabled Off. Verify URLs return 404.

### 11.13 Create Admin API Service Account Client

1. **Clients → Create client.** Client ID: `yourapp-{env}-admin-api`. Client authentication On. Service accounts roles On. All flows Off.
2. **Service accounts roles tab → Assign role** → modal **Filter by clients** → search `realm-management` → assign the following client roles:

   ```
   view-users
   manage-users
   view-realm
   view-clients
   manage-clients
   query-users
   query-groups
   view-identity-providers
   manage-identity-providers
   ```

3. **Credentials tab:** copy secret to `yourapp-keycloak-admin-api-client-secret-{env}`.

**Notes on the role list:**
- This list has evolved across PRD revisions. If updating an existing service account from an earlier PRD version, re-check that all the above roles are assigned (in particular `view-identity-providers`, `manage-identity-providers`, `view-clients`, and — as of the Option B decision — `manage-clients` were added in later revisions).
- `view-clients` (read-only) is needed for the smoke test's client-configuration validation (Tests 11–12), OpenTofu drift detection, and general realm administration.
- ⚠️ **`manage-clients` IS required — this reverses an earlier PRD stance.** Earlier revisions said yourapp.com "does not manage clients at runtime — clients are static IaC" and forbade `manage-clients`. **The MCP/Option B decision changed that premise:** yourapp.com performs runtime client writes on DCR'd MCP clients. **Update (CRP decision):** the *bootstrap* writes — assigning `mcp-default` + author-bundle scopes and binding `browser-mcp-tenant-pick` — now happen **atomically at registration inside Keycloak via the `McpClientRegistrationPolicy` CRP** (`KEYCLOAK_MCP_SPI_DESIGN.md` §5.8), NOT via app Admin API calls. The app's `/mcp/consent` still performs tenant-specific client writes (the wizard's scope-override/consent recording per `YOURAPP_WEB_MCP_ENDPOINTS.md` §7.5) and may idempotently re-assert the bootstrap, so it **still needs `manage-clients`** for those. It is scoped to client writes only — far narrower than `realm-admin`. The static-IaC clients (web, admin-api) remain IaC-managed; `manage-clients` exists for the *DCR'd* clients, which are inherently runtime-created and cannot be IaC.
- **Do not assign** `view-organizations` or `manage-organizations` — these role names do not exist as standalone client roles in current Keycloak 26.x. Earlier PRD revisions listed them in error.
- **Do not assign** `manage-realm` — not needed without Keycloak Organizations (which we don't use per §5.1 / Invariant 8). If a 403 surfaces from any Admin API call yourapp.com makes, the fix is to identify the specific missing role from the realm-management role list, not to escalate to `manage-realm`.
- **Do not assign** `create-client` or `realm-admin` — over-privileged. `create-client` isn't needed (DCR clients self-register via the registration endpoint, not via the admin API); `realm-admin` is the full composite superuser role. Smoke Test 12 warns if either is present.

### 11.14 Apply the yourapp Theme

After the theme JAR has been built and deployed per `KEYCLOAK_THEMING_GUIDE.md`:

1. **Realm settings → Themes → Login Theme:** select `yourapp`.
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

# (Future) yourapp Keycloakify theme JAR added here per KEYCLOAK_THEMING_GUIDE.md.
# COPY --chown=keycloak:keycloak ./themes/yourapp-theme.jar /opt/keycloak/providers/

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
YOURAPP_KEYCLOAK_ADMIN_API_CLIENT_SECRET_TEST=<from-keycloak-after-setup>
YOURAPP_KEYCLOAK_WEB_CLIENT_SECRET_TEST=<from-keycloak-after-setup>
YOURAPP_ENTRA_BROKER_CLIENT_SECRET_TEST=<from-entra-app-registration>
YOURAPP_GOOGLE_OAUTH_CLIENT_SECRET_TEST=<from-gcp-oauth-client>
YOURAPP_GITHUB_OAUTH_CLIENT_SECRET_TEST=<from-github-oauth-app>
```

**4. Per-developer IdP OAuth registrations** with `http://localhost:8080/...` redirect URIs.

**5. Run:**

```bash
docker-compose -f docker-compose.test.yml up -d --build
```

Then follow §§11.1–11.14 substituting `yourapp-test` and `localhost:8080` URLs. Skip §11.9 step 8 (publisher domain verification) — Microsoft does not verify localhost.

**6. Smoke test:**

```bash
export YOURAPP_ENV=test
export ADMIN_CLIENT_SECRET="$YOURAPP_KEYCLOAK_ADMIN_API_CLIENT_SECRET_TEST"
./keycloak-smoke-test.sh
```

### 11.16 Verification Checklist

The smoke-test script `keycloak-smoke-test.sh` automates server-side tests (1–13) and prints URLs for browser-driven federation tests (14–19).

Automated coverage:
- Test 1: realm liveness via `.well-known/openid-configuration`
- Test 2–3: account console disabled (`/realms/yourapp-{env}/account` returns 4xx)
- Test 4: admin API client credentials grant works (functional)
- Test 5: admin API list users (validates `view-users`/`query-users` roles)
- Test 6: list IdPs (validates `view-identity-providers` role; classifies IdPs by `providerId` + URL pattern so the generic-OIDC Microsoft setup is recognized regardless of alias)
- Test 7: browser flow binding is `browser-federated-only`
- Test 8: no Required Actions set as Default
- Test 9: GCP Secrets Manager — every expected secret name from §10.8 exists; warning on misnamed orphans
- Test 10: Microsoft Entra app registration — displayName matches convention, signInAudience is multi-tenant + MSA, redirect URI registered, publisherDomain is `yourapp.com`, Graph API permissions present, client secret not expired (warn within 30 days), secret description follows convention
- Test 11: `yourapp-{env}-web` client configuration — protocol/confidentiality/flow flags per §8.2, PKCE method = S256, front-channel + back-channel logout configured, expected redirect URI registered
- Test 12: `yourapp-{env}-admin-api` client configuration — flow flags (service accounts on; all interactive flows off), service-account user present, exact realm-management role list assigned per §11.13 (all required roles including `manage-clients` for Option B §7.5; no over-privileged roles like `realm-admin`/`manage-realm`/`create-client`)
- Test 13: PKCE enforcement (behavioral) — sends auth request without `code_challenge`, verifies Keycloak rejects it with the expected `error=invalid_request` referencing `code_challenge_method`; catches the case where the PKCE attribute is set in config but not actually enforced

Manual coverage:
- Test 14: fallback IdP picker (no `kc_idp_hint`) — themed login page with all configured IdP buttons
- Tests 15–17: direct-to-IdP routing per alias for Google, Microsoft work account, Microsoft personal MSA
- Test 18: GitHub federation
- Test 19: token exchange — decode resulting id_token, verify claim contract per §8.3

---

## 12. Enterprise Tenant Onboarding

For each enterprise customer, three things must happen: a yourapp.com Organization exists, the customer's IdP is connected (via Microsoft admin consent / Google Workspace allowlist / SAML metadata exchange), and users can then sign in.

**Implementation note throughout this section:** sub-sections describe the *required behavior and persisted state* for tenant onboarding. They do not prescribe specific table names, column types, or storage choices. Map each requirement to yourapp.com's existing data model. Consult the codebase before introducing new persistence — yourapp.com may already have organization, user, or tenant-connection structures that should be extended rather than duplicated.

> **⚠️ Architecture-in-evolution note.** This section currently describes separate-per-IdP-family persistence (`org_microsoft_connection`, `org_google_connection`, etc.). That model is **interim**. A planned rewrite (see §15: *Directory-binding tenancy model*) will collapse these into a single polymorphic `yourapp_org_directory_binding` model where a tenant has 1..N `(idp_type, identifier)` bindings, and tenant context is resolved per-session by matching the current token's `(idp, microsoftTenantId | googleHd | …)` tuple against active bindings. The eventual model preserves cross-IdP user identity (one Keycloak user can authenticate via Microsoft, Google, GitHub) while gating tenant access by the current session's IdP — which gives correct offboarding, clean directory migrations (Microsoft → Google Workspace), and explicit handling of "personal-IdP sessions of someone who's also in a corporate tenant." Implementations of the per-IdP-family sub-sections below should be written so they can be refactored into the polymorphic model without data loss.

### 12.1 Pattern & Rationale

1. **A yourapp.com Organization exists** (created during customer signup).
2. **The customer's IdP is connected to that Organization.** Mechanics differ per IdP family:
   - Microsoft Entra: admin consent.
   - Google Workspace: customer Workspace admin allowlists OAuth client.
   - SAML: customer configures yourapp.com's SP metadata; yourapp.com provisions a SAML IdP entry in Keycloak via Admin REST API.
3. **Users from the customer's IdP can sign in.**

### 12.2 Microsoft Admin Consent Endpoint

```
https://login.microsoftonline.com/{tenant}/adminconsent
  ?client_id={yourapp-prod-entra-app-id}
  &state={yourapp-state-token}
  &redirect_uri=https://prod.yourapp.com/auth/microsoft/admin-consent-callback
```

`{tenant}` is typically `organizations` (unknown tenant) or the tenant GUID/domain. Not `common`.

### 12.3 State Token Persistence Requirement

yourapp.com's backend must persist short-lived state for each in-flight Microsoft admin consent attempt.

**Required logical fields:**

| Field | Purpose |
|---|---|
| state token | High-entropy random value (≥32 bytes base64url). Used as the OAuth `state` parameter for CSRF protection and callback correlation. Serves as the lookup key. |
| initiating organization | Reference to the yourapp.com Organization on whose behalf consent is being granted. |
| initiating user | Reference to the yourapp.com user who clicked Connect (for audit trail). |
| expected tenant ID | Optional. If the customer has supplied their Microsoft tenant in advance, store it here to validate the callback's `tenant` parameter against it. |
| created at | Timestamp. |
| expires at | Timestamp. Records are short-lived (10 minutes from creation). |
| consumed at | Timestamp, nullable. Set when the callback successfully completes consent. Prevents replay. |

**Lifecycle:**
- Created when an org admin clicks "Connect Microsoft 365" in yourapp.com.
- Read once on callback receipt; validated for non-expiry, non-consumption, and (if `expected tenant ID` set) tenant match.
- On successful processing: `consumed at` set; the durable tenant connection (§12.4) is created.
- Expired/unused records can be cleaned up periodically.

*Implementation note: storage choice (relational, KV, cache) and naming are at the implementer's discretion. The records are short-lived and not historically interesting — relational storage with periodic cleanup is fine; a TTL-based KV is also fine.*

### 12.4 Tenant Connection Persistence Requirement

After a successful admin consent, yourapp.com's backend must persist a durable record linking the yourapp.com Organization to the Microsoft tenant.

**Required logical fields:**

| Field | Purpose |
|---|---|
| yourapp organization | Reference to the yourapp.com Organization. |
| Microsoft tenant ID | The tenant GUID received from Microsoft's callback. |
| consent granted at | Timestamp. |
| consent granted by | Identifier (email or user reference) of the admin who consented. |
| consent revoked at | Timestamp, nullable. Soft-delete marker when consent is withdrawn (either via Microsoft-side revocation detected reactively, or via yourapp.com self-service disconnect). |

**Identity:** the natural key is (yourapp organization, Microsoft tenant ID). One yourapp.com Organization may be associated with multiple Microsoft tenants (subsidiaries, M&A). The reverse lookup — given a Microsoft tenant ID, find the connected yourapp.com Organization — is the hot path during sign-in routing (§12.9).

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

Admin in Organization Settings → Identity → "Connect Microsoft 365" → Continue → yourapp.com creates in-flight consent record, redirects to Microsoft admin consent → admin signs in and accepts → redirect back to yourapp.com callback → state validated → tenant connection persisted → success page shown. Subsequent sign-ins from any user in that Microsoft tenant work silently through the standard login flow.

### 12.7 Error Handling

| Scenario | Detection | UX |
|----------|-----------|-----|
| Admin not Global Admin | `error=access_denied&error_subcode=user_consent_required` | "Ask your Global Administrator to complete this step." |
| Admin clicks Cancel | `error=access_denied` | "Connection canceled." |
| State token expired (>10 min) | yourapp.com detects via §12.3 record `expires at` | "Consent session expired. Try again." |
| State already consumed | yourapp.com detects via §12.3 record `consumed at` set | "Link already used. Start over." Log warning. |
| Tenant mismatch | yourapp.com detects when §12.3 `expected tenant ID` set and doesn't match callback | "Sign in with an account from {expected-domain}." |
| Customer tenant blocks consent | Various Microsoft errors | "Your tenant's policies prevent third-party consent. Contact IT." |
| Microsoft endpoint timeout | yourapp.com timeout | "Couldn't complete connection. Try again." |

### 12.8 Consent Revocation

Microsoft does not notify on revocation. Detect reactively when federation fails for a known-connected tenant (`microsoft_tenant_id` matches a §12.4 record with no `consent revoked at`); mark `consent revoked at`, emit `OrganizationMicrosoftTenantDisconnected` Activity.

yourapp.com should also provide self-service disconnect in Organization Settings → Identity, which calls Microsoft Graph to revoke the service principal in the customer tenant and marks the §12.4 record revoked.

### 12.9 Sign-in Routing

Strategy B (email-first home discovery) is the production target. Requires:
- A background job that fetches verified domains for each connected Microsoft tenant via Graph API (`GET /organization` + `GET /domains`), persisted in yourapp.com application data linked to the §12.4 tenant connection. Refresh cadence ~24 hours.
- The login screen email-first flow.
- The Microsoft IdP's Forwarded Query Parameters set to `login_hint,domain_hint,prompt` per §11.9 step 16.
- Fallback to "Sign in with personal Microsoft account" button for users whose domain doesn't match any connected tenant.

*Implementation note: the verified-domain cache is application-layer state. Storage choice (table, columns, indexing) is at the implementer's discretion. The hot-path query is "given an email domain, find the connected Microsoft tenant and the corresponding yourapp.com Organization."*

**Personal MSA handling.** Personal Microsoft accounts (`microsoftTenantId == 9188040d-6c67-4c5b-b112-36a304b66dad`) are not associated with any enterprise tenant. They sign in via the Microsoft IdP but are rejected at the application authorization layer when attempting to join an enterprise Organization.

### 12.10 Analogous Patterns for Other IdPs

**Google Workspace.**

Customer Workspace admin allowlists the per-env yourapp.com Google OAuth client ID in their Google Admin Console (Security → API controls → App access control → Configure new app). No OAuth-protocol-level admin consent flow exists — it's a manual setup step in the customer's admin UI.

*Persistence requirement:* yourapp.com must record the connection between a yourapp.com Organization and the customer's Google Workspace, with: yourapp organization, Workspace domain, verified-at timestamp, verified-by reference. Lifecycle: created when an admin self-attests the allowlisting is done and yourapp.com confirms via a successful test sign-in by the admin. Soft-delete on disconnect.

**SAML enterprise customers.**

Two-way metadata exchange. yourapp.com provides the customer with its SP metadata (downloadable from Organization Settings → Identity → SAML, or via direct link to Keycloak's metadata endpoint). The customer configures their IdP, then provides yourapp.com with their IdP metadata XML (uploaded via the settings UI). yourapp.com backend then calls Keycloak Admin REST API (§8.7) to provision a SAML IdP entry with alias `saml-<customer-slug>` at the realm level (not linked to a Keycloak Organization per Invariant 8).

*Persistence requirement:* yourapp.com must record the connection between a yourapp.com Organization and the provisioned Keycloak SAML IdP alias, with: yourapp organization, Keycloak IdP alias (`saml-<slug>`), customer IdP entity ID, connected-at timestamp, lifecycle state (active/revoked). This mapping is the bridge between Keycloak's per-alias IdP entries and yourapp.com's Organization model. The hot-path query is "given a yourapp.com Organization, find the Keycloak IdP alias to use for sign-in routing."

*Implementation note for all three (Microsoft, Google, SAML):* the connection records may map to a single unified "tenant connection" abstraction in yourapp.com's data model, or to three separate per-provider records, or some hybrid. The choice is for the implementer to make based on the existing data model and the rest of the application's domain model. The PRD specifies only the required behavior and logical fields per provider.

---

## 13. Realm Configuration Automation — OpenTofu

### 13.1 Decision

**Tool: OpenTofu** (https://opentofu.org). Compatible with the Terraform Keycloak provider.

**Out of scope:**
- IdP credentials at the source (Google Cloud OAuth client, Entra app registration, GitHub OAuth App).
- GCP Secrets Manager entries.
- Per-customer SAML IdPs — runtime, via Keycloak Admin REST API by yourapp.com.
- Keycloak deployment itself.

**In scope:**
- Realm creation and settings (excluding Organizations, which we don't use).
- Custom authentication flows and bindings.
- Required Actions configuration.
- Built-in IdPs (Google, Microsoft via generic OIDC with alias `microsoft-oidc`, GitHub).
- The `yourapp-{env}-web` and `yourapp-{env}-admin-api` clients.
- Account console disablement.
- Theme selection.

### 13.2 Repository Structure

```
yourapp-infra-keycloak/
├── modules/
│   ├── yourapp-realm/
│   ├── yourapp-realm-google-idp/
│   ├── yourapp-realm-microsoft-idp/         # alias: microsoft-oidc
│   ├── yourapp-realm-github-idp/
│   ├── yourapp-realm-web-client/
│   └── yourapp-realm-admin-api-client/
├── environments/
│   ├── prod/
│   ├── dev/
│   └── test/
├── scripts/
│   └── keycloak-init.sh
└── README.md
```

(No `yourapp-realm-organizations` module — Organizations is not used per Invariant 8.)

### 13.3 The `keycloak-init.sh` Wrapper

```bash
./scripts/keycloak-init.sh --env prod
```

Responsibilities:
1. Validate `YOURAPP_ENV` ∈ `{prod, dev, test}`.
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

The current `yourapp-prod` realm will be `tofu import`-ed rather than recreated. Procedure:

1. Write OpenTofu modules to match current state exactly (including alias `microsoft-oidc`, role list per §11.13, etc.).
2. `tofu import` each existing resource.
3. `tofu plan` should show zero changes.
4. Going forward, all changes flow through OpenTofu (Invariant 7).

### 13.6 State Management

Per-environment OpenTofu state in GCS buckets with object versioning:
- `gs://yourapp-tofu-state-prod/keycloak/`
- `gs://yourapp-tofu-state-dev/keycloak/`
- `gs://yourapp-tofu-state-test/keycloak/` (or developer-local)

### 13.7 Tracked in v1.6

Section commits to OpenTofu and reflects v1.6's drop of Organizations. Actual `.tf` files and `keycloak-init.sh` are the next deliverable.

---

## 14. Open Questions

1. **Single-org-per-user constraint** — does yourapp.com enforce that a user belongs to exactly one Organization? Affects the tenant-connection data model.
2. **Service account model for AI agents** — parked.
3. **Step-up authentication for sensitive operations** — `acr` claim enforcement timing.
4. **Customer SAML self-service** — via yourapp.com admin UI or manual?
5. **CASB-managed tenants** — manual escalation path.
6. **Microsoft tenant domain refresh cadence** — 24h proposed.
7. **Event bus integration timeline** — parked.
8. **Personal MSA in enterprise orgs** — confirm policy.
9. **GCS state bucket retention** — Object Versioning enabled? Standard practice yes; confirm.
10. **Theme deployment cadence** — see `KEYCLOAK_THEMING_GUIDE.md`.

---

## 15. Future Work (Tracked, Out of Scope for v1.6)

### Directory-binding tenancy model (highest-priority follow-up)

**Status:** discussed and agreed; deferred to a focused next session after auth migration completes.

**Problem this resolves.** The current §12 persistence model treats per-IdP-family connections as separate concepts (`org_microsoft_connection`, `org_google_connection`, anticipated `org_saml_connection`). This obscures a more fundamental concept: **a tenant is an abstract organizational entity, separate from the directories that authenticate its members.** A tenant can have multiple directory bindings over its lifetime (e.g., Microsoft Entra → Google Workspace migration), multiple concurrent bindings (multi-IdP enterprises), or zero bindings (open sign-in by verified email domain).

The first-broker-login-no-prompt flow (§11.4) auto-links a user's federated identities across IdPs by email match. This produces a single Keycloak user with multiple identity links (Microsoft + Google + GitHub all pointing to the same user record). User-attribute claims like `microsoftTenantId` and `googleHd` persist on that user record indefinitely (§8.3). Without an explicit session-scoped tenant resolution rule, this creates an authorization risk: a user signed in via GitHub could inappropriately inherit tenant access granted to their Microsoft-authenticated identity, simply because they share an email.

**Target model.**

A tenant (one row in `yourapp_org`) has 0..N **directory bindings**. Each binding is a polymorphic `(idp_type, identifier)` tuple, with an `active` flag for lifecycle management:

| Binding type | Identifier semantics | Example |
|---|---|---|
| `microsoft-oidc` | Microsoft Entra tenant GUID | `(microsoft-oidc, 8a2b9c4d-...)` |
| `google` | Google Workspace primary domain | `(google, acme.corp)` |
| `saml-<slug>` | Keycloak SAML IdP alias (one per customer) | `(saml-acme, n/a)` |
| `any-idp` (open sign-in) | verified email domain | `(any-idp, acme.corp)` — opt-in low-security model |

Tenant context is resolved **per-session**, not per-user. On every authenticated request, yourapp.com's middleware:

1. Builds the session tuple from token claims:
   - `(microsoft-oidc, claims["microsoftTenantId"])` when `idp == "microsoft-oidc"`
   - `(google, claims["googleHd"])` when `idp == "google"` and `hd` is present
   - `(github, *)` when `idp == "github"` (matches only `any-idp` bindings if at all)
   - `(saml-<alias>, *)` when `idp` starts with `saml-`
2. Looks up the active `yourapp_org_directory_binding` rows matching this tuple
3. Resolves tenant context (or "no tenant context" for personal-IdP sessions of users without a matching corporate binding)
4. Verifies user membership in the resolved tenant before granting access

**Migration scenarios this enables correctly.**

- **acme.corp migrates Microsoft → Google Workspace:** admin adds a Google binding alongside the existing Microsoft binding. Both work during a transition window. Eventually the Microsoft binding is deactivated. Employees experience zero re-onboarding friction.
- **Employee leaves acme.corp:** acme.corp's IT disables their Microsoft account. The session-scoped resolution means even if the ex-employee's GitHub account still asserts `foo@acme.corp` as an email, GitHub sessions match no acme.corp binding → no acme.corp access. Offboarding works without per-app revocation if the directory is properly de-provisioned upstream.
- **Personal-IdP cross-contamination prevented:** a user who is both a personal Gmail user AND an acme.corp employee signs in via personal Gmail; that session matches no enterprise binding (no `hd` claim, or `hd` ≠ acme.corp) → personal access only, no leak into acme.corp's data.

**Implementation prerequisites.**

1. **Token claims contract** (already in place per §8.3 and §11.3b): `idp`, `microsoftTenantId`, `googleHd` claims emitted from Keycloak with correct user-fact-vs-session-fact discipline documented in trust rules.
2. **Auth migration from Auth0 to Keycloak completed** in yourapp.com codebase. This rewrite assumes Keycloak is the live IdP broker, not Auth0.
3. **Schema design session** to define `yourapp_org_directory_binding` (polymorphic columns vs. per-type tables, indexes for fast lookup by `(idp_type, identifier)`, audit columns).
4. **Backfill from existing per-IdP-family rows** if any production data exists in `org_microsoft_connection` / `org_google_connection` shape by the time of cutover.

**Out-of-scope for this rewrite (track separately):**

- **Directory sync** (Microsoft Graph subscriptions / Google Workspace audit feeds → automatic membership de-provisioning). Pre-PMF, reactive de-provisioning (sessions silently lose tenant context as upstream directories revoke users) is acceptable.
- **Cross-binding identity reconciliation** (e.g., proving that a Google-authenticated `foo@acme.corp` is the same person as a previously-Microsoft-authenticated `foo@acme.corp`). For the initial rewrite, the existing Keycloak-level email-match auto-linking (§11.4) carries this forward; explicit user-controlled identity merging is a later concern.

**Estimated scope:** one focused design session for the schema and resolution algorithm; one or two implementation sessions for the persistence layer and middleware; one for backfill and cutover. Auth migration must land first.

---

### Other tracked follow-ups

- **OpenTofu IaC implementation** (per §13 — next major session after auth migration).
- **Microsoft Publisher Verification application** (multi-day lead time).
- **Step-up authentication** via `acr` claim enforcement.
- **Token Exchange** for AI agent delegation.
- **Custom Keycloak Event Listener SPI** for the platform event bus. **Note:** this is a *different* SPI from the Authenticator + Realm Resource Provider SPI specified in §16.8, which is **in scope for v1 MCP launch**. The two SPIs share build infrastructure (both deploy as JARs in the Keycloak Docker image) but solve different problems and ship independently. The Event Listener bridges Keycloak events (login success/failure, IdP federation, user CRUD, session termination, admin API ops) into yourapp.com's platform event bus for audit/notification purposes; it has no dependency on MCP and is not on the critical path for MCP v1.
- **Themed account management UI** inside yourapp.com.
- **Customer self-service onboarding UI** for all IdP families.
- **Microsoft tenant domain background job** for email-domain home discovery.
- **Email-first login routing** (Strategy B in §12.9).
- **Consent revocation detection** for Microsoft tenants.
- **Local username/password tier** (B2C / contractor) — feature flag.
- **Apple Sign In** — deferred. When revived, configure via the `klausbetz/apple-identity-provider-keycloak` extension.

---

## 16. MCP Support — OAuth 2.1 & Dynamic Client Registration

### 16.1 Strategic Context

The fundamental rationale for migrating from Auth0 to self-hosted Keycloak was the cost cliff: Auth0's OAuth 2.1 + Dynamic Client Registration tier (required for Model Context Protocol endpoint support) is approximately $2,500/month. That tier is necessary because MCP clients — Claude Desktop, Cursor, third-party agents, internal CLI tools — aren't knowable in advance and must self-register at runtime. Without DCR, every MCP integration requires manual client provisioning, which doesn't scale. Self-hosted Keycloak provides DCR as a built-in capability at no marginal cost beyond the operating costs already budgeted (§10).

This section specifies how yourapp.com's Keycloak realm exposes MCP-compatible authorization. The corresponding MCP server endpoint on yourapp.com (resource server, protected resource metadata) is application work covered separately.

### 16.1.5 Phase 0 Prerequisites and Sequencing

MCP support depends on work that is not in this PRD — partly because it's application work (YourApp web), partly because it deserves its own implementation spec (the SPI JAR). This sub-section makes the dependency chain explicit so the work can be scheduled correctly.

#### Hard prerequisite: Auth0 → Keycloak migration of yourapp.com app

The path (iii) consent flow (§16.7.2) requires the user to be in a **Keycloak SSO session** when they arrive at `/mcp/consent`, so that the silent `prompt=none` OIDC bootstrap (step 4 of the flow) succeeds without user interaction. If yourapp.com is still running on Auth0 as its primary IdP, the user has an Auth0 session, not a Keycloak one, and the silent bootstrap fails — breaking the entire consent flow.

**Therefore: the auth migration described in §8 (yourapp.com ↔ Keycloak Integration) must complete before MCP end-to-end testing is possible.** The realm-side MCP configuration can be done in parallel, but it cannot be validated end-to-end until the app migration is complete.

#### Phase 0 work items, with where their specs live

| Item | Status | Spec location | Blocks |
|---|---|---|---|
| **Auth0 → Keycloak migration of yourapp.com app** | Not started | §8 of this PRD; ASP.NET Core 10 integration code | YourApp web `/mcp/consent` (silent SSO bootstrap), end-to-end MCP testing |
| **YourApp web `/mcp/consent` sub-app** | Not started | YourApp web specs (brainstorm document §3.4 enumerates the required changes); YourApp web design-system docs for component reuse | End-to-end MCP testing |
| **Custom Authenticator + Realm Resource Provider SPI** (Java/Kotlin) | Not started | §16.8 of this PRD has the architecture. Implementation-level decisions (Keycloak SPI version pinning, package layout, error handling, logging conventions, testing strategy) belong in a separate companion doc `KEYCLOAK_MCP_SPI_DESIGN.md`, to be authored when this track starts. | SPI Authenticator visible in admin console (smoke Test 14); MCP auth flow creation (Test 15); end-to-end MCP flow |
| **Keycloakify theme JAR** | Parked | `KEYCLOAK_THEMING_GUIDE.md` companion doc | Nothing for MCP v1 — the consent UX is in YourApp web, so theme only affects IdP login screens, which users barely see in federated flow |

#### Parallel vs. sequential

The auth migration is a serial blocker for the **app-side** of MCP (the silent SSO bootstrap, the YourApp web sub-app). It is NOT a blocker for the **Keycloak-side** of MCP:

- SPI implementation can start immediately. Each commit lights up another smoke test (Test 14 → Test 15 → ...).
- Realm configuration (Phases 2-4 in §16.11) can be applied immediately once the SPI is deployed. Smoke Tests 14-26 give you red→green progress without touching the yourapp.com app.
- The auth migration, the SPI development, and the `/mcp/consent` sub-app development can all proceed in parallel after their individual prerequisites are met.

**Recommended sequencing:**

1. **Right now**: Complete auth migration per §8. This unblocks the app-side path for everything else and removes Auth0 as a cost / complexity center independent of MCP.
2. **In parallel with (1)**: Author `KEYCLOAK_MCP_SPI_DESIGN.md` and start the SPI implementation. This is a different skill set (Java/Kotlin) and doesn't compete with (1) for the same engineer's attention.
3. **After (1) is far enough along that the app works on Keycloak**: Start the YourApp web `/mcp/consent` sub-app per the brainstorm doc §3.4.
4. **As SPI lands and realm config is applied**: Watch smoke Tests 14-26 progressively turn green.
5. **When (1), (2), (3) all complete**: Run smoke Test 33 (manual end-to-end). At this point the MCP launch is realm-validated AND app-validated.

#### What's NOT in scope for the Keycloak PRD

For clarity, the following work is intentionally NOT specified in this PRD even though it's required for MCP launch:

- YourApp web's `/mcp/consent` sub-app implementation (routes, components, state management, API endpoints). Tracked in YourApp web specs; brainstorm doc §3.4 enumerates required changes.
- YourApp web's "Connected Agents" user-menu entry and tenant-admin view. Tracked in YourApp web specs.
- yourapp.com's MCP server resource-server endpoint (`/mcp`), token validation middleware, RBAC enforcement at MCP call sites. Tracked in the MCP PRD (separate spec).
- The `PermissionMappingRegistry.AccessLevelInfo` extension for the Bundle ↔ RBAC mapping grid. Tracked in the yourapp.com Access Control PRD.
- SPI implementation specifics (Java/Kotlin code, Maven/Gradle setup, unit/integration tests). To be tracked in `KEYCLOAK_MCP_SPI_DESIGN.md` when that work starts.

The Keycloak PRD's scope ends at: **realm configuration, protocol design, and the contract the SPI must satisfy.** Implementation tracks pick up from there.

### 16.2 MCP Authorization Architecture (the RFC stack)

MCP clients perform authorization via four IETF specifications, all of which Keycloak implements:

| RFC | Title | Role | Keycloak endpoint |
|---|---|---|---|
| 6749 / OAuth 2.1 draft | OAuth 2.0 Authorization Framework (with 2.1 tightening) | Authorization code flow with PKCE | `/realms/{realm}/protocol/openid-connect/auth`, `/token` |
| 7591 | Dynamic Client Registration Protocol | MCP client self-registers and receives a `client_id` | `/realms/{realm}/clients-registrations/openid-connect` |
| 8414 | OAuth 2.0 Authorization Server Metadata | Discovery — MCP client finds the auth server's endpoints | `/realms/{realm}/.well-known/oauth-authorization-server` |
| 8707 | Resource Indicators for OAuth 2.0 | Tokens are bound to a specific MCP resource server URI | `resource` parameter on auth + token requests |
| 9728 | OAuth 2.0 Protected Resource Metadata | MCP server (yourapp.com) advertises which auth server protects it | **yourapp.com app**, not Keycloak: `/.well-known/oauth-protected-resource` |

The end-to-end flow when a user adds yourapp.com as an MCP server to Claude Desktop:

```
1. Claude Desktop fetches  https://prod.yourapp.com/.well-known/oauth-protected-resource
   (yourapp.com app responds with authorization_servers=[https://auth.yourapp.com/realms/yourapp-prod])

2. Claude Desktop fetches  https://auth.yourapp.com/realms/yourapp-prod/.well-known/oauth-authorization-server
   (Keycloak responds with the full metadata document including the DCR endpoint URL)

3. Claude Desktop POSTs to https://auth.yourapp.com/realms/yourapp-prod/clients-registrations/openid-connect
   Body: { client_name, redirect_uris, grant_types: ["authorization_code"], 
           token_endpoint_auth_method: "none", ... }
   Keycloak runs the DCR policies (§16.4), and on success returns a client_id +
   registration_access_token + registration_client_uri for future management.

4. Claude Desktop initiates the auth code flow with PKCE, supplying:
     resource=https://prod.yourapp.com/mcp
     scope=<the MCP scopes the client wants — see §16.3>

5. User authenticates via yourapp.com's IdPs (Google/Microsoft/etc.) and sees a 
   consent screen ("Claude Desktop wants to <human-readable scope text>").

6. Keycloak issues an access token with:
     aud = https://prod.yourapp.com/mcp
     scope = <granted scopes>
     azp = <Claude Desktop's dynamically-assigned client_id>
     sub, idp, microsoftTenantId, googleHd as per §8.3
   Refresh token is also issued, with rotation enabled (§16.5).

7. Claude Desktop calls yourapp.com's MCP server at /mcp with Authorization: Bearer <token>.
   yourapp.com validates the JWT (signature against Keycloak's JWKS, aud, exp, scope claims).
```

### 16.3 Scope Vocabulary

yourapp.com exposes a **6-atom semantic scope vocabulary** in the `yourapp:` namespace, surfaced to users and tenant admins through a **5-bundle consent ladder** that strictly nests. Raw scopes are available behind an "expand" affordance for advanced configuration; the default presentation is the bundle.

The vocabulary is in the `yourapp:` namespace (not `mcp:`) because the scopes describe **YourApp authority verbs**, not MCP protocol primitives. The MCP-protocol-axis cut (`mcp:tools:read`, `mcp:tools:execute`, etc.) collapses into roughly `read + write` when pressure-tested against the §16.3b design rule below — and that coarse cut doesn't capture meaningful consent decisions like `comment` vs `curate` or `share` vs `admin`.

#### 16.3.1 The six atomic scopes

| Scope | Verb semantics |
|---|---|
| `yourapp:read` | View resources the user has read access to. |
| `yourapp:comment` | Post comments and suggestions on resources the user has comment access to. |
| `yourapp:curate` | Tag, classify, organize, link (cross-app ontology relationships), archive/restore, move, rename. *Acts on existing resources; strictly reversible; no creation, no destruction.* This is the agent-safe long-lived role (canonical Library `Curate` pattern). |
| `yourapp:write` | Create new resources, edit content, delete. *Generative and destructive on the resource itself.* |
| `yourapp:share` | Grant or revoke access to others (RBAC-adjacent permission mutations). |
| `yourapp:admin` | Tenant-level administration: user management, role configuration, tenant settings, MCP enable/disable per role, audit-log configuration. Elevation tier — blast radius is tenant-wide, not resource-scoped. |

App-level subsets are also available when a client explicitly requests them: `yourapp:thinker:read`, `yourapp:thinker:curate`, etc. The default consent surface uses the platform-level scopes.

#### 16.3.2 The five consent bundles (strictly nested)

| Bundle | Scope set | RBAC mirror | Default? | Elevation? |
|---|---|---|---|---|
| **Viewer** | `read` | viewer | — | — |
| **Reviewer** | `read comment` | commenter / editor-light | — | — |
| **Curator** | `read comment curate` | (n/a as a single role; corresponds to Library `Curate` role) | — | — |
| **Author** | `read comment curate write share` | editor / owner | **Default** | — |
| **Admin** | `read comment curate write share admin` | tenant admin | — | **Required; prominent consent UI** |

Default consent is **Author** when a DCR-registered client doesn't explicitly specify scopes. Rationale: the expected install pattern is "AI assistant that works on the user's behalf" (drafting PRDs, filing work items, sharing diagrams), not "AI assistant that only researches." A Reviewer default would force every user through a re-consent loop on first useful action — exactly the friction that trains people to grant Admin preemptively on the next install. Author draws the right qualitative line ("act as me" vs. "administer the tenant").

Strict nesting means tenant admins configuring role limits pick a single "maximum bundle" rather than a set of toggles. The wire format is raw scopes; bundles are a presentation/admin-mental-model layer.

A custom bundle composition (e.g., Author minus `share`) renders as **"Custom — based on Author"**, never silently as "Author." Otherwise the bundle name lies about the grant.

Bundle definitions are **locked at grant time.** When a new scope is added later (e.g., a future `yourapp:export`), existing `Author` grants keep their original scope set; new consent flows show `Author@v2` with the added scope highlighted as new. Matches OAuth's standard "re-consent on widening" behavior. Avoids both silent authority widening and disruptive forced re-consent for harmless additions.

#### 16.3.3 Mapping the vocabulary onto MCP primitives

| MCP capability | Scope mapping | Notes |
|---|---|---|
| **Tools** | Per-tool `requiredScope` annotation drawn from the 6 atoms. `thinker.get_session` → `read`; `thinker.tag_session` → `curate`; `thinker.create_session` → `write`; `thinker.add_comment` → `comment`; `thinker.share_session` → `share`; `tenant_admin.set_role` → `admin`. | Tool schemas generated from existing API contracts; `requiredScope` added at schema-generation time. |
| **Resources** (URI-addressable content) | All gated by `yourapp:read`. | Resources are read-only by MCP spec. No per-resource-type scope split in v1. |
| **Prompts** (parameterized templates) | Inherited from the tools the prompt invokes. No dedicated scope. | A prompt is a guided tool invocation; the tools it calls are themselves scope-gated. |
| **Sampling** (server-initiated LLM completion) | Future. Will add `yourapp:mcp:sampling` when MCP sampling ships. | Sampling is the one MCP capability that introduces a consent question RBAC cannot express ("this server can spend your AI tokens on your behalf") — so it gets its own protocol-axis scope when it lands. |
| **Roots** | No scope. | Client-side anchors; no server-side authority surface. |

#### 16.3.4 RBAC dovetail

Effective authority at any MCP call site is:

```
RBAC.allows(user, resource, action)  AND  token.scopes.includes(action)
```

Scopes are a **cap**, never a grant. RBAC is the authoritative gate. A user who grants Author to Claude Code but whose RBAC role is `viewer` on a particular resource cannot write that resource through Claude Code — RBAC denies. A user who grants Viewer to Claude Code but whose RBAC role is `editor` everywhere cannot write anything through Claude Code — scope caps.

This dovetail means OAuth scopes target what RBAC can't catch (tenant-wide admin abuse, agent-initiated authority over otherwise-permitted actions) rather than duplicating what RBAC already gates.

#### 16.3.5 Design rule for adding new scopes

> A scope is the unit of consent. Add a new scope only if a meaningful consent decision exists — i.e., if a user might reasonably grant one capability but not the other. If splitting two capabilities into separate scopes would never produce a meaningful consent decision (no one would grant one without the other), they should share a scope.

This rule gates future scope additions. Applied to the 6-atom vocabulary, every adjacent pair (`read` vs `comment`, `comment` vs `curate`, `curate` vs `write`, `write` vs `share`, `share` vs `admin`) passes the test: each split corresponds to real use cases where one is granted without the other. Future additions must pass the same test.

#### 16.3.6 Realization in Keycloak

Each of the 6 atoms becomes a Keycloak **Client Scope**:

| Client Scope Name | Default? | Consent screen text (placeholder — final copy in §16.11) |
|---|---|---|
| `yourapp:read` | Yes (Author bundle) | "View your yourapp.com content" |
| `yourapp:comment` | Yes (Author bundle) | "Comment on yourapp.com content" |
| `yourapp:curate` | Yes (Author bundle) | "Tag, organize, and link your yourapp.com content" |
| `yourapp:write` | Yes (Author bundle) | "Create, edit, and delete yourapp.com content" |
| `yourapp:share` | Yes (Author bundle) | "Share yourapp.com content with others" |
| `yourapp:admin` | **No** (must be explicitly requested) | "Administer the entire tenant — users, roles, settings" |

All 6 are configured with `Display On Consent Screen: On`, `Include In Token Scope: On`. The first 5 are assigned as **default scopes** to clients registered through `mcp-dcr-policy` (§16.4); `yourapp:admin` is an **optional** scope that must be explicitly requested. The user's actual choice in the consent wizard (§16.7) overrides the requested scope set via the SPI's session-note → protocol-mapper mechanism (§16.8).

### 16.4 DCR Access Model — Anonymous Registration With Strict Policies

DCR is enabled in **anonymous** mode (any client can register without proving identity first), constrained by **two complementary Keycloak configuration systems** working together. This is the standard MCP-spec posture: developer-friendly enough that anyone can wire up their own MCP client without manual onboarding, but defended against trivial attacks.

There is **no static `yourapp-{env}-mcp-server` OIDC client.** Every MCP client install gets its own auto-generated `client_id` via DCR. Claude Code on your laptop is one client; Claude Code on a colleague's laptop is a separate one. The yourapp.com MCP server itself is a *resource server*, identified by the audience string `yourapp-mcp-api` — not a Keycloak client. The MCP server validates `aud == "yourapp-mcp-api"` on every incoming token; this audience is set on DCR'd tokens via the default Client Scope `mcp-default` (§16.6).

#### The two configuration systems

Keycloak 26.x splits DCR-time hardening across two related-but-distinct mechanisms; both must be configured for full coverage:

1. **Client Registration Policies (CRP)** — the legacy system at *Clients → Client Registration → Anonymous Access Policies*. Runs at registration time; controls *what kind of client* can be created (scope whitelist, mapper whitelist, consent forcing, host trust, count limit).
2. **Client Policies** — the newer profile-based system at *Realm settings → Client policies*. Enforces *how the client must behave* at request time (PKCE, redirect URI security, response types, session security). Profiles bundle executors; policies bundle conditions that activate profiles. This is where OAuth 2.1 / FAPI-style hardening lives.

A few requirements aren't enforceable via either system out of the box and need workarounds (documented below).

#### System 1: Client Registration Policy entries (anonymous)

Configure these under *Clients → Client Registration → Anonymous Access Policies → Create*:

| Policy provider | Configuration | Why |
|---|---|---|
| `allowed-client-scopes` | Whitelist: `openid`, `offline_access`, `mcp-default`, `yourapp:read`, `yourapp:comment`, `yourapp:curate`, `yourapp:write`, `yourapp:share`, `yourapp:admin` | Prevents registration with privileged scopes like `realm-admin` or other clients' custom scopes |
| `allowed-protocol-mapper-types` | Whitelist: `oidc-audience-mapper`, `oidc-usersessionmodel-note-mapper`, `yourapp-mcp-scope-override` (your SPI's mapper), `oidc-sub-mapper`, `oidc-full-name-mapper`, `oidc-usermodel-attribute-mapper`, `oidc-usermodel-property-mapper`. Or skip this policy for v1 — the security-critical mappers (audience, tenant, scope override) are attached to the `mcp-default` Client Scope, not the client, so DCR'd clients can't override them. This policy only restricts what *additional* mappers a DCR'd client may attach to itself. | Prevents a DCR'd client from attaching mappers that forge claims like `sub`, `email`, `tenant`. |
| `consent-required` | (no configuration — just add the entry) | Forces `consentRequired=true` on every DCR'd client. Belt-and-suspenders with the Client Policy version below. |
| `trusted-hosts` | Permissive initially (`*` or wide range); tighten later with Cloudflare WAF rate limiting in front | Limits which IPs can hit the DCR endpoint |
| `max-clients` (`client-registration-max-clients`) | Sane upper bound, e.g., 10000 | Prevents one bad actor from creating millions of clients to exhaust storage |

Note: there are no PKCE, grant-type, redirect-URI, or auth-method entries in this system. Those live in Client Policies (System 2).

#### System 2: Client Policy profile + policy

**Create one profile** at *Realm settings → Client policies → Profiles → Create*, named `mcp-hardening`, with these executors:

| Executor | Configuration | Purpose |
|---|---|---|
| `pkce-enforcer` | Code Challenge Method: `S256` only | Enforces PKCE on all matched clients |
| `secure-redirect-uri-enforcer` | Mode: HTTPS only (with localhost exception for dev realm if needed) | Production: rejects HTTP redirect URIs; rejects wildcards |
| `secure-response-type` | Default config | Forbids implicit response types (`token`, `id_token`) — only `code` permitted |
| `consent-required` | Default config | Belt-and-suspenders with CRP `consent-required` |
| `secure-session` | Default config | Enforces secure cookies and session binding |
| `full-scope-disabled` | Default config | Prevents clients from receiving wider scope than their explicit configuration allows |

**Create one policy** at *Realm settings → Client policies → Policies → Create*, named `mcp-anonymous-dcr`, with:
- **Condition:** `client-updater-context` with **Update Client Source = `ByAnonymous`** (matches only clients created via anonymous DCR — exactly the MCP clients).
- **Active Profile:** `mcp-hardening`

Other static clients in the realm (`yourapp-{env}-web`, `yourapp-{env}-admin-api`) are NOT matched by this condition (they're created by authenticated admins, matched by `ByAuthenticatedUser`) and continue to operate under their own configuration.

> **Note on executor names:** the exact executor IDs in Keycloak 26.6.0's "Add executor" dropdown should be verified against the admin console. The executors documented above are described by their *behavior*; the actual UI names may differ slightly (e.g., redirect-URI hardening may be exposed as `secure-redirect-uri`, `secure-client-uris`, or similar — pick the one whose description matches HTTPS enforcement). The PRD will be updated as the actual names are confirmed.

#### Things that need workarounds (not enforceable as simple policies)

| Requirement | Workaround |
|---|---|
| **Default Client Scopes** (assign `mcp-default` + Author bundle automatically) | Configure as **realm-default Client Scopes** for any new client (Realm settings → Client scopes → set `mcp-default`, `yourapp:read`, `yourapp:comment`, `yourapp:curate`, `yourapp:write`, `yourapp:share` to "Default"). `yourapp:admin` stays "Optional". This applies to all newly-created clients including DCR'd ones; static clients can have their assignments overridden manually. |
| **Auth flow override** to `browser-mcp-tenant-pick` | **Settled: bound atomically at registration by the `McpClientRegistrationPolicy` CRP** (`KEYCLOAK_MCP_SPI_DESIGN.md` §5.8). The CRP's `afterRegister` sets `authenticationFlowBindingOverrides.browser` on each DCR'd client in-transaction, so the first authorization already routes through the MCP flow. The realm default browser flow **stays `browser-federated-only`** — never bound realm-wide (a malformed MCP flow bound realm-wide takes down all logins). Earlier options considered — (a) realm-wide binding, rejected for blast radius; (b) app binding at `/mcp/consent` first-use, rejected because it's too late for the first authorization's MCP detection (circular dependency: reaching `/mcp/consent` requires the flow already bound). |
| **Allowed grant types** (reject `password`, `client_credentials`, `implicit`) | (1) Disable the Direct Grant flow at the realm level (Authentication → Flows → Direct Grant Flow → unbind or delete). (2) `implicit` is gated by `secure-response-type` (above). (3) `client_credentials` requires `serviceAccountsEnabled=true`, which DCR'd public clients don't get by default — the `consent-required` and `secure-session` executors prevent its meaningful use. |
| **Token Endpoint Auth Method** (`none` for public clients, `client_secret_basic` for confidential) | Both are permitted by default; DCR'd clients pick what they need. No restriction necessary. |

**Tightening lever:** if abuse becomes a problem, the model can be flipped to authenticated DCR — clients must present an initial access token issued by yourapp.com's UI on behalf of an authenticated user. Admin-console toggle, no schema change. Anonymous mode is the right starting posture for MCP ecosystem compatibility.

### 16.5 OAuth 2.1 Hardening

OAuth 2.1 is OAuth 2.0 with security best practices made mandatory. The realm-level settings:

- **PKCE required, S256 only** — already enforced for static `yourapp-{env}-web` client per §8.2; DCR policy (§16.4) enforces the same for dynamically-registered clients.
- **Refresh token rotation** — Realm settings → Tokens → **Revoke Refresh Token: On**. Each refresh token use issues a new refresh token and invalidates the old one. Standard OAuth 2.1 requirement.
- **No implicit flow, no password grant** — disabled at the realm level and prohibited via DCR policy.
- **Authorization Code grant only for interactive clients** — DCR policy restricts this.
- **Exact redirect URI matching** — Keycloak default; no wildcards permitted for dynamically-registered clients.
- **No bearer tokens in URLs** — Keycloak's default; access tokens are returned only via POST body to the token endpoint.

Realm settings to verify or set:

1. Realm settings → Tokens → Revoke Refresh Token: **On**
2. Realm settings → Tokens → Refresh Token Max Reuse: **0**
3. Realm settings → Login → Require SSL: **All requests** (production realm)

### 16.6 Resource Indicators & Audience Binding

Per RFC 8707, tokens issued for MCP clients carry an `aud` claim matching the MCP resource server identifier. The audience for yourapp.com's MCP server is the constant **`yourapp-mcp-api`** (not a per-environment URL — the value identifies the *logical resource server*, and per-environment isolation is achieved through realm separation: `yourapp-prod` realm tokens have `iss=https://auth.yourapp.com/realms/yourapp-prod`, and the MCP server validates both `iss` and `aud`).

The audience is set on DCR'd tokens via a built-in Audience protocol mapper attached to the `mcp-default` Client Scope. Because `mcp-default` is assigned as a default scope by `mcp-dcr-policy` (§16.4), every DCR-registered client inherits the audience without per-client configuration.

```
mcp-default Client Scope
├── Audience mapper
│   ├── Name: mcp-api-audience
│   ├── Included Custom Audience: yourapp-mcp-api
│   ├── Add to access token: On
│   └── Add to ID token: Off
└── (No other mappers — this scope's sole job is audience binding)
```

MCP clients may include `resource=https://prod.yourapp.com/mcp` in their authorization and token requests per RFC 8707. Keycloak validates the parameter against the DCR policy's allowed-resource list (or against the client's configured resources) and stamps it as additional context in audit logs. The token's `aud` claim, however, remains `yourapp-mcp-api` regardless — that's the canonical resource server identifier.

yourapp.com's MCP server validates on every incoming token:

- `iss == "https://auth.yourapp.com/realms/yourapp-{env}"` (matches the deployment environment)
- `aud` contains `"yourapp-mcp-api"` (or the value is the string `"yourapp-mcp-api"` if `aud` is a scalar)
- `exp` is in the future
- Token signature verified against Keycloak's JWKS at `iss + "/protocol/openid-connect/certs"`

Tokens with any other `aud` are rejected. This is what prevents a token issued for the web client (`aud = yourapp-prod-web`) from being replayed against the MCP server, and vice versa.

### 16.7 Consent Flow — Path (iii) Architecture

The consent UX for DCR-registered MCP clients is **hosted by YourApp web**, not by Keycloak's stock consent screen. Keycloak remains the OAuth authorization server (from the MCP client's perspective, nothing changes about who issues tokens), but the tenant picker and the bundle/consent screen are regular YourApp web pages, served from `prod.yourapp.com/mcp/consent`. A small custom Keycloak Authenticator SPI (§16.8) orchestrates the cross-system handoff via HMAC-signed JWTs.

#### 16.7.1 Why path (iii) and not the alternatives

Three implementation paths were considered:

- **(i) Keycloakify-themed picker** — render the picker inside Keycloak via a custom theme. **Rejected**: the consent surface is iteration-heavy (bundle UX, RBAC mapping grid, Connected Agents extension), and Keycloakify iteration requires JAR rebuild + Docker rebuild + Keycloak restart rather than YourApp web's normal deploy cadence. Also fragments the design system across two codebases.
- **(ii) YourApp-hosted OAuth server** — yourapp.com implements its own OAuth 2.1 + DCR server in .NET; Keycloak demoted to upstream IdP. **Rejected**: makes yourapp.com a token issuer with its own JWKS, refresh rotation, PKCE, DCR per RFC 7591, MCP-spec error format — exactly the security-critical code that mature SaaS providers use IdP brokers to avoid building. Fragments the identity surface (two issuers, two key rotations).
- **(iii) Keycloak owns OAuth; YourApp web hosts picker + consent.** **Locked.** Keeps Keycloak as the single token issuer, puts the iteration-heavy UX where the design system lives, requires only a small (~150–250 line) Authenticator SPI to bridge the two systems.

Path (i) remains a clean fallback design if (iii)'s cross-redirect flow ever has to be abandoned (e.g., if some enterprise SSO setups break the browser redirect chain in ways (i) wouldn't). Accepted risk for v1.

#### 16.7.2 End-to-end flow

```
1. MCP client (Claude Code) discovers yourapp.com MCP server via
   https://prod.yourapp.com/.well-known/oauth-protected-resource (yourapp.com app side).

2. Client → OAuth /authorize at Keycloak (auth.yourapp.com/realms/yourapp-prod/...).

3. Keycloak runs browser-mcp-tenant-pick flow:
   a. Standard browser-federated-only steps (federated IdP, post-broker login).
   b. Custom Authenticator SPI step (§16.8.2) at end of flow:
      - Reads user's `sub` from the authenticator session
      - HMAC-signs a "picker-request" JWT containing:
          { yourapp_sub, mcp_client_id, mcp_requested_scopes, redirect_state,
            nonce, jti, exp(now+5min) }
      - 302s browser to https://prod.yourapp.com/mcp/consent?token=<picker-request-token>
      - Marks the SPI step as "awaiting external completion"

4. Browser lands on https://prod.yourapp.com/mcp/consent. YourApp web's standard
   auth middleware runs on this route:
   a. No YourApp web session cookie → middleware initiates silent OIDC sign-in
      against yourapp-prod-web client with `prompt=none` (picker-request token
      preserved through the OIDC state parameter).
   b. Because the user just authenticated through the same Keycloak SSO session
      (step 3a), Keycloak immediately returns an authorization code without any
      user interaction (~100ms invisible round-trip).
   c. YourApp web exchanges code for token, sets YourApp web session cookie,
      redirects to /mcp/consent?token=<picker-request-token>.

5. /mcp/consent renders with full YourApp app shell (top bar, user menu, workspace
   switcher visible). Validates picker-request token (HMAC, expiry, nonce
   uniqueness against a recent-jti cache).

6. YourApp web runs the 3-step wizard (§16.7.3):
   tenant confirmation → bundle selection → review & authorize.

7. On [Authorize] in Step 3:
   a. YourApp backend re-validates picker-request token.
   b. Validates user's membership in the chosen tenant (RBAC).
   c. HMAC-signs a "picker-result" JWT containing:
        { picker_request_jti, chosen_tenant_id, granted_scopes[],
          user_sub_echo, nonce, jti, exp(now+1min) }
   d. 302s browser back to Keycloak's Realm Resource Provider callback URL:
        https://auth.yourapp.com/realms/yourapp-prod/mcp-picker-callback
          ?picker_result=<picker-result-token>

8. Keycloak's Realm Resource Provider (§16.8.3) receives the callback:
   a. Validates HMAC, expiry, nonce, jti-matches-request, user-sub-matches-session.
   b. Writes `yourapp_tenant_id` and `yourapp_scopes` to the User Session Notes.
   c. Marks the SPI Authenticator step as complete.
   d. Resumes the OAuth flow from where it paused.

9. Keycloak finishes the auth flow normally:
   a. Protocol mappers (§16.8.4) expose session notes as token claims:
      - `tenant` claim from `yourapp_tenant_id`
      - `scope` claim derived from `yourapp_scopes` (the user's actual choice
        overrides whatever the client requested)
      - `aud` claim of `yourapp-mcp-api` from the mcp-default scope
   b. Mints OAuth access + refresh tokens.
   c. 302s to the MCP client's redirect URI with the authorization code.

10. MCP client exchanges code at Keycloak's /token endpoint, receives tokens.

11. Subsequent MCP requests to https://prod.yourapp.com/mcp carry the token;
    the yourapp.com MCP server validates against Keycloak JWKS, reads `tenant`,
    enforces `scope`, performs RBAC checks (RBAC ∧ scope per §16.3.4).
```

The full round-trip in step 4 (silent prompt=none OIDC) is invisible to the user — they see one page transition from Keycloak's IdP back to YourApp's consent wizard, not two. The technical machinery exists to give `/mcp/consent` a regular YourApp web session cookie rather than building a bespoke auth path for that route alone.

#### 16.7.3 The 3-step consent wizard

Hosted at `prod.yourapp.com/mcp/consent`. Renders inside YourApp's standard authenticated app shell — top bar, workspace switcher, user menu, app launcher visible. Built on the existing CDN Stepper component. Three steps; cannot skip forward; back navigation always available.

**Step 1 — Who & Where (client identity + tenant confirmation)**

Two cards:
- **Client identity card** (top, prominent): MCP client display name (from DCR metadata), client URI/domain, redirect URI domain prominently shown, "Self-registered" badge with hover surface explaining what self-registration means.
- **Tenant card**: tenant logo, name, user's role in this tenant, last activity timestamp, member count. **Always shown for explicit confirmation**, even for single-tenant users. Multi-tenant users see a radio list.

Explicit confirmation over auto-skip is deliberate — avoids the "I didn't know I did that" failure mode. Empty-membership users hit a halt state (§16.7.4) instead of seeing a tenant picker.

Actions: [Continue] / [Cancel — Don't Connect].

**Step 2 — What (bundle selection)**

Heading: *"What should {client name} be able to do for you in {tenant name}?"*

Five bundle cards stacked vertically: Viewer / Reviewer / Curator / Author / Admin. Each card shows: bundle name + one-line description, 2–3 example actions ("Can read your work items," "Can comment on diagrams," "Cannot administer your tenant"), RBAC mirror in small text ("Like the Editor role").

**Default selection: Author** (per §16.3.2).

**Expand affordance:** "Show advanced (individual scopes)" reveals the 6 raw atoms as checkboxes, with the active selection labelled "this is currently the Author bundle." Editing any checkbox flips the bundle label to "Custom — based on Author" (or whichever bundle was last selected).

**Admin elevation banner:** if the client's DCR registration explicitly requested `yourapp:admin`, a prominent warning banner appears above the cards before the user gets to select: *"This app is requesting tenant administration access. Choose carefully — this allows changes to user roles, tenant settings, and audit configuration."*

Actions: [Continue] / [Back].

**Step 3 — Review & Authorize**

Heading: *"Confirm: {client name} will be able to..."*

**Affirmative list** — what they CAN do under the chosen bundle. Generated from the Bundle ↔ RBAC mapping registry. Examples for Author:
- ✓ Read any resource you have access to
- ✓ Comment on resources you can comment on
- ✓ Create, edit, and delete resources you have edit access to
- ✓ Share resources you own with other users in this tenant
- ✓ Create cross-app links between resources

**Negative list** — what they CANNOT do. Generated from the same registry. Crucial for trust; turns "I clicked through a consent screen" into "I knowingly granted Author, not Admin." Examples for Author:
- ✗ Administer this tenant (cannot manage users or roles)
- ✗ Change tenant-wide settings
- ✗ Access audit logs
- ✗ Act in any tenant other than {tenant name}

**Summary line:** *"Connecting {client name} to {tenant name} · Author bundle · until you disconnect."*

Actions: [Authorize] (visually extra-prominent — larger size, distinct accent — when the chosen bundle is Admin) / [Back] (preserves selection) / [Cancel — Don't Connect].

#### 16.7.4 Empty-membership state

When `/mcp/consent` validates the picker-request token and discovers the user has no YourApp Organization membership, the wizard halts at Step 1 with no [Continue] action. Two branches based on context detected by the YourApp backend:

- **Case A — user's email domain matches a connected tenant** (Microsoft Entra / Google Workspace / SAML directory binding exists for `acme.corp`) **but no membership granted yet**: "Your domain ({acme.corp}) is connected to yourapp.com, but you haven't been added as a member yet. Please ask your administrator to invite you, then return here to connect {client name}."
- **Case B — no domain match, no pending invite**: "You need a yourapp.com workspace to use {client name} with yourapp.com. [Create a workspace] or [Cancel]." First CTA opens normal sign-up in a new tab; user returns to the consent flow after.

In both cases, no picker-result token is ever emitted, the SPI Authenticator step times out (5 min, matching picker-request token expiry), and the OAuth flow fails with `access_denied`. The MCP client sees a normal OAuth denial.

#### 16.7.5 Connected Agents (post-grant management)

Post-consent, the granted client appears in YourApp web's user menu → **Connected Agents** page (entry point locked per design notes §2.6). Per-row:

- Client name + logo, tenant scope ("in {tenant name}"), bundle granted, last activity, [Disconnect].
- Disconnect → revokes the user's grant via Keycloak's Admin REST API (session-level revocation per §8.7) and emits an `AgentConnectionRevoked` activity for audit.

Per-tenant: a tenant-admin Connected Agents view audits all connected agents across the tenant and supports admin-initiated disconnection for offboarding scenarios.

#### 16.7.6 Trust signals (anti-phishing)

The consent wizard depends on the user being able to verify they're on a legitimate YourApp surface and that the client requesting access is the one they think it is.

- **Surface-level:** Consent page renders inside YourApp's authenticated app shell with top bar, workspace switcher, user menu visible. *"I am signed in to yourapp.com as me, viewing a consent page within yourapp.com"* must be verifiable at a glance, before the user reads the consent text. URL is on `prod.yourapp.com`, not a separate auth-only domain.
- **Client-identity:** Client name in a clearly bounded card, separated from the consent prompt. "Self-registered" badge for DCR clients until/unless a publisher-verification process is added (future hardening track). Redirect URI domain displayed prominently — a redirect URI on a suspicious domain is the strongest signal of a phishing client.
- **Cross-system handoff:** HMAC-signed tokens (§16.8.5) prevent tampering with chosen tenant or granted scopes. The `user_sub` cross-check at the picker-result side prevents a different signed-in user from completing consent for the original authenticated user (session-fixation defense in depth).

Future hardening: tenant admin policy to require client verification for any DCR client requesting Author or higher (Reviewer/Viewer granted to unverified DCR clients; Author+ requires the verification badge).

### 16.8 Custom Authenticator SPI Architecture

This is the new in-scope Keycloak extension that implements the path (iii) handoff. It graduates from the §15 Future Work bucket ("Custom Keycloak event listener SPI") — but note that this is a **different SPI** from the parked event-listener SPI; see §16.8.7 for the disambiguation.

> **Scope of this sub-section.** §16.8 specifies the *architecture and contract*: what the SPI must do, what JWT claims flow in each direction, what protocol mappers it relies on. It is **not** a complete implementation specification. The Java/Kotlin code structure, package layout, Keycloak SDK version pinning, error handling specifics, logging conventions, testing strategy, and CI build pipeline should be authored in a separate companion document `KEYCLOAK_MCP_SPI_DESIGN.md` when the implementation track begins (per §16.1.5 Phase 0). The companion doc inherits the contract from this section.

#### 16.8.1 The `browser-mcp-tenant-pick` authentication flow

A new realm-level browser flow, structurally a duplicate of `browser-federated-only` (§11.5) with the SPI Authenticator appended at the end:

```
browser-mcp-tenant-pick
├── Cookie                                [Alternative]
├── Kerberos                              [Disabled]
├── Identity Provider Redirector          [Alternative]
├── Browser - Conditional Organization    [Disabled]
├── Forms                                 [Alternative, sub-flow]
│   ├── Username Password Form            [Required]
│   └── Browser - Conditional OTP / 2FA   [Disabled]
└── YourApp MCP Tenant Picker              [Required]   ← new SPI Authenticator
```

The first four sections behave identically to `browser-federated-only`. The new final step is the SPI Authenticator. Web users (authenticating against `yourapp-{env}-web`) continue to use `browser-federated-only` and never run the SPI Authenticator. MCP clients (DCR-registered) are auto-bound to `browser-mcp-tenant-pick` by `mcp-dcr-policy` (§16.4).

This separation is deliberate: the web auth path stays zero-coupled to MCP, and future MCP-specific flow changes (sampling consent, elevation flows, step-up auth for Admin) extend `browser-mcp-tenant-pick` without touching the web flow.

#### 16.8.2 The SPI Authenticator class

Java/Kotlin implementation of `org.keycloak.authentication.Authenticator`. Responsibilities:

- Read `KeycloakSession.getContext().getAuthenticationSession().getAuthenticatedUser().getId()` to get the user's `sub`.
- Read the requesting client's `client_id`, requested scopes, and the OAuth `state` parameter.
- Construct the picker-request token (§16.8.5) and HMAC-sign it.
- Issue HTTP 302 to `https://{yourapp-web-host}/mcp/consent?token=<picker-request-token>`.
- Mark the auth step as `CHALLENGE` (awaiting external completion); Keycloak suspends the flow.

The Authenticator is a single class, ~80 lines. Its `requiresUser()` returns `true` (must run after federated auth completes); `configuredFor(...)` returns `true` for all clients bound to this flow.

#### 16.8.3 The Realm Resource Provider (callback handler)

Java/Kotlin implementation of `org.keycloak.services.resource.RealmResourceProvider`. Mounts a new endpoint at `https://auth.yourapp.com/realms/{realm}/mcp-picker-callback`. Responsibilities:

- Receive the picker-result token via query parameter.
- Validate: HMAC signature (using the same shared secret as the Authenticator); expiry; nonce uniqueness; `jti` matches the picker-request token's `jti`; `user_sub_echo` matches the current authentication session's user.
- On valid: write `yourapp_tenant_id` and `yourapp_scopes` to `AuthenticationSessionModel.setUserSessionNote(...)`. Resume the Authenticator's pending flow by marking the step `SUCCESS`.
- On invalid: log structured audit event, return HTTP 400 with `error=invalid_handoff`. The user is shown a generic error page; the OAuth flow ultimately fails with `access_denied`.

This is another single class, ~100 lines.

#### 16.8.4 Protocol mappers

Three mappers attached to the `mcp-default` Client Scope (so they apply automatically to every DCR-registered MCP client):

| Mapper | Type | Source | Target Token Claim | Notes |
|---|---|---|---|---|
| MCP Tenant | User Session Note | `yourapp_tenant_id` (set by SPI in §16.8.3) | `tenant` | The chosen tenant's UUID (transitional; aligns with the directory-binding ID per §15 once that lands) |
| MCP Granted Scopes | Custom (replaces standard scope mapper) | `yourapp_scopes` (set by SPI) | `scope` | **Overrides** the requested-scope-set; the user's actual consent choice wins |
| MCP Audience | Audience | (static) | `aud = yourapp-mcp-api` | Per §16.6 |

The MCP Granted Scopes mapper is the non-trivial one: Keycloak's default scope-claim behavior is to emit the intersection of (client's allowed scopes) ∩ (requested scopes) ∩ (granted scopes). We need it to emit *exactly* the session note's value, ignoring whatever was requested. The SPI ships a custom protocol mapper (`McpScopeOverrideMapper`, see §16.8.4 and `KEYCLOAK_MCP_SPI_DESIGN.md` §5.5) that handles this; configuration is just selecting "yourapp mcp scope override" as the mapper type when adding it to the `mcp-default` Client Scope. A Script Mapper alternative (Option B) exists for the case where the SPI is not deployed, but it's a fallback only.

#### 16.8.5 Handoff token construction & key management

Both tokens (picker-request and picker-result) are short-lived JWTs signed with a symmetric key (HS256) held by both the SPI (in Keycloak) and the YourApp backend.

**Picker-request token claims** (issued by SPI Authenticator → consumed by YourApp web `/mcp/consent`):
```
{
  "iss": "keycloak-mcp-spi",
  "aud": "yourapp-web-mcp-consent",
  "sub": "<user's Keycloak sub>",
  "yourapp_sub": "<duplicate of sub for clarity>",
  "mcp_client_id": "<DCR-registered client_id>",
  "mcp_requested_scopes": ["yourapp:read", "yourapp:write", ...],
  "oauth_state": "<the OAuth state parameter from the originating /authorize call>",
  "nonce": "<128-bit random>",
  "jti": "<UUID>",
  "iat": <now>,
  "exp": <now + 5 minutes>
}
```

**Picker-result token claims** (issued by YourApp web → consumed by SPI Realm Resource Provider):
```
{
  "iss": "yourapp-web-mcp-consent",
  "aud": "keycloak-mcp-spi",
  "picker_request_jti": "<jti from the request token, for correlation>",
  "user_sub_echo": "<must match the picker-request's sub>",
  "chosen_tenant_id": "<UUID of the tenant the user picked>",
  "granted_scopes": ["yourapp:read", "yourapp:comment", "yourapp:curate",
                     "yourapp:write", "yourapp:share"],
  "oauth_state": "<echoed back to be re-forwarded to the MCP client>",
  "nonce": "<128-bit random>",
  "jti": "<UUID>",
  "iat": <now>,
  "exp": <now + 1 minute>
}
```

**Why HMAC and not asymmetric:** both ends are first-party services owned by yourapp.com; symmetric is simpler, faster, and the operational story (one secret, rotated together) is cleaner than managing a key pair across systems.

**Replay protection:** the SPI Realm Resource Provider records consumed `jti`s for the picker-result side (1-minute retention — matches token TTL). The YourApp backend records consumed `jti`s for the picker-request side (5-minute retention). Replay attempts fail validation.

**Tampering protection:** if the user (or a malicious browser extension) modifies the chosen tenant or scopes in the picker-result token, the HMAC fails. If the `user_sub_echo` is mismatched against the session user, the SPI rejects.

**State-vs-claims separation:** the picker-request token carries the OAuth `state` value as one of its claims, so YourApp web never has to read `state` from the URL bar (avoids accidentally treating it as user-visible state). YourApp returns `state` to Keycloak inside the picker-result token; Keycloak then forwards it to the MCP client in the normal OAuth `state` callback parameter.

**Key rotation:** the shared HMAC key (`yourapp-mcp-handoff-hmac-key-{env}` in GCP Secret Manager) is rotated quarterly. To avoid downtime during rotation, both SPI and YourApp backend support a two-key overlap pattern: each side accepts tokens signed by either the current or the previous key, while only signing with the current one. Cutover sequence:
1. Generate new key version, add to Secret Manager (versions older than 2 are deleted after cutover).
2. Deploy SPI + YourApp backend with two-key support reading both versions.
3. Update both to sign with the new key while still accepting the previous.
4. After all in-flight tokens have expired (5 min for picker-request, 1 min for picker-result, so 10 min safety margin), the previous key can be retired.

#### 16.8.6 JAR build & deployment

The SPI is built as a single JAR (`yourapp-keycloak-mcp-spi-{version}.jar`) and placed in `/opt/keycloak/providers/` of the custom Keycloak Docker image (see Dockerfile comment block). The `kc.sh build` step picks up new providers and incorporates them into the optimized startup.

When a new SPI version is built:
1. CI builds and tests the JAR.
2. Docker image build includes the JAR via `COPY` before the `kc.sh build` step.
3. Cloud Run revision is deployed; new revision starts with the SPI loaded.
4. Manual realm config (one-time per realm): bind the `YourApp MCP Tenant Picker` Authenticator into the `browser-mcp-tenant-pick` flow (admin console step in §16.11).

Versioning: the JAR uses semver (`yourapp-keycloak-mcp-spi-1.0.0.jar`). Backwards compatibility is required between the SPI and YourApp web's consent flow — a SPI version mismatch with the YourApp web side would silently break handoff. The two are deployed together, tracked by the same `IMAGE_VERSION` label in the Dockerfile.

#### 16.8.7 Two SPIs, do not conflate

yourapp.com's Keycloak roadmap involves two distinct SPIs. They share infrastructure (both deploy as JARs in the custom image; both built and versioned together) but solve different problems and ship independently:

| SPI | Status | Purpose | Required by |
|---|---|---|---|
| **Authenticator + Realm Resource Provider** (this §16.8) | **In scope for v1 MCP launch** | Post-federation 302 to YourApp web for tenant + consent; HMAC handoff token validation; write session notes for protocol mappers | MCP v1 |
| **Event Listener** | Parked (§15 Future Work) | Bridge Keycloak events (login success/failure, IdP federation, user CRUD, session termination, admin API ops) into the platform event bus | Audit trail / event-bus track; not MCP v1 |

§15 Future Work still lists the event-listener SPI as parked. When that work eventually lands, both SPIs coexist in the same JAR (or as two JARs in the same providers/ directory — implementation choice).

### 16.9 Client Lifecycle

**Registration Access Tokens.** Each DCR response includes a `registration_access_token` and `registration_client_uri`. The client uses these to update its own registration (rotate secrets, change redirect URIs, deregister) without going through an admin. RATs are bearer tokens — clients must store them as securely as they'd store an OAuth client secret.

**Cleanup of inactive registrations.** Dynamically-registered clients accumulate. A periodic cleanup job (initially manual; eventually scheduled) deletes registrations meeting all of:
- Last token issuance > 90 days ago
- Zero active sessions
- Not marked as `do_not_purge` (an annotation yourapp.com admins can apply)

Until automated, the operator runs the cleanup quarterly via Admin REST API.

**Revocation.** Three mechanisms:
- User-initiated: yourapp.com Connected Agents UI (§16.7.5) → [Disconnect] revokes the user's grant via Keycloak's Admin REST API.
- Admin-initiated: tenant admin's Connected Agents view can disconnect on a user's behalf for security/offboarding scenarios; calls the same Admin REST endpoint.
- Refresh token rotation (§16.5): a leaked refresh token is detected on next use (because the previous token has been invalidated by rotation), at which point yourapp.com can heuristically revoke the entire session.

### 16.10 Threat Model

The DCR endpoint is internet-exposed and anonymously accessible by design. The path (iii) handoff also introduces cross-system trust requirements. Combined threats and defenses:

| Threat | Defense |
|---|---|
| Registration flood (resource exhaustion) | Cloudflare WAF rate limit on `/realms/*/clients-registrations/*`; Keycloak-side `Client Registration Maximum` policy |
| Privilege escalation via scope injection | `Allowed Client Scopes` policy whitelists only `yourapp:*` + `mcp-default` + `openid` + `offline_access` |
| Privilege escalation via protocol mapper injection | `Allowed Protocol Mappers` policy restricts to built-in defaults |
| Token delivery to attacker URI | `Allowed Redirect URIs` policy: HTTPS-only, no wildcards, no `localhost` in prod |
| Phishing via spoofed `client_name` ("Microsoft Account") | Consent screen displays the redirect URI host alongside the client name; user can audit (§16.7.6) |
| Refresh token theft | Refresh token rotation (§16.5) — a stolen RT becomes invalid on next legitimate use |
| Client_id enumeration | Client IDs are opaque UUIDs; no enumeration value |
| Resource indicator bypass | yourapp.com MCP server validates `aud == "yourapp-mcp-api"` strictly on every request |
| Abandoned/forgotten clients | Quarterly cleanup of inactive registrations (§16.9) |
| **Handoff token tampering** (modify chosen tenant or scopes in picker-result) | HMAC signature on picker-result token (§16.8.5); fails validation |
| **Handoff token replay** (re-submit a previously-consumed token) | `jti` tracking in both directions with TTL-bounded retention (§16.8.5) |
| **Session fixation** (different signed-in user completes consent for original) | `user_sub_echo` cross-check in picker-result token against authentication session user |
| **Cross-tenant grant injection** (user fakes membership in a tenant they don't belong to) | YourApp backend validates RBAC membership before issuing picker-result token; SPI can only trust HMAC, but the data being signed is already authoritative-validated |
| **HMAC key compromise** | Quarterly rotation with two-key overlap pattern (§16.8.5); key stored in GCP Secret Manager with audit logging on access |
| **Picker URL phishing** (attacker mimics `/mcp/consent`) | YourApp app shell visible (top bar, user identity) at the consent surface; URL is on `prod.yourapp.com` (canonical app domain); HMAC handoff means token cannot be forged client-side |

Defense in depth: Cloudflare in front, Keycloak policies enforced, yourapp.com MCP server validates `aud`, yourapp.com backend validates RBAC at handoff. No single layer is sufficient on its own.

### 16.11 Realm Configuration

Step-by-step admin console configuration has moved to `KEYCLOAK_SETUP_GUIDE.md` — the operational "how" companion to this PRD. That guide is 26.6.x-specific and explicit about exact UI labels. It covers infrastructure deployment (Cloud Run + Cloud SQL/Neon/Supabase, or Hetzner VM + Docker Compose), realm + IdP foundation, and the full MCP setup sequence.

Sections of the setup guide that implement this PRDs requirements:
- Setup Guide §A or §B → image deployment + infrastructure
- Setup Guide §C → realm + IdP foundation (PRD §6, §8, §11)
- Setup Guide §D → MCP-specific configuration (PRD §16)
- Setup Guide §E → verification checklist (was PRD §16.12)

When PRD intent and setup guide instructions diverge: the PRD is the authority on *what and why*; the setup guide is the authority on *how* for the current Keycloak version. Update both when reality changes.

## 17. Client Taxonomy and Authentication Models (Forward-Looking)

> **Status:** Roadmap / architecture. Only the "regular user (browser)" and "MCP client" rows are implemented today. The rest are documented here so the design assumptions are explicit and the future work is scoped, not so they are built now.

### 17.1 Why this section exists

The auth design as built carries an implicit assumption: **every client is either (a) an MCP client that self-registers via DCR, or (b) the first-party web client.** The SPI short-circuit (§16.8 / SPI design §5.1 step 0) already relaxes this by letting non-MCP interactive clients pass through the MCP-bound browser flow untouched — but the roadmap introduces client types that break the assumption more fundamentally:

- **SDK / API clients** auto-generated from yourapp.com's Swagger surface — both *user-context* (a script or tool acting as a person) and *service-context* (a background integration or sync service acting as itself).
- **Native mobile applications.**
- **A browser plugin.**
- **Agents** — already designed in the Agentics specs, included here for reconciliation.
- **Enterprise SSO** for human users authenticating through a customer's own IdP.

This section catalogs those client types, states how each authenticates, and identifies what must be built. It does not change any current implementation.

### 17.2 Two authentication authorities, one authorization plane

The critical architectural framing: yourapp.com already has **more than one place a request can be authenticated**, and exactly **one place it is authorized**.

**Authentication authorities:**

1. **Keycloak** — issues and (via JWKS) backs validation of OAuth/OIDC tokens. Used by interactive principals (humans in a browser, MCP clients, user-context CLI/SDK) and potentially by OAuth-style machine-to-machine clients (client credentials grant).
2. **yourapp.com app layer** — authenticates two non-Keycloak credential types directly, per the Agentics design:
   - **Native yourapp identity** — the principal signs each canonicalized request with its **private key** (asymmetric keypair). The request gateway looks up the principal's `credential_handle`, confirms it is active via the Key Manager (`KM.status`), and verifies the signature (`KM.verify`). This is the agent "native" path (Agentics §4.4); it is *request signing*, not shared symmetric keys.
   - **Federated identity** — the principal presents an OIDC token from an external issuer (e.g. a cloud provider service account). yourapp.com validates it against per-tenant trust config: issuer, allowed audiences, allowed subject patterns, required claims, standard time-based checks, and replay defenses (Agentics §4.5). This validation happens in the app layer, *not* in Keycloak.

**Authorization plane (single):** regardless of how a request was authenticated, it resolves to a **Principal** (the generalized identity abstraction, Agentics Foundation 1). All RBAC / FGAC / tenancy decisions operate on the Principal in the yourapp.com app layer. Authentication answers "who are you?"; the Principal is the answer; authorization ("what may you do?") is uniform from there.

This is the unifying insight for everything below: **new client types are new ways to prove identity and resolve to a Principal. They do not each need bespoke authorization.** The design work for a new client type is (1) pick its authentication authority and method, (2) ensure it resolves to a Principal with the right tenancy binding.

### 17.3 Client taxonomy

| Client type | Interactive? | Auth method | Credential | Authenticated by | Status |
|---|---|---|---|---|---|
| Regular user (web) | Yes | Browser flow, federated IdP | Session cookie / OIDC tokens | Keycloak | **Built** |
| MCP client | Yes (first connect) | DCR + PKCE + consent wizard | Per-tenant OAuth tokens | Keycloak + yourapp consent | **Built** |
| User-context CLI / SDK / tool | Yes (login step) | Auth Code + PKCE (loopback) or Device Grant | OAuth tokens + refresh | Keycloak | Roadmap (small) |
| Service integration — OAuth M2M | No | Client Credentials grant | Confidential `client_id` + secret/cert | Keycloak | Roadmap (design) |
| Service integration — native key | No | Request signing (asymmetric keypair) | KM `credential_handle` + keypair | yourapp.com app layer (KM) | Roadmap — reuses agent native path |
| Service integration — federated | No | External IdP token | Cloud/enterprise service-account token | yourapp.com app layer | Roadmap — reuses agent federated path |
| Agent (native) | No | Request signing (asymmetric keypair) | KM `credential_handle` + keypair | yourapp.com app layer (KM) | **Designed** (Agentics §4.4) |
| Agent (federated) | No | External IdP token | Issuer-minted token | yourapp.com app layer | **Designed** (Agentics §4.5) |
| Native mobile app | Yes | Auth Code + PKCE via system browser | OAuth tokens + refresh | Keycloak | Roadmap (extends interactive) |
| Browser plugin | Yes | Auth Code + PKCE | OAuth tokens | Keycloak | Roadmap (extends interactive) |
| Enterprise SSO user | Yes | SAML / OIDC brokering to customer IdP | Session / tokens | Keycloak (brokered) | Partial (alias convention exists) |

### 17.4 What each roadmap client type needs

#### User-context CLI / SDK / tool (script acting as a person)

The `gcloud auth login` / `gh auth login` / `aws sso login` pattern. The tool opens the system browser, the user authenticates through the normal federated IdP, and the token returns to a loopback listener (`http://127.0.0.1:<port>/callback`) or via the Device Authorization Grant for headless contexts.

- **Authentication authority:** Keycloak.
- **Is it an MCP client?** No. It talks to the regular yourapp.com API, not the MCP server. It does **not** get `mcp-default`, so the SPI short-circuit passes it through to normal federated login (no consent wizard). This is exactly the case the short-circuit was built for.
- **What must be built:**
  - Enable the **Device Authorization Grant** flow on the relevant client(s) for headless/remote CLI use (Keycloak supports it; it is off by default). Loopback Auth Code + PKCE needs no server-side change — any public client can do it; it is SDK ergonomics (implement the loopback listener, cache tokens, refresh).
  - Decide the **audience** these tokens carry so the regular API validates them (distinct from `yourapp-mcp-api`; see §17.5).
  - SDK token cache + refresh handling.
- **Tenancy:** the user's existing tenant memberships, same as web. If a CLI action needs a tenant chosen (multi-tenant user), that is a CLI UX concern, not a new auth mechanism.

#### Service-context integration (background sync / push / pull, acting as itself)

No user, no browser. A daemon that syncs data in or out. This maps directly onto the **existing Principal + credential machinery** — a service integration is a non-agent service Principal. Three candidate credential models, and the design decision is which to offer (§17.5):

- **(a) OAuth M2M — Keycloak confidential client + Client Credentials grant.** The integration holds a `client_id` + secret (or cert). It requests a token from Keycloak's token endpoint with `grant_type=client_credentials`; yourapp validates the JWT via JWKS. Analogous to **Azure MSAL "app authentication."** Requires deliberate confidential-client provisioning (not anonymous DCR — the Client Policies correctly forbid DCR public clients from meaningful client-credentials use). New work: a provisioning path (admin-created or self-service confidential clients) and secret lifecycle.
- **(b) Native key — reuse the agent KM path.** The integration is issued an asymmetric keypair via the Key Manager and signs each request. Analogous to **AWS SDK "key authentication"** (request signing). New work: extend KM credential issuance to non-agent service Principals and provide a self-service key-issuance UI. Minimal new *mechanism* — the signing/verification path already exists for agents.
- **(c) Federated — reuse the agent federated path.** The integration authenticates with its own cloud/enterprise IdP (e.g. a GCP service account) and presents that token; yourapp validates it against per-tenant trust config. Analogous to **Azure MSAL app auth when the customer uses their own IdP.** New work: expose the per-tenant federated-trust configuration (already designed for agents) to service integrations, and a registration UI.

**Reconciliation note:** (b) and (c) are *already built for agents*. Extending them to service integrations is largely a matter of Principal typing and a provisioning UI, not new authentication machinery. (a) is the genuinely new path and the only one that involves Keycloak. A reasonable v1 could offer just (b) — it reuses the most existing code and gives integration authors the familiar "issue a key, sign requests" ergonomics — and add (a)/(c) as demand appears.

#### Native mobile app

Standard mobile OAuth: Auth Code + PKCE via the system browser component (ASWebAuthenticationSession on iOS, Custom Tabs on Android), with a custom-scheme (`com.yourapp.app://callback`) or app-link redirect.

- **Authentication authority:** Keycloak. From Keycloak's perspective this **is** a browser flow, so the SPI short-circuit applies: MCP-enabled mobile client → MCP flow; regular mobile client → passthrough.
- **What must be built — mostly redirect-URI policy, not flow logic:** custom-scheme and app-link redirects intersect with the `secure-redirect-uri` executor and (if re-added) the Trusted Hosts policy. HTTPS-only enforcement may reject custom-scheme redirects. This is the **same class of decision as loopback redirects for desktop MCP clients** (setup guide F.1) — resolve it deliberately when mobile lands: either register the specific custom schemes / app-link domains, or relax the redirect policy for these clients.
- Token cache in the platform keystore; refresh handling.

#### Browser plugin

A browser extension is a browser-based public client with PKCE.

- **Authentication authority:** Keycloak. MCP-enabled plugin → MCP flow; regular plugin → passthrough (SPI short-circuit).
- **What must be built:** the extension's redirect URL (`chrome-extension://<id>/...` or a hosted redirect page) must satisfy the redirect-URI policy — same policy question as mobile. Otherwise no new mechanism.

#### Enterprise SSO (human users via a customer IdP)

Customers who want their employees to authenticate through their own corporate IdP (Okta, Entra, Ping, etc.).

- **Authentication authority:** Keycloak, brokering to the customer IdP via SAML or OIDC. The IdP-alias naming convention already reserves `saml-<slug>` (§10.8), so the topology anticipates this.
- **What must be built:** per-customer SAML/OIDC IdP registration in the realm; attribute mapping (align claims to the token contract in §8.3); optionally **SCIM** for user provisioning/deprovisioning; handling of IdP-initiated SSO if a customer requires it. This extends the existing federated model rather than replacing it — an enterprise user still resolves to a Principal exactly like a Google-federated user does.

### 17.5 Open design decisions

These need answers before the corresponding client type is built:

1. **Audience taxonomy per surface.** The MCP server validates `aud == yourapp-mcp-api`. The regular API needs its own audience (e.g. `yourapp-api`) so a token minted for one surface is not accepted at the other. Define the full audience set and which client types request which audiences. This is the same "tokens are audience-scoped" discipline the platform already applies.
2. **Service-context credential model(s) to offer** — (a) OAuth M2M, (b) native KM key, (c) federated — or some subset. Recommendation: start with (b) since it reuses the agent path and gives familiar key-issuance ergonomics; add (a)/(c) on demand.
3. **Self-service credential provisioning UX.** For both user-context (no provisioning — they just log in) and service-context (they need a key or client issued). Where in yourapp.com does a developer create a service Principal and obtain its credential? How is it scoped to a tenant? How is it rotated/revoked? This is app-layer product design, informed by the existing KM and agent-provisioning work.
4. **Device Authorization Grant** — enable per-client, and decide the UX for the "enter this code" step.
5. **Redirect-URI policy for non-HTTPS schemes** (loopback, custom scheme, app-link, extension URLs). One coherent policy decision that serves desktop CLI, mobile, and browser-plugin clients rather than three separate ad-hoc fixes. Ties to setup guide F.1 (Trusted Hosts) and the `secure-redirect-uri` executor (setup guide D.6).

### 17.6 What flow binding (setup guide D.8) does and does not cover

To close the loop with the operational decision already made: the browser-flow binding in setup guide D.8 governs **only interactive browser-based login.** It is relevant to: regular web users, MCP clients, user-context CLI (during its browser login step), mobile, and browser plugins. The SPI short-circuit is what lets all the *non-MCP* interactive clients share the MCP-bound realm flow safely.

It is **irrelevant** to non-interactive clients — OAuth M2M (client credentials), native-key service integrations, and agents never traverse a browser flow, so no flow-binding configuration affects them. Their authentication is a token-endpoint call or a signed request, not an `/authorize` redirect.

### 17.7 Dependencies on current work

Nothing in §17 requires immediate work, and nothing blocks the current roadmap (finish realm config, complete the MCP consent sub-app). But three properties of the *current* design must be preserved so the future client types slot in without a refactor. All three are already satisfied — this subsection makes them explicit so they aren't broken inadvertently.

**1. Audience is validated deliberately (already correct — keep it that way).**
The finished Auth0→Keycloak migration already does this right: the web client's dedicated audience mapper (`yourapp-{env}-web-audience`, §8.3) stamps the `aud` claim, and the .NET app validates it (`ValidateAudience = true`, `ValidAudience = <web client id>`, §8.2). That is a real security boundary — a token minted for another surface (e.g. `aud: yourapp-mcp-api`) is rejected by the web API, and vice versa.

*Forward-looking evolution (not a fix — a generalization):* today the web API validates `aud == <web client id>`. That works in a single-interactive-client world. When user-context CLI, mobile, or browser-plugin clients arrive, they are **different Keycloak clients with different client ids**, so their tokens would carry a different `aud` and be rejected by an API that pins the web client's id. The clean evolution is a **shared resource audience** for the regular API — e.g. `yourapp-api` — that every API-calling client requests (via a shared client scope's audience mapper) and that the API validates, exactly parallel to how `yourapp-mcp-api` identifies the MCP resource server regardless of which DCR'd client calls it. This is §17.5 decision #1. Until then, the current per-client-id validation is correct and secure; no change needed now.

*Verification:* smoke Test 11 includes a sub-check that the web client (or its default scopes) carries an `oidc-audience-mapper`, pinning the current-correct producer-side behavior so a future scope refactor can't silently regress it to `aud=account`. The consumer-side check (`ValidateAudience = true` in the app) is app-side and lives in the .NET auth configuration, not the smoke test.

**2. The token claim contract is shared across all Principal types (§8.3).**
Web users, and every future interactive client type (CLI, mobile, enterprise-SSO), flow through the same claims (`idp`, `microsoftTenantId`, `googleHd`) and the same tenant-derivation logic. The discipline: do not add a claim or a tenant-resolution shortcut that only the web client understands. Any interactive client must be able to authenticate and resolve to the correct Principal + tenant using the identical, client-agnostic derivation. This is already the design; the note is "keep it client-agnostic."

**3. Keycloak stays a thin authenticator; the Principal + authorization plane stays in yourapp.com (Invariant 8).**
§17's entire taxonomy depends on Keycloak authenticating OAuth principals while the yourapp.com app layer owns the Principal abstraction, native-key and federated validation, and all RBAC/FGAC/tenancy. If authorization logic (roles, groups, tenant claims minted authoritatively by Keycloak) ever migrated into Keycloak, the taxonomy would fracture — each client type would need bespoke authorization instead of resolving to a uniform Principal. Invariant 8 already forbids this. The note is "the migration and all future auth work must preserve Invariant 8."

None of these is an action item. They are guardrails: as long as the current design's invariants hold, the §17 client types are additive, each one a new authentication path landing on the existing Principal + authorization plane.

## 18. References

- Keycloak Server Administration Guide (v26): https://www.keycloak.org/docs/latest/server_admin/
- Keycloakify: https://keycloakify.dev (see `KEYCLOAK_THEMING_GUIDE.md`)
- Microsoft Entra publisher verification: https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview
- Microsoft admin consent endpoint: https://learn.microsoft.com/en-us/entra/identity-platform/v2-admin-consent
- Microsoft Entra app registration (multitenant): https://learn.microsoft.com/en-us/entra/identity-platform/howto-convert-app-to-be-multi-tenant
- GitHub OAuth Apps: https://docs.github.com/en/apps/oauth-apps
- OpenTofu: https://opentofu.org
- Terraform Keycloak provider: https://registry.terraform.io/providers/keycloak/keycloak
- OIDC Back-Channel Logout 1.0: https://openid.net/specs/openid-connect-backchannel-1_0.html
- OAuth 2.1 (draft): https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- RFC 7591 — Dynamic Client Registration Protocol: https://datatracker.ietf.org/doc/html/rfc7591
- RFC 8414 — OAuth 2.0 Authorization Server Metadata: https://datatracker.ietf.org/doc/html/rfc8414
- RFC 8707 — Resource Indicators for OAuth 2.0: https://datatracker.ietf.org/doc/html/rfc8707
- RFC 9728 — OAuth 2.0 Protected Resource Metadata: https://datatracker.ietf.org/doc/html/rfc9728
- RFC 8628 — OAuth 2.0 Device Authorization Grant: https://datatracker.ietf.org/doc/html/rfc8628
- Model Context Protocol authorization spec: https://modelcontextprotocol.io/specification/draft/basic/authorization
- yourapp.com Access Control PRD.
- yourapp.com Audit Trail ADRs 001/002/003.
- yourapp.com Approval System Requirements.
- yourapp.com Infrastructure Hardening Plan.
- yourapp.com Agentics Layer specs — Foundation 1 (Principal generalization), §4.4 (native identity / KM request signing), §4.5 (federated identity validation). Cited by §17 for the non-Keycloak authentication planes.
- `KEYCLOAK_THEMING_GUIDE.md` (companion document).
- `KEYCLOAK_SETUP_GUIDE.md` (operational "how" companion).
- `KEYCLOAK_MCP_SPI_DESIGN.md` (SPI implementation).
- `YOURAPP_WEB_MCP_ENDPOINTS.md` (YourApp web MCP endpoints).
