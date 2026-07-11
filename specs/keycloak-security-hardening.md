<!-- AGENT: Step-by-step operator hardening runbook for the public Knobby Keycloak endpoint. -->

# Keycloak Security Hardening Runbook

**Status:** operator action pending
**Last verified:** 2026-07-11
**Endpoint:** `https://auth.knobby.io`
**Primary realm:** `knobby-prod`
**Audience:** solo developer/operator, not a security team

This runbook is written for the current setup:

- One Cloudflare account.
- One Keycloak admin account.
- Keycloak admin account already has TOTP enabled.
- `auth.knobby.io` is a public hostname for Keycloak.
- You want normal app login/OIDC to keep working.

The goal is narrow:

1. Keep public `knobby-prod` OIDC endpoints public.
2. Put Cloudflare Access in front of Keycloak admin-only paths.
3. Keep Keycloak admin username/password and Keycloak TOTP exactly as they are.
4. Let `./smoke.sh` keep working by using a Cloudflare Access service token.

---

## 0. Read This First

### Do not create a Cloudflare SaaS application

For this task, the correct Cloudflare product is:

```text
Zero Trust -> Access controls -> Applications -> Create new application
-> Self-hosted and private -> Add public hostname
```

Do **not** choose **SaaS**.

A SaaS application is for using Cloudflare as an identity layer for third-party SaaS apps. That is not what this Keycloak deployment needs.

This Keycloak deployment needs a **self-hosted public hostname** Access application: Cloudflare sits in front of `auth.knobby.io` and decides whether a request to selected paths is allowed to reach the origin.

### Do not replace Keycloak login with Cloudflare login

Cloudflare Access is an outer gate. Keycloak admin login is still the inner gate.

After this guide, admin login should feel like this:

```text
Open https://auth.knobby.io/admin/master/console/
  -> Cloudflare Access asks for your email / one-time PIN
  -> Keycloak asks for your admin username/password
  -> Keycloak asks for your existing TOTP
  -> Keycloak admin console opens
```

That is intentional. Cloudflare does **not** mint the token that logs you into Keycloak admin. It only decides whether your browser can reach the admin path at all.

### What to keep enabled

Keep:

- Your Keycloak admin username/password.
- Your Keycloak admin TOTP.
- Your normal `knobby-prod` OIDC discovery, authorization, token, JWKS, and DCR endpoints.

Do not:

- Disable Keycloak admin login.
- Disable Keycloak TOTP.
- Configure Keycloak to trust a Cloudflare token as the Keycloak admin session.
- Put Cloudflare Access in front of all of `auth.knobby.io`.
- Protect `/resources/*`; Keycloak pages need static scripts and styles from there.

---

## 1. Cloudflare Identity Choice for a Solo Developer

For a solo setup, use Cloudflare Access **One-time PIN** first. It is simple and does not require Google Workspace, Microsoft Entra, Okta, or another identity provider.

Use this identity model:

| Layer | What authenticates you | Why it exists |
|---|---|---|
| Cloudflare Access | Email one-time PIN to your owner/admin email | Blocks anonymous scanners before they reach admin paths |
| Keycloak admin | Keycloak admin username/password | Actual Keycloak administrator identity |
| Keycloak admin MFA | Existing Keycloak TOTP | Inner MFA for privileged Keycloak actions |

Use the same email address you control for Cloudflare Access. It can be the same email you use for your Cloudflare account, but the important thing is that the Access policy allows only your exact email.

### Enable One-time PIN in Cloudflare

1. Open the Cloudflare dashboard.
2. Select your account.
3. Open **Zero Trust**.
4. In the left navigation, open **Integrations**.
5. Open **Identity providers**.
6. Under **Your identity providers**, select **Add new identity provider**.
7. Select **One-time PIN**.
8. Save the identity provider.

If Cloudflare asks you to configure an identity provider and you do not want to do that yet, use **One-time PIN**. Do not block this hardening task on SSO setup.

Later, if you add Google/Microsoft/GitHub login, that is fine. The rest of this guide stays the same.

---

## 2. Confirm Cloudflare Can Enforce on `auth.knobby.io`

Cloudflare Access only works when traffic passes through Cloudflare.

