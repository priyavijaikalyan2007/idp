<!-- AGENT: Step-by-step operator hardening runbook for the public YourApp Keycloak endpoint. -->

# Keycloak Security Hardening Runbook

**Status:** operator action pending  
**Last verified:** 2026-07-11  
**Endpoint:** `https://auth.yourapp.com`  
**Primary realm:** `yourapp-prod`

This runbook is intentionally explicit. It assumes you are doing the work in browser consoles, not from memory.

The 2026-07-11 exploratory pass did **not** find an unauthenticated token, admin-data, DCR, or OAuth bypass. It did find two things to harden before broad publication:

1. Public users can reach the Keycloak admin UI and `master` realm URLs.
2. Some Keycloak endpoints answer CORS preflights for arbitrary origins.

The fix is mostly edge configuration. Keep normal `yourapp-prod` OIDC endpoints public; protect only admin-only surfaces.

---

## 0. Mental Model

### What Cloudflare Access does here

Cloudflare Access is an **outer gate** in front of selected paths.

Request flow after this guide:

```text
Browser
  -> Cloudflare Access check for /admin/* or /realms/master/*
  -> Keycloak admin login
  -> Keycloak admin TOTP
  -> Keycloak admin console
```

Cloudflare Access does **not** replace Keycloak admin login. It decides whether the request is allowed to reach Keycloak at all. Once it reaches Keycloak, Keycloak still asks for the admin username/login and still enforces Keycloak TOTP.

### Do not do these

- Do **not** create a Cloudflare **SaaS application** for this.
- Do **not** disable Keycloak admin login.
- Do **not** disable Keycloak TOTP.
- Do **not** configure Keycloak to trust Cloudflare's token as an admin login token.
- Do **not** protect all of `auth.yourapp.com`; that would break normal OIDC login, token, DCR, and discovery flows.
- Do **not** protect `/resources/*`; Keycloak pages load scripts and styles from there.

### What application type to create

Create **Self-hosted public applications** in Cloudflare Access.

Depending on the exact Cloudflare UI revision, the path may be labelled one of these:

- **Zero Trust -> Access -> Applications -> Add an application -> Self-hosted**
- **Zero Trust -> Access controls -> Applications -> Add web application -> Self-hosted public application**
- **Zero Trust -> Access controls -> Applications -> Self-hosted and private -> Add public hostname**

These labels point to the same kind of Access app: a policy in front of a public hostname/path.

---

## 1. Prerequisites

### 1.1 Confirm Cloudflare proxy is enabled

Cloudflare Access only enforces on traffic that actually passes through Cloudflare.

**Path:** Cloudflare dashboard -> Websites -> `yourapp.com` -> DNS -> Records

Find the DNS record for `auth.yourapp.com`.

Required state:

| Field | Value |
|---|---|
| Name | `auth` or `auth.yourapp.com` |
| Type | usually `CNAME` |
| Proxy status | **Proxied** / orange cloud |

If it is **DNS only** / grey cloud, Cloudflare Access will not protect `auth.yourapp.com`.

### 1.2 Disable Cloudflare optimizations for `auth.yourapp.com`

This is important because Keycloak's admin console is a JavaScript SPA and Cloudflare optimizations have broken it before.

**Path:** Cloudflare dashboard -> Websites -> `yourapp.com`

Create configuration rules, or use the equivalent product pages, scoped to:

```text
Hostname equals auth.yourapp.com
```

Set:

| Feature | Required value |
|---|---|
| Rocket Loader | Off |
| Auto Minify JavaScript | Off |
| Auto Minify CSS | Off |
| Auto Minify HTML | Off |
| Aggressive bot/challenge features | Off for `/resources/*`, `/admin/*`, and normal OIDC endpoints |

Keep Cloudflare proxying/DDoS/TLS on. Turn off content rewriting and blanket challenges.

### 1.3 Confirm Cloudflare Access login method

Cloudflare Access needs some identity method for the outer gate.

**Path:** Cloudflare Zero Trust -> Settings -> Authentication

Acceptable for this outer gate:

- Google login for your admin email.
- Microsoft/Entra login for your admin email.
- GitHub login for your admin account.
- One-time PIN to your admin email, if you have not set up an identity provider yet.

Keycloak TOTP remains the inner MFA control. If Cloudflare Access also has MFA through Google/Microsoft/GitHub, good; if not, the outer gate is still useful because it prevents anonymous scanners from reaching admin paths.

---

## 2. Protect `/admin/*`

### 2.1 Create the Access application

**Path:** Cloudflare Zero Trust -> Access -> Applications -> Add an application

Choose:

```text
Self-hosted public application
```

Do **not** choose:

