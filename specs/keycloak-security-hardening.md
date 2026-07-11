<!-- AGENT: Operator hardening runbook for the public YourApp Keycloak endpoint. -->

# Keycloak Security Hardening Runbook

**Status:** operator action pending  
**Last verified:** 2026-07-11  
**Endpoint:** `https://auth.yourapp.com`  
**Primary realm:** `yourapp-prod`

This runbook covers hardening steps that sit outside the SPI JAR and smoke-test baseline. The 2026-07-11 exploratory pass did not find an unauthenticated token, admin-data, DCR, or OAuth bypass, but it did confirm two public attack-surface issues worth closing before broad publication:

1. The Keycloak admin console and `master` realm are reachable on the public hostname.
2. CORS preflight responses on some Keycloak endpoints reflect arbitrary origins with credentials enabled.

The goal is not to hide Keycloak entirely. The production realm's normal OIDC endpoints must stay public. The goal is to remove public reachability for admin-only surfaces and keep browser-origin behavior narrow where feasible.

---

## 1. Restrict `/admin/*` and `/realms/master/*`

### Finding

External probes against `auth.yourapp.com` showed:

- `/admin/master/console/` returns the Keycloak Admin SPA.
- `/realms/master/.well-known/openid-configuration` returns the master realm metadata.
- `/realms/master/account/` returns the master account surface.

No authentication bypass was found. Admin REST endpoints still require authentication. This is still unnecessary public attack surface: it advertises Keycloak, exposes the master realm issuer, and gives scanners a stable admin UI to target.

### Recommended control: Cloudflare Access

Use Cloudflare Zero Trust Access for human-admin surfaces. This avoids brittle Keycloak theme hacks and does not affect the production realm's login/token/DCR endpoints.

1. In Cloudflare Zero Trust, open **Access -> Applications -> Add an application -> Self-hosted**.
2. Create an app for the admin console:
   - Application name: `YourApp Keycloak Admin`
   - Domain: `auth.yourapp.com`
   - Path: `/admin*`
   - Session duration: 8 to 12 hours is reasonable for admin work.
3. Add an allow policy:
   - Include only named admin emails or an identity-provider group.
   - Require MFA in the upstream identity provider used by Cloudflare Access.
   - Do not add service-token bypass unless a concrete automation flow needs it.
4. Create a second self-hosted app, or add an equivalent policy, for the master realm:
   - Domain: `auth.yourapp.com`
   - Path: `/realms/master*`
   - Same allow policy as the admin app.
5. Leave the production realm public:
   - Do not protect `/realms/yourapp-prod/.well-known/*`.
   - Do not protect `/realms/yourapp-prod/protocol/openid-connect/*`.
   - Do not protect `/realms/yourapp-prod/clients-registrations/*` unless you are deliberately pausing MCP DCR.
   - Do not protect `/resources/*`; the login and admin SPAs load assets from there.

### Alternative control: Cloudflare WAF custom rule

If Cloudflare Access is not available, use a WAF custom rule that blocks or challenges admin-only paths unless the source is an approved admin IP range.

Example intent:

```text
host is auth.yourapp.com
and (
  path starts with /admin
  or path starts with /realms/master
)
and source IP is not in the approved-admin list
then block or managed-challenge
```

Prefer Access over static IP allowlists when admins move between networks. If you use IP allowlists, keep a break-glass path documented before enabling the rule.

### Keycloak-side posture

- Do not place application clients or users in the `master` realm.
- Keep only break-glass administrative accounts in `master`.
- Require strong MFA on every account that can administer Keycloak through its upstream IdP or account policy.
- Use named admin accounts. Do not share a single `admin` user.

Keycloak does not provide a clean switch to make the master realm discovery document private while leaving other realms public. Put this control at the edge.

### Verification

Run these from a network that is not covered by an admin bypass:

```bash
curl -i https://auth.yourapp.com/admin/master/console/
curl -i https://auth.yourapp.com/realms/master/.well-known/openid-configuration
curl -i https://auth.yourapp.com/realms/master/account/
```

Expected result after Access/WAF is active: each request is blocked, challenged, or redirected to Cloudflare Access.

Then confirm production OIDC remains public:

```bash
curl -i https://auth.yourapp.com/realms/yourapp-prod/.well-known/openid-configuration
curl -i https://auth.yourapp.com/realms/yourapp-prod/protocol/openid-connect/auth
```

Expected result: discovery returns `200`; the authorization endpoint returns a normal Keycloak/OIDC response such as `400` for missing parameters or a login redirect when parameters are supplied. It should not return a Cloudflare Access block.

Finally run:

```bash
./smoke.sh
```

