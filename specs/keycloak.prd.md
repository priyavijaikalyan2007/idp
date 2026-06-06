# Authentication & Identity Brokering PRD

**Status:** Draft v1.5
**Owner:** PVSS
**Last Updated:** 2026-06-02
**Related Specs:** Access Control PRD (Zanzibar RBAC), Audit Trail ADR-001/002/003, Approval System Requirements, Pathfinder PRD (agent session management), **Keycloak Theming Guide** (companion document)

**Changelog:**
- v1.0 (2026-05-28): Initial draft.
- v1.1 (2026-06-02): Microsoft Entra strategy and admin-consent flow.
- v1.2 (2026-06-02): Six Keycloak 26.x runbook corrections.
- v1.3 (2026-06-02): Locked naming conventions; one shared Keycloak instance for prod+dev, local for test.
- v1.4 (2026-06-02): Expanded §8 into comprehensive app integration reference; expanded GitHub; added Apple Sign In; OpenTofu IaC commitment.
- v1.5 (2026-06-02): Apple Sign In deferred to Future Work (§15) per current priorities — removed from §6, §10.5, §10.8, §11, §13 main flow. Apple-related secrets removed from naming convention. §9 expanded to reference the new `KEYCLOAK_THEMING_GUIDE.md` companion document which carries all detailed theming setup, customization, build, and deployment instructions.

---

## Reader's Guide

This PRD addresses several audiences:

- **Architects / decision review** → §§1–10.
- **Operators setting up a Keycloak realm by hand** → §11 (runbook).
- **knobby.io app implementers (including Claude Code)** → §8 (integration reference) and §12.5 (tenant onboarding data model). §10.8 is the authoritative naming-convention table.
- **Infra engineers building Keycloak IaC** → §13 (OpenTofu plan) and §10.8.
- **Frontend engineers building the Keycloak theme** → `KEYCLOAK_THEMING_GUIDE.md` (companion document).
- **Customer-onboarding flow implementers** → §12.

§10.8 is the single source of truth for all naming. Any code, IaC, runbook step, or documentation that disagrees with §10.8 should be considered out of date.

---

## 1. Executive Summary

knobby.io will use Keycloak as a centralized identity broker that federates to all upstream identity providers (Google Workspace, Microsoft Entra, GitHub, enterprise SAML 2.0). Users will never directly interact with Keycloak. All login, profile management, and account operations occur within knobby.io's UI. Keycloak operates as invisible infrastructure: it terminates federation, mints tokens, and exposes an Admin REST API that knobby.io consumes server-side.

Enterprise customer onboarding is a first-class concern. Each enterprise customer tenant must be explicitly *connected* to knobby.io before its users can sign in. For Microsoft Entra, this means a tenant admin grants OAuth admin consent via a dedicated knobby.io onboarding flow. For Google Workspace, this means Workspace admin allowlisting. For SAML customers, this means the customer configures their IdP against knobby.io's SP metadata.

This PRD establishes the durable invariants, the target architecture, the tenant model, the per-IdP configuration, the per-customer onboarding pattern, naming conventions, application integration reference, and a step-by-step setup runbook for fresh realm configuration in any of the three environments. It also commits to OpenTofu as the IaC tool for automated realm setup, with the module structure described in §13. The Keycloak theme (consumed by the rare user-facing Keycloak pages that survive Invariant 3) is documented in the companion `KEYCLOAK_THEMING_GUIDE.md`.

---

## 2. Context

### 2.1 Business Drivers

knobby.io is a B2B enterprise SaaS platform targeting software/IT organizations. Customer organizations expect:

- SSO integration with their existing IdP (Google Workspace, Microsoft Entra, custom SAML 2.0).
- No additional credentials for knobby.io itself.
- A consistent, branded experience that never breaks the "knobby.io product" illusion.
- Compliance with their internal identity governance (MFA, session policies, deprovisioning) — knobby.io must not undermine these.
- IT-controlled onboarding: an enterprise admin explicitly approves knobby.io for the organization before users can sign in.
- Optional social sign-in (GitHub) for individual contributors and consumer-adjacent flows.

### 2.2 knobby.io Platform Needs

- One integration surface (Keycloak as OIDC IdP) regardless of how many upstream IdPs are configured.
- Consistent JWT claims across users from any source, so the Zanzibar-style RBAC + FGAC layer has uniform inputs.
- Centralized session management, logout coordination, and revocation.
- A path to support local users (B2C, contractors, service accounts) without re-architecting.
- First-class AI agent principals (per Access Control PRD) — distinct authentication paths from human users.
- A clean tenant-onboarding model that ties Microsoft tenant consent, Google Workspace allowlist, or SAML federation to a knobby.io Organization record.

### 2.3 Why Keycloak

Keycloak is the established open-source identity broker with mature support for OIDC, SAML 2.0, social IdPs, multi-realm and (as of v26) multi-organization tenancy.

---

## 3. Invariants

These constraints are durable design commitments. Changes require an ADR.

### Invariant 1 — No local username/password authentication in production flows

The realm does not expose a username/password form. All human users authenticate via an upstream IdP. The capability to support local credentials remains present in the realm configuration so it can be re-enabled later by modifying the browser flow.

### Invariant 2 — Upstream IdP policies are authoritative for authentication assurance

Keycloak does not enforce additional MFA, password policies, or session policies on top of what the upstream IdP requires. Whatever Google Workspace, Microsoft Entra, GitHub, or a customer's SAML IdP demands is what the user does. Keycloak brokers the result.

### Invariant 3 — Users never see Keycloak

Keycloak's user-facing surfaces are either replaced, bypassed, disabled, or themed beyond recognition. The Keycloak hostname is `auth.knobby.io` (or `localhost:8080` for the developer-local `test` environment). Theming is documented in `KEYCLOAK_THEMING_GUIDE.md`.