```text
SaaS application
```

Fill the application form:

| Field | Value |
|---|---|
| Application name | `YourApp Keycloak Admin` |
| Application domain / hostname | `auth.yourapp.com` |
| Path | `/admin*` |
| Session duration | `8h` |
| App Launcher visibility | Off, if the UI asks |

Leave CORS settings at defaults unless the UI forces a choice. This app is only an access gate for admin paths.

### 2.2 Create the allow policy

On the same application, add a policy:

| Field | Value |
|---|---|
| Policy name | `allow-keycloak-admins` |
| Action | `Allow` |
| Include | Your exact admin email address, or an Access Group containing only Keycloak admins |
| Require | Optional: login method is your chosen IdP; optional: country/device posture if you already use those |
| Exclude | Empty, unless you need to block a specific account |

For a solo admin setup, the simplest safe policy is:

```text
Action: Allow
Include: Emails -> <your admin email>
```

Do not add a broad `Bypass` policy. Bypass means Cloudflare Access is not enforcing for matching traffic.

### 2.3 Save and test immediately

Open a private/incognito browser window and visit:

```text
https://auth.yourapp.com/admin/master/console/
```

Expected sequence:

1. Cloudflare Access login/approval screen appears first.
2. After you pass Cloudflare Access, Keycloak's normal admin login appears.
3. After Keycloak login, Keycloak still asks for TOTP if the admin account has TOTP enabled.
4. The admin console loads.

If you go straight to Keycloak without seeing Cloudflare Access first, check:

- DNS record is orange-cloud proxied.
- Access app hostname is exactly `auth.yourapp.com`.
- Access app path is exactly `/admin*`.
- The request URL starts with `/admin`.

---

## 3. Protect `/realms/master/*`

The `master` realm should not be a public application realm. Protect it separately.

### 3.1 Create the Access application

**Path:** Cloudflare Zero Trust -> Access -> Applications -> Add an application

Choose:

```text
Self-hosted public application
```

Fill:

| Field | Value |
|---|---|
| Application name | `YourApp Keycloak Master Realm` |
| Application domain / hostname | `auth.yourapp.com` |
| Path | `/realms/master*` |
| Session duration | `8h` |
| App Launcher visibility | Off, if the UI asks |

### 3.2 Add the same allow policy

Use the same policy shape:

```text
Action: Allow
Include: Emails -> <your admin email>
```

or reuse the same `keycloak-admins` Access Group if you created one.

### 3.3 Test immediately

From a private/incognito window:

```text
https://auth.yourapp.com/realms/master/.well-known/openid-configuration
```

Expected result: Cloudflare Access appears first, or Cloudflare denies the request if the user is not allowed.

After passing Cloudflare Access, Keycloak may show JSON or a Keycloak page. That is fine. The goal is that anonymous public users cannot reach it.

---

## 4. Confirm You Did Not Break Public OIDC

These paths must remain public because apps and MCP clients use them.

Run:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://auth.yourapp.com/realms/yourapp-prod/.well-known/openid-configuration
```

Expected:

```text
200
```

Run:

```bash
curl -i 'https://auth.yourapp.com/realms/yourapp-prod/protocol/openid-connect/auth'
```

Expected:

- A Keycloak/OIDC response.
- Usually `400` because required OAuth parameters are missing.
- **Not** a Cloudflare Access login page.
- **Not** a Cloudflare Access 403.

Run:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://auth.yourapp.com/resources/
```

Expected:

- `200`, `301`, `302`, or `404` from Keycloak is acceptable.
- A Cloudflare Access login page is **not** acceptable for `/resources/*`.

---

## 5. Verify Edge Protection With Curl

From a terminal that is not carrying browser cookies:

```bash
curl -i https://auth.yourapp.com/admin/master/console/ | sed -n '1,25p'
```

Good outcomes:

- `302` redirect to a Cloudflare Access login URL.
- `403` from Cloudflare Access.
- HTML that clearly says Cloudflare Access, not Keycloak.

Bad outcome:

- `200` with Keycloak admin console HTML.

Now test the master realm:

```bash
curl -i https://auth.yourapp.com/realms/master/.well-known/openid-configuration | sed -n '1,25p'
```

Good outcomes:

- `302` to Cloudflare Access.
- `403` from Cloudflare Access.
- Cloudflare Access login HTML.

Bad outcome:

- `200` with JSON containing `"issuer":"https://auth.yourapp.com/realms/master"`.

---

## 6. Smoke Test Caveat

`./smoke.sh` currently calls Keycloak Admin REST endpoints under:

```text
/admin/realms/<realm>/...
```

It authenticates to Keycloak with:

```text
Authorization: Bearer <Keycloak admin-api token>
```