If the smoke tests use the Admin REST API through `auth.yourapp.com`, run them from an Access-authorized session/network or add a narrowly scoped operator bypass. Do not add a broad bypass for all clients.

### Rollback

Disable the Cloudflare Access app or WAF rule for `/admin*` and `/realms/master*`. Do not change Keycloak realm configuration during rollback unless the edge rule accidentally protected production realm paths.

---

## 2. Harden CORS and Browser-Origin Exposure

### Finding

Exploratory preflight probes observed `Access-Control-Allow-Origin` reflecting arbitrary origins with `Access-Control-Allow-Credentials: true` on several Keycloak endpoints, including OIDC and Admin REST paths.

No unauthenticated data access was found. Admin REST still returned `401` without credentials. The risk is browser-context abuse if an authenticated admin session can be driven from an attacker origin, especially while `/admin/*` remains public.

### Primary mitigation

Restrict `/admin/*` and `/realms/master/*` at the edge first. Once Cloudflare Access/WAF blocks those paths for non-admin contexts, permissive preflight behavior on admin endpoints is no longer reachable by the public web.

### Keycloak client configuration

Review each first-party client in every realm:

1. Open **Clients -> `yourapp-{env}-web` -> Settings**.
2. Set **Valid Redirect URIs** to exact app callback origins and paths. Avoid broad wildcards.
3. Set **Web Origins** explicitly:
   - Production: `https://prod.yourapp.com`
   - Development: `https://dev.yourapp.com`
   - Staging/test: the exact deployed app origin for that environment
4. Avoid `*` in Web Origins.
5. Avoid `+` unless the redirect URI list is already exact and intentionally maintained. Explicit origins are easier to audit.
6. Confirm Direct Access Grants remain disabled for browser clients.

For MCP DCR clients, do not rely on browser CORS as the security boundary. The security controls are:

- Trusted Hosts / redirect-domain allowlisting.
- Secure redirect URI enforcement.
- Allowed Protocol Mapper Types.
- The YourApp MCP Registration CRP grant-type guard.
- PKCE and loopback redirect rules for native clients.

### Cloudflare response-header rules

Do not blanket-strip CORS headers from all Keycloak OIDC endpoints without first testing the web app. Some browser-based OIDC flows can require CORS on token or userinfo calls depending on whether the app exchanges tokens in the browser or through its backend.

Safe edge strategy:

1. Block or protect admin/master paths with Access/WAF.
2. Leave production realm OIDC endpoints reachable.
3. Only add response-header transforms for CORS after confirming the app does not need browser CORS on the affected endpoint.

### Verification

Before and after hardening, test an attacker origin:

```bash
curl -i -X OPTIONS \
  'https://auth.yourapp.com/admin/realms/yourapp-prod/users' \
  -H 'Origin: https://evil.example.com' \
  -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: authorization'

curl -i -X OPTIONS \
  'https://auth.yourapp.com/realms/yourapp-prod/protocol/openid-connect/token' \
  -H 'Origin: https://evil.example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type'
```

Expected after Access/WAF:

- Admin REST preflight is blocked, challenged, or redirected by Cloudflare for unauthorised users.
- Production realm token behavior depends on the app architecture. If token exchange happens in the browser, allow only the exact first-party app origin. If token exchange is backend-only, no arbitrary browser origin should be accepted.

Test the legitimate app origin:

```bash
curl -i -X OPTIONS \
  'https://auth.yourapp.com/realms/yourapp-prod/protocol/openid-connect/token' \
  -H 'Origin: https://prod.yourapp.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type'
```

Expected result: compatible with the app's real login/token flow. Validate with a browser login, not only curl.

---

## 3. Regression Checklist

After changing Cloudflare or Keycloak client-origin settings:

- `./smoke.sh` passes.
- OIDC discovery for `yourapp-prod` returns `200`.
- A normal web login from `https://prod.yourapp.com` succeeds.
- Anonymous DCR attacker-host negative test remains rejected.
- MCP loopback DCR still works for approved loopback redirect URIs.
- `/admin/*` and `/realms/master/*` are not public from an unauthorised network.
- No Cloudflare optimization feature is rewriting Keycloak scripts or assets.

---

## 4. Future Smoke-Test Hooks

If the Access/WAF policy becomes a stable production requirement, add optional prod-only smoke checks:

- Admin/master edge protection: unauthorised GET to `/admin/master/console/` and `/realms/master/.well-known/openid-configuration` must not return `200`.
- Admin CORS preflight: unauthorised attacker-origin OPTIONS to `/admin/realms/yourapp-prod/users` must be blocked before Keycloak.

Keep those tests opt-in or environment-aware so local and pre-edge deployments do not fail by design.