1. Open the Cloudflare dashboard.
2. Select the `knobby.io` website/zone.
3. Go to **DNS** -> **Records**.
4. Find the record for `auth.knobby.io`.

Required state:

| Field | Required value |
|---|---|
| Name | `auth` or `auth.knobby.io` |
| Type | usually `CNAME` |
| Proxy status | **Proxied** / orange cloud |

If the record is **DNS only** / grey cloud, Cloudflare Access will not protect the hostname.

### Disable Cloudflare page optimizations for Keycloak

Keycloak admin console is a JavaScript application. Do not let Cloudflare rewrite or optimize it.

For `auth.knobby.io`, turn these off:

| Feature | Required value |
|---|---|
| Rocket Loader | Off |
| Auto Minify JavaScript | Off |
| Auto Minify CSS | Off |
| Auto Minify HTML | Off |
| Zaraz | Off |
| APO / caching product features | Off |
| Broad bot/challenge rules | Off for `/resources/*`, normal OIDC paths, and admin login paths |

Keep proxying, TLS, and normal DDoS protection on.

---

## 3. Create the Human Admin Access Application

This protects browser access to admin-only Keycloak paths.

### 3.1 Start the application

1. Open the Cloudflare dashboard.
2. Open **Zero Trust**.
3. In the left navigation, open **Access controls**.
4. Open **Applications**.
5. Click **Create new application**.
6. Choose **Self-hosted and private**.
7. Click **Add public hostname**.

Do **not** choose **SaaS**.

### 3.2 Application basics

Use these values:

| Field | Value |
|---|---|
| Application name | `Knobby Keycloak Private Admin Surfaces` |
| Session duration | `8h` |
| Application launcher visibility | Off, if shown |

If Cloudflare asks for a logo, skip it.

### 3.3 Public hostnames / paths

Add these public hostname entries.

| Public hostname | Path |
|---|---|
| `auth.knobby.io` | `admin/*` |
| `auth.knobby.io` | `admin` |
| `auth.knobby.io` | `realms/master/*` |
| `auth.knobby.io` | `realms/master` |

Important path notes:

- Cloudflare's path examples do not use a leading slash. Enter `admin/*`, not `https://auth.knobby.io/admin/*`.
- If your Cloudflare UI automatically shows the slash, that is fine. The route should still mean `/admin/*`.
- The wildcard path `admin/*` protects child paths such as `/admin/master/console/`.
- Wildcards do not always protect the parent path. That is why this guide includes both `admin/*` and `admin`.
- Same for `realms/master/*` and `realms/master`.

If the UI only lets you add one hostname/path per application, create four Access applications with the same settings and the same policies:

1. `Knobby Keycloak Admin Wildcard` -> `auth.knobby.io` / `admin/*`
2. `Knobby Keycloak Admin Parent` -> `auth.knobby.io` / `admin`
3. `Knobby Keycloak Master Wildcard` -> `auth.knobby.io` / `realms/master/*`
4. `Knobby Keycloak Master Parent` -> `auth.knobby.io` / `realms/master`

Using one application with four public hostnames is easier to maintain, but either shape is acceptable.

### 3.4 Human allow policy

Add a policy to the application.

Use:

| Field | Value |
|---|---|
| Policy name | `allow-owner-email` |
| Action | `Allow` |
| Include selector | `Emails` |
| Include value | `<your exact owner/admin email>` |
| Require | Empty for now |
| Exclude | Empty |

For the login method, select **One-time PIN** if the UI asks which identity provider applies to the app.

If the UI offers **Instant Auth**, turn it on. With only one login method, this avoids an extra provider selection screen.

If the UI offers **Independent MFA**, leave it off for now. Your Keycloak admin account already has TOTP. You can add Cloudflare-side MFA later after the basic gate is working.

### 3.5 What not to add

Do not add:

- A `Bypass` policy.
- `Everyone`.
- A whole email domain such as `*@knobby.io`.
- Country-only access as the only control.
- Device posture/WARP requirements unless you already use WARP and know it works.

For a solo developer, exact email allowlisting is enough for this first hardening pass.

---

## 4. Test Browser Admin Access

Use a private/incognito browser window so old cookies do not hide mistakes.

Open:

```text
https://auth.knobby.io/admin/master/console/
```

Expected sequence:

1. Cloudflare Access appears first and asks for your email/one-time PIN.
2. After Cloudflare Access succeeds, Keycloak admin login appears.
3. After Keycloak admin login, Keycloak TOTP still appears.
4. The admin console loads.

Bad results and fixes:

| Result | Likely cause | Fix |
|---|---|---|
| You go straight to Keycloak admin without Cloudflare Access | DNS is grey-cloud/DNS-only, or path is wrong | Set `auth.knobby.io` to Proxied and recheck `admin/*` |
| You cannot load Keycloak styles/scripts | You protected `/resources/*` or enabled aggressive challenges | Remove `/resources/*` from Access/challenge rules |
| Admin console loads blank or broken | Cloudflare optimization rewrote JS/CSS | Turn off Rocket Loader, Auto Minify, Zaraz, APO for `auth.knobby.io` |
| You pass Cloudflare but Keycloak rejects login | This is a Keycloak credential/TOTP issue, not Cloudflare | Use the normal Keycloak admin recovery path |

Now test the master realm URL in a new incognito window:

```text
https://auth.knobby.io/realms/master/.well-known/openid-configuration
```

Expected:

- Cloudflare Access appears first, or Cloudflare blocks the request.
- Anonymous public users should not get raw JSON for the `master` realm.

---

## 5. Confirm Public OIDC Still Works

These paths must remain public. Do not put Access in front of them.

Run:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://auth.knobby.io/realms/knobby-prod/.well-known/openid-configuration
```

Expected:

```text
200
```

Run:

```bash
curl -i 'https://auth.knobby.io/realms/knobby-prod/protocol/openid-connect/auth'
```

Expected:

- A Keycloak/OIDC response.
- Usually `400` because OAuth parameters are missing.
- Not a Cloudflare Access login page.
- Not a Cloudflare Access 403.

Run:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://auth.knobby.io/resources/
```

Expected:

- Any normal Keycloak response such as `200`, `301`, `302`, or `404` is acceptable.
- A Cloudflare Access login page is not acceptable for `/resources/*`.

---

## 6. Add a Cloudflare Access Service Token for Smoke Tests

`./smoke.sh` calls Keycloak Admin REST endpoints under:

```text
/admin/realms/<realm>/...
```

After `/admin/*` is protected, smoke tests need a machine credential for the Cloudflare outer gate.

Use a Cloudflare Access **service token**. Do not use a broad bypass policy.

### 6.1 Create the service token

1. Open Cloudflare **Zero Trust**.
2. Open **Access controls**.
3. Open **Service credentials**.
4. Open **Service Tokens**.
5. Click **Create Service Token**.
6. Name it:

   ```text
   knobby-keycloak-smoke
   ```

7. Set a reasonable expiration. For now, use 1 year and calendar a rotation.
8. Copy the generated **Client ID** and **Client Secret** immediately.

The Client Secret is only shown once.

### 6.2 Allow the service token on the Access application

Go back to the `Knobby Keycloak Private Admin Surfaces` Access application.

Add a second policy:

| Field | Value |
|---|---|
| Policy name | `allow-smoke-service-token` |
| Action | `Service Auth` |
| Include selector | `Service Token` |
| Include value | `knobby-keycloak-smoke` |

Policy order should not matter for the simple setup, but keep both policies:

1. `allow-smoke-service-token` with action `Service Auth`.
2. `allow-owner-email` with action `Allow`.

Do not replace the human allow policy with the service-token policy. You need both.

### 6.3 Store the service token in Secret Manager

Use names that make the secret purpose obvious:

```text
knobby-cloudflare-access-smoke-client-id-prod
knobby-cloudflare-access-smoke-client-secret-prod
```

Create them:

```bash
printf '%s' '<cloudflare-access-client-id>' \
  | gcloud secrets create knobby-cloudflare-access-smoke-client-id-prod \
      --replication-policy=automatic \
      --data-file=-

printf '%s' '<cloudflare-access-client-secret>' \
  | gcloud secrets create knobby-cloudflare-access-smoke-client-secret-prod \
      --replication-policy=automatic \
      --data-file=-
```

If the secrets already exist, add new versions instead:

```bash
printf '%s' '<cloudflare-access-client-id>' \
  | gcloud secrets versions add knobby-cloudflare-access-smoke-client-id-prod \
      --data-file=-

printf '%s' '<cloudflare-access-client-secret>' \
  | gcloud secrets versions add knobby-cloudflare-access-smoke-client-secret-prod \
      --data-file=-
```