### Invariant 4 — knobby.io is a single OIDC client of Keycloak per environment

The knobby.io application integrates with Keycloak as one OIDC client per environment (`knobby-prod-web`, `knobby-dev-web`, `knobby-test-web`).

### Invariant 5 — Per-environment IdP credentials

Every upstream IdP integration (Google OAuth client, Microsoft Entra app registration, GitHub OAuth app, customer SAML SP entry) is registered separately per environment.

### Invariant 6 — Convention-based naming

All Keycloak resources and associated secrets follow a deterministic naming convention so that automation, scripts, runbooks, and human operators can derive any name from the environment alone. See §10.8 for the full naming table.

### Invariant 7 — Realm configuration as code

Once the OpenTofu IaC for realm setup is in place (per §13), manual changes to realm configuration through the Keycloak admin console are not permitted in `prod` or `dev`. All realm configuration changes flow through the IaC repository with code review.

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

**Production-facing topology:** one Keycloak instance hosted at `https://auth.knobby.io` serves both the `knobby-prod` and `knobby-dev` realms. Trade-off: lower infra cost, shared upgrade cycle.

**Test environment:** developer-local Keycloak via Docker Compose. See §11.17.

### 4.2 Component Responsibilities

**Keycloak**
- Terminates federation to upstream IdPs.
- Maintains the canonical federated user record.
- Issues OIDC tokens.
- Exposes Admin REST API.
- Hosts SAML SP metadata endpoint.

**knobby.io frontend**
- Renders the login screen with IdP buttons (Google, Microsoft, GitHub, "Enterprise SSO").
- Initiates OIDC Authorization Code + PKCE flow against Keycloak with `kc_idp_hint=<alias>`.
- Renders all account, profile, and tenant management UI.
- Renders the enterprise admin onboarding flow.
- Handles logout via RP-initiated logout.

**knobby.io backend (ASP.NET Core)**
- Validates OIDC tokens.
- Calls Keycloak Admin REST API.
- Maps Keycloak `sub` to knobby.io user identity.
- Enforces RBAC/FGAC per the Access Control PRD.
- Owns tenant-connection state.

**Agent runtime (future)**
- Authenticates via OAuth 2.0 Client Credentials with a per-agent client.

### 4.3 Data Flow — Human Login (happy path)

1. User opens `knobby.io`. App renders login screen.
2. User clicks "Sign in with Google" (or Microsoft / GitHub / Enterprise SSO). Frontend navigates to Keycloak's authorize endpoint with `kc_idp_hint=google`.
3. Keycloak 302s to Google. No Keycloak HTML rendered.
4. User authenticates at the IdP.
5. IdP 302s back to Keycloak's broker endpoint with authorization code.
6. Keycloak exchanges the code, reads identity claims.
7. Keycloak runs First Broker Login flow: looks up federated user; creates if needed.
8. Keycloak 302s back to `https://knobby.io/auth/callback?code=...&state=...`.
9. knobby.io backend exchanges Keycloak's code for tokens, validates, establishes session.

### 4.4 Data Flow — Logout

RP-initiated logout from knobby.io frontend, hits Keycloak end-session endpoint with `id_token_hint` and `post_logout_redirect_uri`. Keycloak terminates session, 302s back. Upstream IdP session is not terminated.

### 4.5 Data Flow — Enterprise Tenant Onboarding

See §12.

---

## 5. Tenant Model

### 5.1 Recommendation: Keycloak Organizations (GA in 26)

One realm contains multiple Organizations. Each Organization has its own brokered IdPs, its own membership, and (optionally) its own theme. Users can belong to one or more Organizations.

**Rationale:** knobby.io's customer-organization model maps directly to Keycloak Organizations.

**Constraint:** lock in before onboarding the first enterprise SAML customer.

---

## 6. Identity Provider Strategy

### 6.1 Common Configuration (all IdPs)

For every IdP added to a realm:
- **Alias** is stable and lowercase (used in `kc_idp_hint`).
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

**Implementation:** generic **OpenID Connect v1.0** provider type — not the built-in "Microsoft" provider.

**Per-environment Entra app registrations** (multi-tenant + personal account support enabled):
- Prod: `knobby.io Keycloak Broker`
- Dev: `knobby.io Keycloak Broker (dev)`
- Test: `knobby.io Keycloak Broker (test - {developer-name})`

**Discovery endpoint:** `https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration`.

**Issuer validation gotcha:** leave the **Issuer** field empty.

**Forwarded query parameters:** `login_hint,domain_hint,prompt`.

**Personal-account differentiation:** `tid` claim. Personal MSAs have `tid=9188040d-6c67-4c5b-b112-36a304b66dad`.

**Client secrets:** `knobby-entra-broker-client-secret-{env}`.

**Publisher verification:** see §10.7. Mitigated by the admin consent flow (§12).

**Trust posture:**
- Work/school accounts: equivalent trust tier to Google Workspace.
- Personal MSAs: lower trust tier. Rejected from enterprise-tier Organizations at the application authorization layer.

### 6.4 GitHub

GitHub is a **lower-trust** IdP than Google or Microsoft work accounts. Used for individual contributors, developer-focused signups, and consumer-adjacent flows. Not the default for enterprise customer users.

**Implementation:** built-in provider, alias `github`.

**Per-environment GitHub OAuth Apps:**
- Prod: `knobby.io`
- Dev: `knobby.io (dev)`
- Test: `knobby.io (test - {developer-name})` — per-developer apps