It can send Cloudflare Access service-token headers when you export the `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` env vars. After you protect `/admin/*`, smoke tests that call Admin REST through `https://auth.yourapp.com` must use those env vars, or they may fail with a Cloudflare Access page or 403 even though Keycloak is healthy.

Use a Cloudflare Access **service token** for smoke tests. Do not use a broad bypass.

Cloudflare side:

1. Zero Trust -> Access -> Service Auth -> Service Tokens.
2. Create token: `yourapp-keycloak-smoke`.
3. Copy the generated Client ID and Client Secret.
4. Add a policy to both Access applications:

   | Field | Value |
   |---|---|
   | Policy name | `allow-smoke-service-token` |
   | Action | `Service Auth` |
   | Include | Service Token -> `yourapp-keycloak-smoke` |

Store the service-token values in Secret Manager. Suggested names:

```text
yourapp-cloudflare-access-smoke-client-id-prod
yourapp-cloudflare-access-smoke-client-secret-prod
```

Run smoke with:

```bash
export YOURAPP_ENV=prod
export ADMIN_CLIENT_SECRET=$(gcloud secrets versions access latest \
  --secret=yourapp-keycloak-admin-api-client-secret-prod)
export CF_ACCESS_CLIENT_ID=$(gcloud secrets versions access latest \
  --secret=yourapp-cloudflare-access-smoke-client-id-prod)
export CF_ACCESS_CLIENT_SECRET=$(gcloud secrets versions access latest \
  --secret=yourapp-cloudflare-access-smoke-client-secret-prod)
./smoke.sh
```

`smoke.sh` also accepts the longer aliases:

```text
CLOUDFLARE_ACCESS_CLIENT_ID
CLOUDFLARE_ACCESS_CLIENT_SECRET
```

The script adds these headers to curl requests when the env vars are present:

```text
CF-Access-Client-Id: <service-token-client-id>
CF-Access-Client-Secret: <service-token-client-secret>
```

It does not print the secret. Do not add the token to the repo.

### Emergency alternative: temporary narrow IP bypass

Use this only if the service-token setup is broken and you need a one-off smoke run.

1. Find your current public IP:

   ```bash
   curl -s https://ifconfig.me
   ```

2. In the `YourApp Keycloak Admin` Access application, add a policy above the allow policy:

   | Field | Value |
   |---|---|
   | Policy name | `temporary-smoke-ip-bypass` |
   | Action | `Bypass` |
   | Include | IP ranges -> `<your-public-ip>/32` |

3. Run:

   ```bash
   ./smoke.sh
   ```

4. Delete `temporary-smoke-ip-bypass` immediately after the smoke run.

This is less clean because bypassed requests do not get Access enforcement.

### Private-origin alternative

Only use this if you have a private/internal route to Keycloak that is not internet-accessible. Do not create a second public hostname just to bypass Cloudflare Access.

---

## 7. Keycloak CORS and Web Origins

This section narrows browser-origin behavior for first-party clients. It does not replace the Cloudflare Access admin/master protection above.

### 7.1 Configure `yourapp-prod-web`

**Path:** Keycloak admin console -> realm `yourapp-prod` -> Clients -> `yourapp-prod-web` -> Settings

Set:

| Field | Value |
|---|---|
| Valid redirect URIs | `https://prod.yourapp.com/auth/callback` |
| Valid post logout redirect URIs | `https://prod.yourapp.com/` |
| Web origins | `https://prod.yourapp.com` |
| Direct access grants | Off |
| Standard flow | On |
| Implicit flow | Off |

Do not use:

- `*`
- broad wildcard origins
- `https://*.yourapp.com`

If the UI currently has `+` for Web Origins, replace it with the explicit origin above. `+` derives origins from redirect URIs; explicit origins are easier to audit.

### 7.2 Configure `yourapp-dev-web`

**Path:** Keycloak admin console -> realm `yourapp-dev` -> Clients -> `yourapp-dev-web` -> Settings

Set:

| Field | Value |
|---|---|
| Valid redirect URIs | `https://dev.yourapp.com/auth/callback` |
| Valid post logout redirect URIs | `https://dev.yourapp.com/` |
| Web origins | `https://dev.yourapp.com` |
| Direct access grants | Off |
| Standard flow | On |
| Implicit flow | Off |

For local development only, add local origins to the dev realm, not prod:

```text
http://localhost:3000
http://localhost:5173
```

Only add the local ports your app actually uses.

### 7.3 Configure future staging/test web clients

Use the same pattern:

```text
Valid redirect URIs: exact /auth/callback URL
Valid post logout redirect URIs: exact app root URL
Web origins: exact app origin only
```