Do not paste either value into this repository.

### 6.4 Run smoke tests with the service token

Export the Keycloak admin API secret and the Cloudflare Access service token:

```bash
export KNOBBY_ENV=prod

export ADMIN_CLIENT_SECRET="$(gcloud secrets versions access latest \
  --secret=knobby-keycloak-admin-api-client-secret-prod)"

export CF_ACCESS_CLIENT_ID="$(gcloud secrets versions access latest \
  --secret=knobby-cloudflare-access-smoke-client-id-prod)"

export CF_ACCESS_CLIENT_SECRET="$(gcloud secrets versions access latest \
  --secret=knobby-cloudflare-access-smoke-client-secret-prod)"

./smoke.sh
```

`smoke.sh` also accepts these longer aliases:

```text
CLOUDFLARE_ACCESS_CLIENT_ID
CLOUDFLARE_ACCESS_CLIENT_SECRET
```

When the env vars are present, the script sends:

```text
CF-Access-Client-Id: <service-token-client-id>
CF-Access-Client-Secret: <service-token-client-secret>
```

The script does not print the secret.

### 6.5 Quick service-token curl test

Run:

```bash
curl -i \
  -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
  https://auth.knobby.io/admin/master/console/ \
  | sed -n '1,25p'
```

Expected:

- A Keycloak response or redirect.
- Not a Cloudflare Access login page.
- Not a Cloudflare Access 403.

If this fails but browser login works, the service-token policy is missing or attached to the wrong Access application/path.

---

## 7. Keycloak Web Origins

This section is separate from Cloudflare Access.

Cloudflare Access protects admin-only paths. Keycloak Web Origins controls which browser origins Keycloak will answer with CORS headers for first-party web clients.

### 7.1 Configure `knobby-prod-web`

Path:

```text
Keycloak admin console -> realm knobby-prod -> Clients -> knobby-prod-web -> Settings
```

Set:

| Field | Value |
|---|---|
| Valid redirect URIs | `https://prod.knobby.io/auth/callback` |
| Valid post logout redirect URIs | `https://prod.knobby.io/` |
| Web origins | `https://prod.knobby.io` |
| Standard flow | On |
| Direct access grants | Off |
| Implicit flow | Off |

Do not use:

- `*`
- `https://*.knobby.io`
- `+` in prod if the UI lets you enter the explicit origin instead
- localhost origins in prod

### 7.2 Configure `knobby-dev-web`

Path:

```text
Keycloak admin console -> realm knobby-dev -> Clients -> knobby-dev-web -> Settings
```

Set:

| Field | Value |
|---|---|
| Valid redirect URIs | `https://dev.knobby.io/auth/callback` |
| Valid post logout redirect URIs | `https://dev.knobby.io/` |
| Web origins | `https://dev.knobby.io` |
| Standard flow | On |
| Direct access grants | Off |
| Implicit flow | Off |

For local development only, add local origins to dev or test realms:

```text
http://localhost:3000
http://localhost:5173
```

Only add local ports the app actually uses.

### 7.3 Do not casually edit built-in Keycloak clients

Avoid changing:

- `security-admin-console`
- `account-console`
- `broker`
- `realm-management`

Those are built-in Keycloak clients. The admin/master public-exposure issue is handled at Cloudflare, not by trying to surgically rewrite Keycloak's internal console clients.

---

## 8. Verification Commands

### 8.1 Admin path must be gated

Run from a terminal that is not carrying browser cookies:

```bash
curl -i https://auth.knobby.io/admin/master/console/ | sed -n '1,25p'
```

Good:

- `302` redirect to Cloudflare Access.
- `403` from Cloudflare Access.
- HTML clearly from Cloudflare Access.

Bad:

- `200` with Keycloak admin console HTML.

### 8.2 Master realm must be gated

Run:

```bash
curl -i https://auth.knobby.io/realms/master/.well-known/openid-configuration \
  | sed -n '1,25p'
```

Good:

- `302` to Cloudflare Access.
- `403` from Cloudflare Access.
- Cloudflare Access login HTML.

Bad:

- `200` with JSON containing:

  ```text
  "issuer":"https://auth.knobby.io/realms/master"
  ```

### 8.3 Public prod discovery must stay public

Run:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  https://auth.knobby.io/realms/knobby-prod/.well-known/openid-configuration
```

Expected:

```text
200
```

### 8.4 Admin REST evil-origin preflight must not reach raw Keycloak

Run:

```bash
curl -i -X OPTIONS \
  'https://auth.knobby.io/admin/realms/knobby-prod/users' \
  -H 'Origin: https://evil.example.com' \
  -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: authorization' \
  | sed -n '1,40p'
```

Good:

- Cloudflare Access blocks, challenges, or redirects.
- You do not see a normal Keycloak `204`/`200` preflight response.

Bad:

```text
access-control-allow-origin: https://evil.example.com
access-control-allow-credentials: true
```

on a normal Keycloak response from `/admin/realms/...`.

### 8.5 Token endpoint CORS probe

Run:

```bash
curl -i -X OPTIONS \
  'https://auth.knobby.io/realms/knobby-prod/protocol/openid-connect/token' \
  -H 'Origin: https://evil.example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type' \
  | sed -n '1,40p'
```

Preferred:

- No `access-control-allow-origin: https://evil.example.com`.

If Keycloak still reflects the evil origin here, record it as residual Keycloak behavior and do not immediately add Cloudflare response-header rewrites. Token endpoint CORS is easy to break. The higher-risk admin path is already protected by Access.

### 8.6 Real app login still works

Open:

```text
https://prod.knobby.io
```

Expected:

- Normal app login works.
- Normal redirect to/from `auth.knobby.io/realms/knobby-prod/...` works.
- No Cloudflare Access prompt appears during normal app login.

---

## 9. Final Checklist

Mark this done only when all are true:

- [ ] `auth.knobby.io` DNS record is Proxied / orange cloud.
- [ ] Rocket Loader, Auto Minify, Zaraz, and APO are off for `auth.knobby.io`.
- [ ] Access application uses **Self-hosted and private -> Add public hostname**.
- [ ] No Cloudflare SaaS application was created for Keycloak.
- [ ] `auth.knobby.io` + `admin/*` is protected.
- [ ] `auth.knobby.io` + `admin` is protected.
- [ ] `auth.knobby.io` + `realms/master/*` is protected.
- [ ] `auth.knobby.io` + `realms/master` is protected.
- [ ] Human policy allows only your exact owner/admin email.
- [ ] One-time PIN is enabled as the Access login method.
- [ ] No broad `Bypass` policy exists.
- [ ] `knobby-keycloak-smoke` service token exists.
- [ ] Service-token policy is attached to the same Access app/path(s).
- [ ] Incognito `/admin/master/console/` shows Cloudflare Access before Keycloak.
- [ ] After Cloudflare Access, Keycloak still requires admin login and TOTP.
- [ ] Incognito `/realms/master/.well-known/openid-configuration` is blocked or gated.
- [ ] `knobby-prod` OIDC discovery still returns `200`.
- [ ] `prod.knobby.io` login still works.
- [ ] `knobby-prod-web` Web Origins is exactly `https://prod.knobby.io`.
- [ ] Dev/localhost Web Origins exist only in dev/test realms.
- [ ] Admin REST evil-origin preflight is blocked by Cloudflare Access.
- [ ] `./smoke.sh` passes with `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET` exported.

---

## 10. Rollback

If normal app login breaks:

1. In Cloudflare Zero Trust, open **Access controls** -> **Applications**.
2. Disable only the Keycloak Access application(s) created in this runbook.
3. Do not change Keycloak client settings during the first rollback.
4. Confirm public discovery is back:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" \
     https://auth.knobby.io/realms/knobby-prod/.well-known/openid-configuration
   ```

5. Re-enable one path at a time and retest.

If the admin console loads but looks broken:

1. Leave the Access application enabled.
2. Check Cloudflare optimizations first:
   - Rocket Loader
   - Auto Minify
   - Zaraz
   - APO/caching
   - broad challenge/bot rules
3. Confirm `/resources/*` is not protected by Access.

---

## 11. References Checked

Cloudflare documentation checked on 2026-07-11:

- `https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/`
- `https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/`
- `https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/`
- `https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/one-time-pin/`