**Configuration on GitHub** (Developer Settings → OAuth Apps → New OAuth App):
| Field | Prod | Dev | Test |
|-------|------|-----|------|
| Application name | `knobby.io` | `knobby.io (dev)` | `knobby.io (test - {dev-name})` |
| Homepage URL | `https://knobby.io` | `https://knobby.io` | `http://localhost:3000` |
| Authorization callback URL | `https://auth.knobby.io/realms/knobby-prod/broker/github/endpoint` | `https://auth.knobby.io/realms/knobby-dev/broker/github/endpoint` | `http://localhost:8080/realms/knobby-test/broker/github/endpoint` |
| Enable Device Flow | Off | Off | Off |

**Scopes:** `user:email read:user`.

**Email handling caveat:** GitHub users can hide their email. Configure an attribute mapper that pulls the primary verified email from `/user/emails`. If still null after all mappers, the user can't federate via GitHub — treated as a profile data error, acceptable for an optional social IdP.

**Trust Email:** On (GitHub verifies primary email).

**Client secrets:** `knobby-github-oauth-client-secret-{env}`.

### 6.5 Enterprise SAML 2.0 (per customer organization)

- One SAML IdP entry per Organization. Alias pattern `saml-<org-slug>`.
- Configuration imported from customer-supplied SAML metadata XML.
- knobby.io's SP entity ID per env:
  - Prod: `https://auth.knobby.io/realms/knobby-prod`
  - Dev: `https://auth.knobby.io/realms/knobby-dev`
- ACS URL: `<SP-entity-id>/broker/saml-<org-slug>/endpoint`.
- NameID format: `emailAddress` preferred.
- Signed AuthnRequests and signed assertions required.
- Linked to a Keycloak Organization to scope membership.

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

This section is the authoritative reference for the knobby.io application's integration with Keycloak. An implementer (including Claude Code) should be able to build the knobby.io auth layer from this section alone, consulting §10.8 for naming.

### 8.1 Per-Environment URL & ID Reference

All URLs and identifiers needed for app configuration, parameterized by `{env}` ∈ `{prod, dev, test}`. Examples shown for prod.

**Base URLs:**

| Setting | Prod / Dev | Test |
|---------|-----------|------|
| Keycloak base URL | `https://auth.knobby.io` | `http://localhost:8080` |
| Realm name | `knobby-{env}` | `knobby-test` |
| OIDC issuer | `https://auth.knobby.io/realms/knobby-{env}` | `http://localhost:8080/realms/knobby-test` |
| OIDC discovery (well-known) | `<issuer>/.well-known/openid-configuration` | (same pattern) |
| Authorization endpoint | `<issuer>/protocol/openid-connect/auth` | (same) |
| Token endpoint | `<issuer>/protocol/openid-connect/token` | (same) |
| Userinfo endpoint | `<issuer>/protocol/openid-connect/userinfo` | (same) |
| JWKS endpoint | `<issuer>/protocol/openid-connect/certs` | (same) |
| End-session endpoint | `<issuer>/protocol/openid-connect/logout` | (same) |
| Admin REST API base | `<keycloak-base>/admin/realms/knobby-{env}` | (same pattern) |

**knobby.io application URLs** (registered as Valid Redirect URIs / Valid Post-Logout URIs on the `knobby-{env}-web` client):

| Purpose | Prod | Dev | Test |
|---------|------|-----|------|
| Sign-in callback | `https://knobby.io/auth/callback` | `https://dev.knobby.io/auth/callback` | `http://localhost:3000/auth/callback` |
| Post-logout landing | `https://knobby.io/` | `https://dev.knobby.io/` | `http://localhost:3000/` |
| Front-channel logout | `https://knobby.io/auth/frontchannel-logout` | `https://dev.knobby.io/auth/frontchannel-logout` | `http://localhost:3000/auth/frontchannel-logout` |
| Back-channel logout | `https://knobby.io/auth/backchannel-logout` | `https://dev.knobby.io/auth/backchannel-logout` | `http://localhost:3000/auth/backchannel-logout` |
| Microsoft admin consent callback | `https://knobby.io/auth/microsoft/admin-consent-callback` | `https://dev.knobby.io/auth/microsoft/admin-consent-callback` | `http://localhost:3000/auth/microsoft/admin-consent-callback` |

### 8.2 OIDC Client Configuration

The `knobby-{env}-web` client in Keycloak has these settings (configured per §11.4):

| Setting | Value |
|---------|-------|
| Client type | OpenID Connect |
| Client authentication | On (confidential) |
| Authorization | Off (Zanzibar layer handles authz) |
| Standard flow | Enabled (Authorization Code) |
| Direct access grants | Disabled |
| Implicit / hybrid flows | Disabled |
| PKCE | `S256`, required |
| Front-channel logout | Enabled |
| Back-channel logout | Enabled, session required |

The client secret is in `knobby-keycloak-web-client-secret-{env}` (GCP Secrets Manager for prod/dev, `.env` for test).

### 8.3 Token Claims Contract

The ID token and access token issued by Keycloak to the `knobby-{env}-web` client carry these claims. The knobby.io backend MUST validate `iss`, `aud`, `exp`, signature; MAY rely on the rest.

| Claim | Type | Source | Notes |
|-------|------|--------|-------|
| `iss` | string | Keycloak | Equals `https://auth.knobby.io/realms/knobby-{env}` (or `http://localhost:8080/realms/knobby-test`). Validate. |
| `aud` | string | Keycloak | Equals `knobby-{env}-web`. Validate. |
| `exp` | int (unix) | Keycloak | Validate. |
| `iat` | int (unix) | Keycloak | Issuance time. |
| `sub` | string (UUID) | Keycloak | Stable knobby.io user identifier. Primary key for user records. |
| `email` | string | IdP (via Keycloak) | Verified email. |
| `email_verified` | bool | IdP | Always `true` in normal flow (per Invariant 2). |
| `name` | string | IdP | Display name. |
| `given_name` | string | IdP | First name. May be missing for some IdPs. |
| `family_name` | string | IdP | Last name. Same caveat. |
| `preferred_username` | string | Keycloak | Usually equals `email`. |
| `org` | string or array | Keycloak | Organization ID(s) the user belongs to. Source claim for tenant scoping. |
| `idp` | string | Keycloak | Alias of the IdP that authenticated this session: `google`, `microsoft`, `github`, or `saml-<slug>`. |
| `microsoftTenantId` | string (UUID) | Microsoft via Keycloak | Only present when `idp=microsoft`. Equals `9188040d-6c67-4c5b-b112-36a304b66dad` for personal MSAs. |
| `microsoftObjectId` | string (UUID) | Microsoft via Keycloak | Only when `idp=microsoft`. |