Do not copy prod origins into dev, and do not copy dev/localhost origins into prod.

### 7.4 Do not edit built-in Keycloak clients casually

Do not change these unless you are deliberately debugging Keycloak internals:

- `security-admin-console`
- `account-console`
- `broker`
- `realm-management`

These clients are easy to break. The admin/master risk is handled at Cloudflare, not by trying to surgically change Keycloak's built-in console clients.

---

## 8. CORS Verification

### 8.1 Admin REST preflight must be blocked by Cloudflare

Run:

```bash
curl -i -X OPTIONS \
  'https://auth.yourapp.com/admin/realms/yourapp-prod/users' \
  -H 'Origin: https://evil.example.com' \
  -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: authorization' \
  | sed -n '1,40p'
```

Expected after `/admin*` Access protection:

- Cloudflare Access blocks, challenges, or redirects.
- You should **not** see a normal Keycloak `204`/`200` preflight response for this public unauthorised request.

Bad result:

```text
access-control-allow-origin: https://evil.example.com
access-control-allow-credentials: true
```

on a normal Keycloak response from `/admin/realms/...`.

### 8.2 Production token endpoint evil-origin probe

Run:

```bash
curl -i -X OPTIONS \
  'https://auth.yourapp.com/realms/yourapp-prod/protocol/openid-connect/token' \
  -H 'Origin: https://evil.example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type' \
  | sed -n '1,40p'
```

Preferred result:

- No `access-control-allow-origin: https://evil.example.com`.

If Keycloak still reflects the evil origin here, record it as residual Keycloak behavior and do **not** immediately add a Cloudflare response-header rewrite. Token endpoint CORS can be flow-sensitive; breaking it may break browser login. The higher-risk admin path is already protected by Access.

### 8.3 Production token endpoint legitimate-origin probe

Run:

```bash
curl -i -X OPTIONS \
  'https://auth.yourapp.com/realms/yourapp-prod/protocol/openid-connect/token' \
  -H 'Origin: https://prod.yourapp.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type' \
  | sed -n '1,40p'
```

Expected:

- Compatible with the production app's login flow.
- If the app exchanges tokens in the browser, `https://prod.yourapp.com` must be allowed.
- If the app exchanges tokens only from the backend, the browser preflight can be stricter.

The final check is a real browser login at:

```text
https://prod.yourapp.com
```

If browser login works and admin evil-origin preflight is blocked, the important hardening objective is met.

---

## 9. Final Checklist

Mark this done only when all are true:

- [ ] `auth.yourapp.com` DNS record is Proxied / orange cloud.
- [ ] Rocket Loader and Auto Minify are off for `auth.yourapp.com`.
- [ ] Cloudflare Access application `YourApp Keycloak Admin` exists.
- [ ] `YourApp Keycloak Admin` protects hostname `auth.yourapp.com`, path `/admin*`.
- [ ] Cloudflare Access application `YourApp Keycloak Master Realm` exists.
- [ ] `YourApp Keycloak Master Realm` protects hostname `auth.yourapp.com`, path `/realms/master*`.
- [ ] Both apps allow only named Keycloak admin email(s) or a `keycloak-admins` Access Group.
- [ ] Both apps allow the `yourapp-keycloak-smoke` Service Auth token.
- [ ] No broad bypass policy exists.
- [ ] Incognito visit to `/admin/master/console/` shows Cloudflare Access before Keycloak.
- [ ] After Cloudflare Access, Keycloak still requires normal admin login and TOTP.
- [ ] Incognito visit to `/realms/master/.well-known/openid-configuration` is blocked or gated by Cloudflare Access.
- [ ] `yourapp-prod` OIDC discovery still returns `200`.
- [ ] `prod.yourapp.com` login still works.
- [ ] `yourapp-prod-web` Web Origins is exactly `https://prod.yourapp.com`.
- [ ] Dev/localhost Web Origins exist only in dev/test realms, not prod.
- [ ] Admin REST evil-origin preflight is blocked by Cloudflare Access.
- [ ] `./smoke.sh` passes with `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` exported.

---

## 10. Rollback

If login or admin access breaks:

1. In Cloudflare Zero Trust -> Access -> Applications, disable only:
   - `YourApp Keycloak Admin`
   - `YourApp Keycloak Master Realm`
2. Do not change Keycloak realm/client settings during the first rollback.
3. Confirm:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" \
     https://auth.yourapp.com/realms/yourapp-prod/.well-known/openid-configuration
   ```

4. Re-enable one Access application at a time and retest.

If the admin console loads but looks broken, check Cloudflare optimizations first: Rocket Loader, Auto Minify, bot challenges, and rate limits on `/resources/*`.