**Trust rules for knobby.io backend:**
- `sub` is the stable user identifier. Never trust `email` alone for user lookup.
- Use `idp` + application policy to gate joining enterprise Organizations (e.g., reject `idp=github` from joining an enterprise tier).
- Use `microsoftTenantId` to differentiate enterprise vs. personal Microsoft accounts.
- `org` is for routing within knobby.io; the Zanzibar layer enforces authorization.

### 8.4 ASP.NET Core 10 Integration Pattern

knobby.io's backend integrates with Keycloak via the standard OpenID Connect middleware.

**NuGet packages:**
- `Microsoft.AspNetCore.Authentication.OpenIdConnect`
- `Microsoft.AspNetCore.Authentication.JwtBearer`
- `Microsoft.IdentityModel.Tokens`

**Configuration model** (`KeycloakOptions.cs`):

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
    options.Scope.Add("organization");

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
            var sub = context.Principal.FindFirst("sub")?.Value;
            var idp = context.Principal.FindFirst("idp")?.Value;
            var orgClaim = context.Principal.FindFirst("org")?.Value;
            // synchronize with knobby.io user table; populate org context
        },
        OnRedirectToIdentityProvider = context =>
        {
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

**`GET /auth/logout-callback`** — post-logout callback. ASP.NET OIDC middleware handles.

**`POST /auth/backchannel-logout`** — Keycloak-initiated back-channel logout. Receives a `logout_token` JWT. knobby.io validates the signature against the JWKS and the `sid` claim, then invalidates the local session. Implement explicitly. Reference: OIDC Back-Channel Logout 1.0 spec.

**`GET /auth/frontchannel-logout`** — Keycloak-initiated front-channel logout. Rendered in a hidden iframe by Keycloak's logout page. Should invalidate the user's session and return 200 OK.

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

**Common operations** (`<base>` = `https://auth.knobby.io/admin/realms/knobby-{env}`):

| Operation | Method | URL |
|-----------|--------|-----|
| Get user by sub | GET | `<base>/users/{sub}` |
| Find user by email | GET | `<base>/users?email={email}&exact=true` |
| Update user attributes | PUT | `<base>/users/{sub}` |
| Delete user | DELETE | `<base>/users/{sub}` |
| List organizations | GET | `<base>/organizations` |
| Get organization | GET | `<base>/organizations/{org-id}` |
| Create organization | POST | `<base>/organizations` |
| Add user to organization | POST | `<base>/organizations/{org-id}/members` |
| List org members | GET | `<base>/organizations/{org-id}/members` |
| Remove user from org | DELETE | `<base>/organizations/{org-id}/members/{sub}` |
| List user sessions | GET | `<base>/users/{sub}/sessions` |
| Revoke specific session | DELETE | `<base>/sessions/{session-id}` |
| Revoke all user sessions | POST | `<base>/users/{sub}/logout` |
| List identity providers | GET | `<base>/identity-provider/instances` |
| Provision per-customer SAML IdP | POST | `<base>/identity-provider/instances` |
| Link IdP to organization | POST | `<base>/organizations/{org-id}/identity-providers` |

Full API: https://www.keycloak.org/docs-api/latest/rest-api/.

### 8.8 Account Console Disablement

Both built-in account clients disabled per realm:
- `account` — Enabled = Off
- `account-console` — Enabled = Off

URLs return 404 / unauthorized.

### 8.9 AI Agent Authentication (future, parked)

Per the Access Control PRD. Realm must remain compatible.

---

## 9. Theming

Keycloak's user-facing fallback pages (rendered when `kc_idp_hint` is missing, on errors, on logout confirmation, on session expiry, on account linking) are themed to match knobby.io's design system using **Keycloakify** — a React + TypeScript toolchain that transpiles to Keycloak's expected FreeMarker theme format.

**All detailed setup, customization, build, and deployment instructions for the theme are in the companion document `KEYCLOAK_THEMING_GUIDE.md`.** This includes:

- Keycloakify project setup and dependencies.
- Project structure within the knobby.io frontend repository.
- Design system integration (sharing tokens and components with the main knobby.io frontend).
- Page-by-page customization (login fallback, error pages, logout, session expired, account linking).
- Internationalization.
- Building the theme JAR.
- Deploying to Keycloak via Docker image baking or providers-directory drop.
- Local development workflow against the `knobby-test` realm.
- CI/CD pipeline integration.
- Common gotchas (FreeMarker fallback, theme caching, resource paths).

Pages explicitly **not** themed:
- Account console — disabled per §8.8.
- Admin console — internal-only, default `keycloak.v2` theme acceptable.
- Registration / forgot password — disabled per Invariant 1.

---

## 10. Operational Considerations

### 10.1 Availability

Keycloak is tier-zero. Run on Cloud Run with `min-instances=2`. Postgres backend on Supabase with HA. Since prod and dev share one instance, all realm configuration changes flow through the OpenTofu IaC (§13); Keycloak version upgrades are tested in the dev realm in the same instance before effects reach prod.

### 10.2 Token Lifetimes

Per §8.6.

### 10.3 Logout Coordination

RP-initiated logout from knobby.io frontend. Back-channel logout from Keycloak to knobby.io backend. Upstream IdP logout is not initiated by Keycloak by default.

### 10.4 Break-Glass Admin

Break-glass admin lives in the master realm with YubiKey-backed TOTP. Username/password authentication remains enabled for the master realm only.

### 10.5 Secrets Management

All secrets follow the convention `knobby-<system>-<purpose>-<credential-type>-{env}` and are stored in GCP Secrets Manager (prod, dev) or developer-local `.env` (test).

| Secret name | Used by | Source |
|-------------|---------|--------|
| `knobby-keycloak-admin-api-client-secret-{env}` | knobby.io backend → Keycloak Admin REST API | Keycloak: `knobby-{env}-admin-api` client credentials |
| `knobby-keycloak-web-client-secret-{env}` | knobby.io backend → Keycloak token endpoint | Keycloak: `knobby-{env}-web` client credentials |
| `knobby-entra-broker-client-secret-{env}` | Keycloak → Microsoft Entra (broker auth) | Entra app registration: client secret |
| `knobby-google-oauth-client-secret-{env}` | Keycloak → Google (broker auth) | Google Cloud OAuth client |
| `knobby-github-oauth-client-secret-{env}` | Keycloak → GitHub (broker auth) | GitHub OAuth App |
| `knobby-keycloak-db-password-{env}` | Keycloak → Postgres | Postgres user |

### 10.6 Audit

Keycloak emits events that feed the platform event bus: login success/failure, IdP federation events, user CRUD, session termination, Admin API operations. Custom SPI exporter (future work) pushes to the Postgres transactional outbox.

### 10.7 Microsoft Entra Publisher Verification

Microsoft's risk-based step-up consent policy (effective November 2020) means newly registered multitenant apps without verified-publisher status face cross-tenant consent friction. Mitigated by the admin consent flow (§12). Start Microsoft AI Cloud Partner Program enrollment for prod; skip for dev/test.

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
| Google broker redirect URI | `<issuer>/broker/google/endpoint` | `https://auth.knobby.io/realms/knobby-prod/broker/google/endpoint` |
| Microsoft broker redirect URI | `<issuer>/broker/microsoft/endpoint` | `https://auth.knobby.io/realms/knobby-prod/broker/microsoft/endpoint` |
| GitHub broker redirect URI | `<issuer>/broker/github/endpoint` | `https://auth.knobby.io/realms/knobby-prod/broker/github/endpoint` |
| Keycloak admin API secret | `knobby-keycloak-admin-api-client-secret-{env}` | `knobby-keycloak-admin-api-client-secret-prod` |
| Keycloak web client secret | `knobby-keycloak-web-client-secret-{env}` | `knobby-keycloak-web-client-secret-prod` |
| Entra broker secret | `knobby-entra-broker-client-secret-{env}` | `knobby-entra-broker-client-secret-prod` |
| Google OAuth secret | `knobby-google-oauth-client-secret-{env}` | `knobby-google-oauth-client-secret-prod` |
| GitHub OAuth secret | `knobby-github-oauth-client-secret-{env}` | `knobby-github-oauth-client-secret-prod` |
| Keycloak DB password | `knobby-keycloak-db-password-{env}` | `knobby-keycloak-db-password-prod` |
| knobby.io OIDC callback path | `/auth/callback` | (same per env) |
| knobby.io backchannel logout path | `/auth/backchannel-logout` | (same per env) |
| knobby.io MS admin consent callback | `/auth/microsoft/admin-consent-callback` | (same per env) |
| Keycloak theme name (per §9) | `knobby` | `knobby` |

---

## 11. Setup Runbook — Fresh Realm Configuration

Currently manual; will be superseded by the OpenTofu IaC per §13 once available.

Prerequisites: Keycloak 26.x deployed; per-environment IdP credentials created per §10.8; for the theme, the `knobby` theme JAR baked into the Keycloak image per `KEYCLOAK_THEMING_GUIDE.md`.

Execute in **dev first**, then **prod**. Test setup per §11.17 on each developer's machine.

**Ordering note:** flows (§11.6–11.8) and Required Actions (§11.9) before IdPs (§11.10–11.13).

### 11.1 Create the Realm

1. Log into Keycloak admin console as master realm admin.
2. Realm dropdown → **Create realm**.
3. Realm name: `knobby-{env}`.
4. Enabled: On. Click **Create**.

### 11.2 Configure Realm Settings

**Realm settings → Login tab:** User registration Off, Forgot password Off, Remember me Off, Email as username On, Login with email On, Duplicate emails Off, Verify email Off, Edit username Off.

**Realm settings → Email tab:** Leave unconfigured.

**Realm settings → Themes tab:** Login `keycloak` for now (will switch to `knobby` after theme is built per `KEYCLOAK_THEMING_GUIDE.md` and §11.16). Admin `keycloak.v2`.

**Realm settings → Tokens tab:** Access Token 5 min; SSO Idle 30 min; SSO Max 10 hrs; Revoke Refresh Token On; Refresh Token Max Reuse 0.

**Realm settings → Security defenses:** Brute Force Detection On; X-Frame-Options DENY; HSTS Max Age 31536000 (skip HSTS for test).

### 11.3 Enable Organizations Feature

1. Confirm Keycloak started with `--features=organization`.
2. **Realm settings → General → Organizations**: On. Save.

### 11.4 Create OIDC Web Client

1. **Clients → Create client**. Client type: OIDC. Client ID: `knobby-{env}-web`.
2. Client authentication: On. Authorization: Off. Standard flow only.
3. Root URL, redirect URIs, post-logout URIs per §8.1.
4. **Credentials tab:** copy secret to `knobby-keycloak-web-client-secret-{env}`.
5. **Advanced tab:** PKCE S256. Front-channel logout On. Back-channel logout URL set. Back-channel logout session required On.

### 11.5 Configure Organizations & Token Claim

1. **Organizations → Create organization** (initial internal `knobby`).
2. **Client scopes → Create client scope** named `organization`, type Default. Add Organization Membership mapper with token claim name `org` in ID/access/userinfo tokens.
3. Assign the scope to `knobby-{env}-web`.

### 11.6 Create `first-broker-login-no-prompt` Authentication Flow

Duplicate `first broker login` flow. Disable Review Profile, Confirm Link, Verify Existing Account by Email, Verify Existing Account by Re-auth. Add Automatically Set Existing User → Required.

### 11.7 Create `browser-federated-only` Authentication Flow

Duplicate `browser` flow. Identity Provider Redirector: Required, no default IdP. Forms subflow: Disabled.

### 11.8 Bind the Custom Browser Flow

Open `browser-federated-only` → Action menu → Bind flow → Browser flow → Save. (Bindings tab is gone in 26.x.)

### 11.9 Configure Required Actions

All actions → Default Action Off (Configure OTP, Update Password, Update Profile, Verify Email, Verify Profile, Terms and Conditions, Delete Account, etc.).

### 11.10 Add Google as IdP

1. **Identity Providers → Add → Google.** Alias `google`.
2. Client ID, Client Secret from `knobby-google-oauth-client-secret-{env}`.
3. **Settings → Advanced:** Trust Email On, **First Login Flow `first-broker-login-no-prompt`**, Sync Mode `force`, Store Tokens Off, Hide on Login Page Off.

### 11.11 Add Microsoft Entra as IdP

Per §6.3 (full Entra app registration + Keycloak OIDC config + attribute mappers).

**Entra app registration:**
1. Entra admin center → App registrations → New registration.
2. Name per §6.3. Multitenant + personal MSAs.
3. Redirect URI per §10.8.
4. Client secret in Certificates & secrets → store as `knobby-entra-broker-client-secret-{env}`.
5. API permissions: Graph delegated `openid`, `profile`, `email`, `offline_access`, `User.Read`. Grant admin consent.
6. Branding: logo, publisher domain `knobby.io`, TOS, Privacy.

**Keycloak config:**
7. Identity Providers → Add → OpenID Connect v1.0. Alias `microsoft`.
8. Discovery endpoint: `https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration`.
9. Client ID, secret from Entra. Default Scopes `openid profile email`.
10. **Issuer field: empty** (multi-tenant `{tenantid}` placeholder workaround).
11. Validate Signatures On. Use JWKS URL On. Allowed clock skew 0.
12. Accepts prompt=none forward On.
13. **Forwarded Query Parameters: `login_hint,domain_hint,prompt`**.
14. Trust Email On. **First Login Flow `first-broker-login-no-prompt`**. Sync Mode `force`.

**Mappers:**
15. Attribute Importer: claim `tid` → user attribute `microsoftTenantId`.
16. Attribute Importer: claim `oid` → user attribute `microsoftObjectId`.
17. Username Template Importer: template `${CLAIM.email}` (avoids `#EXT#` suffix for guest users).

### 11.12 Add GitHub as IdP

**Prerequisite — GitHub OAuth App (per environment):**

1. GitHub → Settings → Developer settings → OAuth Apps → New OAuth App.
2. Configure per §6.4 (application name, homepage URL, authorization callback URL, Device Flow Off).
3. Register application.
4. On the app page, click **Generate a new client secret** → copy the value (shown once).
5. Store as `knobby-github-oauth-client-secret-{env}`.

**Keycloak config:**

6. **Identity Providers → Add → GitHub.** Alias `github`.
7. Client ID and Client Secret from steps 1 and 5.
8. **Settings tab → Advanced:**
   - Default Scopes: `user:email read:user`
   - Trust Email: On
   - **First Login Flow: `first-broker-login-no-prompt`**
   - Sync Mode: `force`
   - Store Tokens: Off
   - Hide on Login Page: Off

**Mapper:** Attribute Importer: claim `email` → user attribute `email`.

**Verify:** Sign in via GitHub in incognito. Confirm `email` populated on the new federated user.

### 11.13 Add Customer SAML IdP (template, per customer)

Performed once per enterprise customer, ideally via Admin API automation. Manual:

1. Obtain customer's SAML metadata XML.
2. Identity Providers → Add → SAML v2.0. Alias `saml-<customer-slug>`.
3. Use entity descriptor: Import metadata XML.
4. NameID policy format: `emailAddress`.
5. Want AuthnRequests Signed On, Want Assertions Signed On, Validate Signature On.
6. **First Login Flow: `first-broker-login-no-prompt`**. Sync Mode `force`.
7. Link IdP to customer's Organization under Organizations → \<org\> → Identity providers.

### 11.14 Disable Account Console

Clients → `account-console` Enabled Off; `account` Enabled Off. Verify URLs return 404.

### 11.15 Create Admin API Service Account Client

1. **Clients → Create client.** Client ID: `knobby-{env}-admin-api`. Client authentication On. Service accounts roles On. All flows Off.
2. **Service accounts roles tab → Assign role** → modal **Filter by clients** → search `realm-management` → assign: `view-users`, `manage-users`, `view-realm`, `query-users`, `query-groups`, `manage-organizations`, `view-organizations`, `manage-identity-providers`, `view-identity-providers`.
3. **Credentials tab:** copy secret to `knobby-keycloak-admin-api-client-secret-{env}`.

### 11.16 Apply the knobby Theme

After the `knobby` theme JAR has been built and deployed to Keycloak per `KEYCLOAK_THEMING_GUIDE.md` (sections on building and deploying):

1. **Realm settings → Themes → Login Theme:** select `knobby`.
2. **Realm settings → Themes → Email Theme:** select `knobby` (if a custom email theme has been built).
3. Save.
4. Verify by hitting a fallback Keycloak-rendered page (e.g., the bare authorization endpoint without `kc_idp_hint`) and confirming the themed login renders.

### 11.17 Test Environment Setup (Developer Local)

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
    command: start-dev --features=organization
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

**2. Dockerfile** at `keycloak/Dockerfile` (also used for prod/dev builds — same image, different deployments):

```dockerfile
FROM quay.io/keycloak/keycloak:26.0 AS builder

# (Future) knobby Keycloakify theme JAR added here per KEYCLOAK_THEMING_GUIDE.md.
# ADD --chown=keycloak:keycloak ./themes/knobby-theme.jar /opt/keycloak/providers/

RUN /opt/keycloak/bin/kc.sh build --features=organization

FROM quay.io/keycloak/keycloak:26.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
EXPOSE 8080
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

**3. Developer-local `.env` file** (gitignored, per developer):

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
# Wait ~30 seconds. Open http://localhost:8080 → log in as admin.
```

Then follow §§11.1–11.16 substituting `knobby-test` and `localhost:8080` URLs.

**6. Smoke test:**

```bash
export KNOBBY_ENV=test
export ADMIN_CLIENT_SECRET="$KNOBBY_KEYCLOAK_ADMIN_API_CLIENT_SECRET_TEST"
./keycloak-smoke-test.sh
```

**Caveats:** HTTP only; HSTS disabled; no publisher verification; customer SAML testing requires a test IdP (e.g., samltest.id).

### 11.18 Verification Checklist

The smoke-test script `keycloak-smoke-test.sh` automates server-side tests and prints the URLs for browser-driven federation tests.

Coverage:
- Realm liveness via `.well-known/openid-configuration`.
- Account console disabled.
- Fallback IdP picker (no `kc_idp_hint`) — themed login with all configured IdP buttons.
- Direct-to-IdP routing per alias: `kc_idp_hint=google`, `kc_idp_hint=microsoft`, `kc_idp_hint=github`.
- Token claim inspection.
- Microsoft `tid` differentiation (work vs personal MSA).
- GitHub email mapping.
- Logout flow.
- Admin API smoke test.
- Themed error pages (verify the `knobby` theme is applied per §11.16).

---

## 12. Enterprise Tenant Onboarding

For each enterprise customer, three things must happen: knobby.io Organization is created, the customer's IdP is connected (via Microsoft admin consent / Google Workspace allowlist / SAML metadata exchange), and users can then sign in.

### 12.1 Pattern & Rationale

1. **knobby.io Organization is created.**
2. **The customer's IdP is connected to that Organization.** Mechanics differ per IdP family:
   - Microsoft Entra: admin consent.
   - Google Workspace: customer Workspace admin allowlists OAuth client.
   - SAML: customer configures knobby.io's SP metadata; knobby.io provisions a SAML IdP entry under the Organization.
3. **Users from the customer's IdP can sign in.**

This pattern is the enterprise norm (Slack, Notion, Linear, Asana, GitHub Enterprise).

### 12.2 Microsoft Admin Consent Endpoint

```
https://login.microsoftonline.com/{tenant}/adminconsent
  ?client_id={knobby-prod-entra-app-id}
  &state={knobby-state-token}
  &redirect_uri=https://knobby.io/auth/microsoft/admin-consent-callback
```

`{tenant}` is typically `organizations` (unknown tenant) or the tenant GUID/domain. Not `common`.

### 12.3 State Token Design

`microsoft_admin_consent_state` table:

| Column | Type | Notes |
|--------|------|-------|
| `state_token` | text PK | High-entropy random (32 bytes base64url) |
| `knobby_org_id` | uuid | Org initiating consent |
| `initiated_by_user_id` | uuid | User who clicked Connect |
| `expected_tenant_id` | uuid NULL | If known in advance |
| `created_at` / `expires_at` | timestamptz | 10-minute expiry |
| `consumed_at` | timestamptz NULL | Prevents replay |

### 12.4 Callback Handling

Success: `?admin_consent=True&tenant=<guid>&state=<token>`. Failure: `?error=...&state=...`.

Handler: validate state, persist `microsoft_tenant_connection`, mark state consumed, emit Activity, redirect to success page.

### 12.5 knobby.io Data Model

```sql
CREATE TABLE microsoft_admin_consent_state (
    state_token text PRIMARY KEY,
    knobby_org_id uuid NOT NULL REFERENCES organizations(id),
    initiated_by_user_id uuid NOT NULL REFERENCES users(id),
    expected_tenant_id uuid NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz NULL
);

CREATE INDEX idx_consent_state_expiry ON microsoft_admin_consent_state(expires_at)
    WHERE consumed_at IS NULL;

CREATE TABLE microsoft_tenant_connection (
    knobby_org_id uuid NOT NULL REFERENCES organizations(id),
    microsoft_tenant_id uuid NOT NULL,
    consent_granted_at timestamptz NOT NULL,
    consent_granted_by text NOT NULL,
    consent_revoked_at timestamptz NULL,
    PRIMARY KEY (knobby_org_id, microsoft_tenant_id)
);

CREATE INDEX idx_tenant_connection_tenant ON microsoft_tenant_connection(microsoft_tenant_id)
    WHERE consent_revoked_at IS NULL;
```

### 12.6 End-to-End Flow

Admin in Organization Settings → Identity → "Connect Microsoft 365" → Continue → redirect to Microsoft admin consent → admin signs in and accepts → redirect back to knobby.io → state validated → tenant connection persisted → success page shown.

### 12.7 Error Handling

| Scenario | Detection | UX |
|----------|-----------|-----|
| Admin not Global Admin | `error=access_denied&error_subcode=user_consent_required` | "Ask your Global Administrator to complete this step." |
| Admin clicks Cancel | `error=access_denied` | "Connection canceled." |
| State token expired (>10 min) | knobby.io detects | "Consent session expired. Try again." |
| State already consumed | `consumed_at` set | "Link already used. Start over." Log warning. |
| Tenant mismatch | `expected_tenant_id` set, doesn't match | "Sign in with an account from {expected-domain}." |
| Customer tenant blocks consent | Various Microsoft errors | "Your tenant's policies prevent third-party consent. Contact IT." |
| Microsoft endpoint timeout | knobby.io timeout | "Couldn't complete connection. Try again." |

### 12.8 Consent Revocation

Microsoft does not notify on revocation. Detect reactively when federation fails for known-connected tenant; mark `consent_revoked_at`, emit Activity.

### 12.9 Sign-in Routing

Strategy B (email-first home discovery) is the production target. Requires the Microsoft IdP's Forwarded Query Parameters set to `login_hint,domain_hint,prompt` per §11.11.

### 12.10 Analogous Patterns

**Google Workspace:** Workspace admin allowlists in Google Admin Console. `google_workspace_connection` table.

**SAML:** two-way metadata exchange. `saml_idp_connection` table. Provisioned via Admin REST API.

---

## 13. Realm Configuration Automation — OpenTofu

### 13.1 Decision

**Tool: OpenTofu** (https://opentofu.org). Rationale:
- OSS fork of Terraform after the BSL license change.
- Compatible with the Terraform Keycloak provider (`keycloak/keycloak`).
- Aligned with the OSS-forward stack.
- Declarative HCL syntax matches the spec-first approach.

**Out of scope:**
- IdP credentials at the source (Google Cloud OAuth client, Entra app registration, GitHub OAuth App) — remain manual one-time setups.
- GCP Secrets Manager entries — separate IaC module.
- Per-customer SAML IdPs and Organizations — runtime, via Keycloak Admin REST API.
- Keycloak deployment itself — separate infra IaC.

**In scope:**
- Realm creation and settings.
- Custom authentication flows and bindings.
- Required Actions configuration.
- Built-in IdPs (Google, Microsoft, GitHub).
- The `knobby-{env}-web` and `knobby-{env}-admin-api` clients.
- The `organization` client scope and mappers.
- Default internal `knobby` Organization.
- Account console disablement.
- Theme selection (assuming the theme JAR is already deployed per §11.16).

### 13.2 Repository Structure

```
knobby-infra-keycloak/
├── modules/
│   ├── knobby-realm/
│   ├── knobby-realm-google-idp/
│   ├── knobby-realm-microsoft-idp/
│   ├── knobby-realm-github-idp/
│   ├── knobby-realm-web-client/
│   ├── knobby-realm-admin-api-client/
│   └── knobby-realm-organizations/
├── environments/
│   ├── prod/
│   ├── dev/
│   └── test/
├── scripts/
│   └── keycloak-init.sh
└── README.md
```

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

For `test`, reads secrets from local `.env` instead of GCP Secrets Manager.

### 13.4 Implementation Phases

**Phase 1:** core realm + clients (validates with smoke tests 1-8, no IdPs).
**Phase 2:** Google + Microsoft IdPs (validates federation tests 10-12).
**Phase 3:** GitHub IdP (validates federation test 13).
**Phase 4:** Organizations + initial internal org + theme binding (parity with §11).
**Phase 5:** IaC drift detection in CI (scheduled `tofu plan`).

### 13.5 Migration from Manual Setup

The current `knobby-prod` realm will be `tofu import`-ed rather than recreated. Procedure:

1. Write OpenTofu modules to match current state exactly.
2. `tofu import` each existing resource.
3. `tofu plan` should show zero changes.
4. Going forward, all changes flow through OpenTofu (Invariant 7).

### 13.6 State Management

Per-environment OpenTofu state in GCS buckets with object versioning:
- `gs://knobby-tofu-state-prod/keycloak/`
- `gs://knobby-tofu-state-dev/keycloak/`
- `gs://knobby-tofu-state-test/keycloak/` (or developer-local)

### 13.7 What's Tracked in v1.5

This section commits to OpenTofu. Actual `.tf` files, module implementations, and `keycloak-init.sh` are the next deliverable.

---

## 14. Open Questions

1. **Single-org-per-user constraint** — does knobby.io enforce that a user belongs to exactly one Organization?
2. **Service account model for AI agents** — parked.
3. **Step-up authentication for sensitive operations** — `acr` claim enforcement timing.
4. **Customer SAML self-service** — via knobby.io admin UI or manual?
5. **CASB-managed tenants** — manual escalation path.
6. **Microsoft tenant domain refresh cadence** — 24h proposed.
7. **Event bus integration timeline** — parked.
8. **Personal MSA in enterprise orgs** — confirm policy.
9. **GCS state bucket retention** — Object Versioning enabled? Standard practice yes; confirm.
10. **Theme deployment cadence** — when the theme JAR changes, does it require a Keycloak restart and how is that orchestrated alongside the regular Keycloak version upgrade cycle? Detailed in `KEYCLOAK_THEMING_GUIDE.md` (deployment section); the operational answer affects §10.1.

---

## 15. Future Work (Tracked, Out of Scope for v1.5)

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
- **Apple Sign In** — deferred. When revived, configure via the `klausbetz/apple-identity-provider-keycloak` extension (Apple is not a Keycloak built-in IdP and uses JWT client assertion rather than client_secret). Requires Apple Developer account ($99/year), per-env Service IDs, .p8 key per env, and `klausbetz` JAR baked into the Keycloak Docker image. Application policy: Apple users admitted to consumer-tier Organizations only.

---

## 16. References

- Keycloak Server Administration Guide (v26): https://www.keycloak.org/docs/latest/server_admin/
- Keycloak Organizations: https://www.keycloak.org/docs/latest/server_admin/#_managing_organizations
- Keycloakify: https://keycloakify.dev (see also `KEYCLOAK_THEMING_GUIDE.md`)
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
