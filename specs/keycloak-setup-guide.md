# Keycloak Setup From Scratch — Step-by-Step Guide

**Status:** Draft v3 (Cloud Run + realm foundation + MCP setup)
**Companion to:** `keycloak-operations-spec.md`, `KEYCLOAK_AUTH_PRD.md` (architecture / rationale), `KEYCLOAK_MCP_SPI_DESIGN.md` (SPI implementation)

> ## ⚠️ UI label accuracy disclaimer
>
> **The exact UI labels and navigation paths in this guide have not been verified against Keycloak 26.6.0.** Items I have lower confidence on are marked `[?]`, but the rest should also be treated as approximations until validated against your actual admin console.
>
> What's verified: the high-level architecture, what each step is *trying to achieve*, the API behavior the smoke tests check.
>
> What's not verified: exact button text, tab names, navigation paths, executor names, condition names, configuration field labels.
>
> **As you work through each step, if the UI shows something different from what's written here:**
> 1. Trust the UI.
> 2. Note the actual label you see.
> 3. Update this guide.
>
> The smoke tests in `./smoke.sh` are the authoritative check on whether the setup achieved the intended state — they query the admin REST API directly and don't depend on UI labels.

This guide covers infrastructure setup, realm foundation, and MCP-specific configuration. The PRD has the "what and why"; this guide has the "how." Where the two diverge, trust what your admin console actually shows and update this guide.

**Deployment paths** — pick one:

- **Option A — Cloud Run + Cloud SQL/Neon/Supabase. Recommended now.** Fastest time-to-market, native secrets integration, one-command deploys, minimal ops. Cold-start latency on first login of a session is the main trade-off; tolerable pre-PMF.
- **Option B — Hetzner VM + Docker Compose + managed Postgres. Recommended later.** When you have 3+ services that benefit from co-location (Keycloak + Elasticsearch + workers + Redis), the economics flip. Migrating Keycloak from Cloud Run to a VM later is hours, not a re-architecture.

Both assume: Keycloak `26.6.x` pinned, platform-managed TLS, realm names per ops spec (`yourapp-prod`, `yourapp-staging`, `yourapp-dev`), hostname `auth.yourapp.com`.

**Reading order:**
- Pre-flight (both options)
- Section A or Section B (infrastructure deployment)
- Section C (realm + IdP foundation)
- Section D (MCP-specific configuration; requires §C complete + MCP SPI image deployed per `KEYCLOAK_MCP_SPI_DESIGN.md`)
- Section E (verification checklist)

**STOP** = human action required.
**[?]** = best guess at exact UI label in 26.6.x — verify against your admin console.

---

## Pre-flight (both options)

1. **STOP — DNS access** for `auth.yourapp.com` confirmed.
2. **STOP — Google OAuth client** created at https://console.cloud.google.com/apis/credentials. Authorized redirect URIs: `https://auth.yourapp.com/realms/yourapp-{prod,staging,dev}/broker/google/endpoint`. Save Client ID + Secret.
3. **STOP — Microsoft Entra app registration** (multi-tenant): redirect URI `https://auth.yourapp.com/realms/yourapp-{env}/broker/microsoft-oidc/endpoint`, publisher domain `yourapp.com`. Save Client ID + Secret. See PRD §6.3, §11.9.
4. **STOP — GitHub OAuth app** created. Authorized callback URL: `https://auth.yourapp.com/realms/yourapp-{env}/broker/github/endpoint`. Save Client ID + Secret.
5. **STOP — Auth0 dashboard access + Management API access** confirmed (needed later for migration).
6. **STOP — GCP Secret Manager** chosen as secret store.
7. **Decide Postgres home** (Option A): Cloud SQL, Neon, or Supabase.
8. **For §D (MCP setup) only — STOP — MCP SPI build infrastructure** in place: repo scripts (`build.sh`, `push.sh`, `deploy.sh`, `test.sh`, `smoke.sh`), `src/providers/` Maven module per `KEYCLOAK_MCP_SPI_DESIGN.md`, the SPI JAR built and packaged into the custom Keycloak Docker image. Defer §D until §A or §B + §C is complete and the MCP SPI image is deployed.

---

# OPTION A: Cloud Run + Managed Postgres (Recommended Now)

## A.1 Project setup

```bash
gcloud config set project yourapp-prod-XXXXX
gcloud services enable run.googleapis.com sqladmin.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com
```

## A.2 Choose your Postgres

**A.2.1 Cloud SQL (recommended — tightest integration).** Native Cloud Run socket factory; no IP allowlisting needed.

```bash
gcloud sql instances create yourapp-keycloak \
  --database-version=POSTGRES_16 --tier=db-f1-micro \
  --region=us-central1 --storage-size=10GB --storage-type=SSD \
  --backup-start-time=03:00 --enable-point-in-time-recovery \
  --availability-type=zonal

gcloud sql databases create keycloak --instance=yourapp-keycloak

KC_DB_PASSWORD=$(openssl rand -base64 32)
echo -n "$KC_DB_PASSWORD" | gcloud secrets create keycloak-db-password --data-file=-
gcloud sql users create keycloak --instance=yourapp-keycloak --password="$KC_DB_PASSWORD"
```

Cost ~$10/mo at `db-f1-micro`. Bump if login latency suffers.

**A.2.2 Neon or Supabase.** If you already use one for the main app, create a *separate project* (not just a separate DB) so migrations can't touch app data. Connection over public TLS endpoint.

**On VPC/network isolation:** For Cloud Run → Cloud SQL, the native socket factory handles isolation; nothing more needed. For Cloud Run → Neon/Supabase, the connection goes over the public internet with TLS. This is **acceptable pre-PMF** given TLS-required connections, credentials in Secret Manager, and DB-side RLS/least-privilege. Add IP allowlisting (restricting DB to Cloud Run's egress IPs) as a Phase 4 hardening task. Full VPC peering / PrivateLink is overkill at this scale; defer until a real trigger (enterprise compliance, measurable latency problem, or a paid DB tier that bundles it).

## A.3 Secrets

```bash
echo -n "$(openssl rand -base64 32)" | gcloud secrets create keycloak-bootstrap-password --data-file=-
echo -n "YOUR_GOOGLE_CLIENT_SECRET" | gcloud secrets create google-oauth-client-secret --data-file=-
```

## A.4 Runtime service account

```bash
gcloud iam service-accounts create keycloak-runner --display-name="Keycloak Cloud Run runtime"
SA="keycloak-runner@$(gcloud config get-value project).iam.gserviceaccount.com"

for SECRET in keycloak-db-password keycloak-bootstrap-password google-oauth-client-secret; do
  gcloud secrets add-iam-policy-binding "$SECRET" \
    --member="serviceAccount:$SA" --role="roles/secretmanager.secretAccessor"
done

# Cloud SQL only
gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
  --member="serviceAccount:$SA" --role="roles/cloudsql.client"
```

## A.5 Deploy

```bash
PROJECT=$(gcloud config get-value project)
REGION=us-central1
SQL_CONN="$PROJECT:$REGION:yourapp-keycloak"

gcloud run deploy keycloak \
  --image=quay.io/keycloak/keycloak:26.6.0 \
  --region=$REGION --platform=managed \
  --service-account="keycloak-runner@$PROJECT.iam.gserviceaccount.com" \
  --add-cloudsql-instances="$SQL_CONN" \
  --port=8080 --cpu=2 --memory=2Gi \
  --min-instances=0 --max-instances=3 --timeout=300 \
  --args="start,--optimized" \
  --set-env-vars="KC_DB=postgres,KC_DB_URL=jdbc:postgresql:///keycloak?cloudSqlInstance=$SQL_CONN&socketFactory=com.google.cloud.sql.postgres.SocketFactory,KC_DB_USERNAME=keycloak,KC_HOSTNAME=auth.yourapp.com,KC_HOSTNAME_STRICT=true,KC_HTTP_ENABLED=true,KC_PROXY_HEADERS=xforwarded,KC_HEALTH_ENABLED=true,KC_METRICS_ENABLED=true,KC_BOOTSTRAP_ADMIN_USERNAME=admin" \
  --set-secrets="KC_DB_PASSWORD=keycloak-db-password:latest,KC_BOOTSTRAP_ADMIN_PASSWORD=keycloak-bootstrap-password:latest"
```

For Neon/Supabase, swap the JDBC URL: `jdbc:postgresql://HOST:5432/keycloak?sslmode=require`, drop `--add-cloudsql-instances`.

**`--min-instances=0`** is the pre-PMF default. Saves ~$15/mo at the cost of cold starts. Flip to `1` when users complain, first paying customer onboards, or cold-start frequency crosses what you can tolerate.

## A.6 Custom domain

```bash
gcloud run domain-mappings create --service=keycloak --domain=auth.yourapp.com --region=$REGION
```

**STOP** — add the printed DNS records. TLS is GCP-managed.

## A.7 First admin login + secure bootstrap

1. Browse `https://auth.yourapp.com/admin`, log in with bootstrap creds.
2. Create your real admin user in the master realm, assign `admin` role.
3. Log out, log back in as the real admin.
4. **STOP** — disable bootstrap admin.
5. Remove bootstrap env vars:
   ```bash
   gcloud run services update keycloak --region=$REGION \
     --remove-env-vars=KC_BOOTSTRAP_ADMIN_USERNAME \
     --remove-secrets=KC_BOOTSTRAP_ADMIN_PASSWORD
   ```

## A.8 Backups

Cloud SQL PITR is on. **STOP — test restore via clone within 7 days:**

```bash
gcloud sql instances clone yourapp-keycloak yourapp-keycloak-restore-test \
  --point-in-time="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
gcloud sql instances delete yourapp-keycloak-restore-test
```

For Neon/Supabase: verify provider backup schedule; test restore within 7 days.

Realm export to GCS as defense-in-depth: deferred follow-up.

## A.9 Iteration loop

```bash
# New Keycloak version:
gcloud run services update keycloak --region=$REGION --image=quay.io/keycloak/keycloak:26.6.1
# Env change:
gcloud run services update keycloak --region=$REGION --update-env-vars=KEY=value
# Rotate secret (latest version pulled on next cold start; force redeploy if env-mounted):
echo -n "new-value" | gcloud secrets versions add SECRET --data-file=-
```

Wire into a GitHub Actions workflow once Phase 1 of infra hardening (WIF) lands.

## A.10 Outgrowing Cloud Run

Triggers for Option B:
- 3+ services that would benefit from co-location.
- Cold starts become user-visible *and* `min-instances=1` costs more than a multi-service VM.
- You add Elasticsearch or another service that doesn't fit Cloud Run.

Migration when needed: export realms, stand up VM per Option B, import realms, repoint DNS. A couple of hours.

---

# OPTION B: Hetzner VM + Docker Compose (For Later)

Documented for forward reference.

## B.1 Provision

Hetzner CX22 (2 vCPU, 4 GB, ~€4.50/mo), Ubuntu 24.04. Bump to CX32+ before Elasticsearch joins. Assign static IPv4. **STOP** — create DNS A record.

## B.2 Harden

```bash
sudo apt update && sudo apt upgrade -y
sudo adduser yourapp --disabled-password --gecos ""
sudo usermod -aG sudo yourapp
sudo mkdir -p /home/yourapp/.ssh
sudo cp ~/.ssh/authorized_keys /home/yourapp/.ssh/
sudo chown -R yourapp:yourapp /home/yourapp/.ssh
sudo chmod 700 /home/yourapp/.ssh && sudo chmod 600 /home/yourapp/.ssh/authorized_keys
sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow OpenSSH && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw enable
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

Test SSH from a second terminal before closing the first.

## B.3 Install Docker

Official Docker repo, add `yourapp` to `docker` group. Standard. Log out and back in. Verify `docker run --rm hello-world`.

## B.4 Secrets pattern: fetch from GCP Secret Manager at boot

You don't need Nomad or Vault. ~30 min one-time setup.

1. Create a GCP service account with `roles/secretmanager.secretAccessor` only.
2. Generate a key, copy to VM at `/etc/yourapp/gcp-sa.json` (chmod 600, root).
3. Install gcloud, activate the service account.
4. Fetch script `/opt/yourapp/scripts/fetch-secrets.sh`:
   ```bash
   #!/bin/bash
   set -euo pipefail
   ENV_FILE=/opt/yourapp/.env
   umask 077
   {
     echo "KC_DB_HOST=$(gcloud secrets versions access latest --secret=keycloak-db-host)"
     echo "KC_DB_PASSWORD=$(gcloud secrets versions access latest --secret=keycloak-db-password)"
     echo "KC_BOOTSTRAP_ADMIN_USERNAME=admin"
     echo "KC_BOOTSTRAP_ADMIN_PASSWORD=$(gcloud secrets versions access latest --secret=keycloak-bootstrap-password)"
   } > "$ENV_FILE"
   chmod 600 "$ENV_FILE"
   chown root:docker "$ENV_FILE"
   ```
5. Systemd unit `/etc/systemd/system/yourapp-secrets.service` running this before docker-compose. Enable.

Rotation: update in Secret Manager → `sudo systemctl restart yourapp-secrets && docker compose up -d`.

This inherits GCP Secret Manager's audit, rotation, and IAM. Same secret store as Cloud Run uses; VM just fetches on boot.

## B.5 Layout

```bash
sudo mkdir -p /opt/yourapp && sudo chown yourapp:yourapp /opt/yourapp
cd /opt/yourapp && mkdir -p {keycloak,caddy,backups,scripts}
mkdir -p keycloak/{themes,providers} caddy/{data,config}
```

## B.6 Compose stack

`/opt/yourapp/docker-compose.yml`:

```yaml
name: yourapp-auth

services:
  caddy:
    image: caddy:2.8-alpine
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
    depends_on: [keycloak]

  keycloak:
    image: quay.io/keycloak/keycloak:26.6.0
    restart: unless-stopped
    command: start --optimized
    env_file: [.env]
    environment:
      KC_DB: postgres
      KC_DB_URL: "jdbc:postgresql://${KC_DB_HOST}:5432/keycloak?sslmode=require"
      KC_DB_USERNAME: keycloak
      KC_HOSTNAME: auth.yourapp.com
      KC_HOSTNAME_STRICT: "true"
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
      KC_HEALTH_ENABLED: "true"
      KC_METRICS_ENABLED: "true"
    volumes:
      - ./keycloak/themes:/opt/keycloak/themes
      - ./keycloak/providers:/opt/keycloak/providers
    expose: ["8080", "9000"]
    deploy:
      resources:
        limits: { memory: 1.5G }
        reservations: { memory: 768M }
```

`/opt/yourapp/caddy/Caddyfile`:

```
auth.yourapp.com {
    reverse_proxy keycloak:8080
    encode gzip
    log { output file /data/access.log; format json }
}
```

## B.7 First boot, first admin, backups

```bash
sudo systemctl start yourapp-secrets
docker compose up -d
docker compose logs -f keycloak
```

Then §A.7 conceptually for the admin bootstrap, and §A.8's equivalent for backups (managed Postgres provider's PITR + weekly realm export to GCS via cron).

## B.8 Adjacent containers later

Each new service under `/opt/yourapp/<service>/`, shared `yourapp-internal` Docker network, additional Caddy site blocks. Bump VM size before Elasticsearch. Keep memory limits explicit so neighbors can't starve Keycloak.

---

# SECTION C: Realm and Federation Configuration (Both Options)

Identical once Keycloak is reachable.

## C.1 Realms

Create `yourapp-prod`, `yourapp-staging`, `yourapp-dev` via admin console.

## C.2 Realm settings per realm

Per ops spec §3.3:
- Login → User registration: OFF.
- Login → Forgot password: ON for prod, OFF for dev.
- Security defenses → Brute Force Detection: ON, 5–10 failures.
- Tokens → Access token lifespan 5 min; SSO Session Idle 30 min; Max 10 hr.
- General → SSL required: External requests.

## C.3 Google federation per realm

Start with dev. Identity Providers → Add → Google. Alias `google` (exact). Client ID/Secret from pre-flight. First login flow: `first broker login`. Sync mode: `force`. Trust Email: ON. Test in incognito with a test Google account before replicating to staging/prod. Each realm needs its redirect URI registered in the Google OAuth client.

## C.4 OIDC clients

Per realm. Naming per PRD §10.8 conventions: `yourapp-{env}-{purpose}`.

- **`yourapp-{env}-web`** — confidential, standard flow only, PKCE-S256 required. Redirect URIs: `https://prod.yourapp.com/auth/callback` (prod) / equivalent per env. Backchannel logout URL: `/auth/backchannel-logout`. Web origin: `https://prod.yourapp.com` / per env. Copy secret to Secret Manager. See PRD §8.2.
- **`yourapp-{env}-admin-api`** — confidential, service accounts only, 8 realm-management roles per PRD §11.13: `view-users`, `manage-users`, `view-realm`, `view-clients`, `query-users`, `query-groups`, `view-identity-providers`, `manage-identity-providers`.
- **`yourapp-{env}-mcp-server`** — does **not** exist as a static client. MCP clients self-register via Dynamic Client Registration; see §D. The yourapp.com MCP server is a *resource server* identified by audience `yourapp-mcp-api`, not a Keycloak client.

## C.5 Verify minimal token shape

Per ops spec §4.5. Clients → `yourapp-web-ui` → Client scopes → Evaluate.

Must contain: `iss`, `sub`, `aud`, `azp`, `exp`, `iat`, `email`, `email_verified`, `preferred_username`.
Must NOT contain: `tenant`, `organization`, `roles`, `groups`.

If extras appear, remove the offending client scope or mapper. The minimal-token contract is what makes future IdP migration cheap; protect it.

---

# SECTION D: MCP Setup (Both Options)

Requires: §C complete, custom Keycloak image with the MCP SPI deployed (per `KEYCLOAK_MCP_SPI_DESIGN.md`), `YOURAPP_MCP_HANDOFF_HMAC_KEY` + `YOURAPP_WEB_HOST` env vars injected into the Keycloak runtime.

Setup ordering matters — later steps depend on earlier ones. Follow in sequence.

## D.1 Verify the SPI is loaded

Run `./smoke.sh`. Look at Test 14.

- **Green** → SPI loaded. Proceed.
- **Red** → SPI not loaded. Check Cloud Run startup logs: `./logs.sh | grep -i "yourapp\|spi\|provider\|exception"`. Common causes: META-INF/services file has wrong factory class name; JAR's Keycloak SDK version doesn't match the base image; `target/providers/` was empty at `docker build` time.

## D.2 Create the `browser-mcp-tenant-pick` authentication flow

**Path:** Authentication → Flows

1. Find `browser-federated-only` → row action menu → **Duplicate**.
2. Name the copy: `browser-mcp-tenant-pick`. Open it.
3. At the bottom of the flow, **Add step** [?]. In the picker, find **YourApp MCP Tenant Picker** [?] (or whatever display name your SPI's `AuthenticatorFactory.getDisplayType()` returns — search "yourapp" or "mcp").
4. Set the new step's requirement to **Required**.
5. Save.

**Verify:** `./smoke.sh` → Test 15 green.

## D.3 Create the six atomic `yourapp:*` Client Scopes

**Path:** Client scopes → **Create client scope** (repeat 6×)

Per scope:
- **Name:** as below
- **Type:** **None** [?] (don't auto-assign; the consent wizard explicitly grants them)
- **Protocol:** **OpenID Connect**
- **Display on consent screen:** **On**
- **Consent screen text:** as below
- **Include in token scope:** **On**

| Name | Consent screen text |
|---|---|
| `yourapp:read` | Read your resources |
| `yourapp:comment` | Comment on resources you have access to |
| `yourapp:curate` | Tag, link, and organize resources |
| `yourapp:write` | Create, edit, and delete resources |
| `yourapp:share` | Share resources with other users in this tenant |
| `yourapp:admin` | **Administer this tenant** (manage users, settings, audit) |

**Verify:** `./smoke.sh` → Test 16 green.

## D.4 Create the `mcp-default` Client Scope

**Path:** Client scopes → **Create client scope**

- **Name:** `mcp-default`
- **Description:** "Audience binding and tenant/scope claims for MCP clients"
- **Type:** **Default** [?] (so it can be assigned as realm-default in §D.7)
- **Protocol:** **OpenID Connect**
- **Display on consent screen:** **Off** (the consent wizard handles UX)
- **Include in token scope:** **Off** (we don't want `mcp-default` itself appearing as a scope value)

Save, then in the **Mappers** tab, add three mappers (§D.4a–c).

### D.4a Audience mapper

Add mapper → By configuration → **Audience**:
- **Name:** `mcp-default-audience`
- **Included Custom Audience:** `yourapp-mcp-api`
- **Add to access token:** **On**

### D.4b User Session Note mapper (`tenant` claim)

Add mapper → By configuration → **User Session Note**:
- **Name:** `mcp-default-tenant-claim`
- **User Session Note:** `yourapp_tenant_id`
- **Token Claim Name:** `tenant`
- **Claim JSON Type:** `String`
- **Add to ID token:** **On**
- **Add to access token:** **On**

### D.4c YourApp MCP Scope Override mapper (SPI's custom mapper)

Add mapper → By configuration → **YourApp MCP Scope Override** [?] (search "yourapp"):
- **Name:** `mcp-default-scope-override`
- No other configuration needed; the mapper hardcodes `yourapp_scopes` session note → `scope` claim. If you see additional fields with toggles for token targets, leave defaults — the mapper applies to access tokens unconditionally.

**Verify:** `./smoke.sh` → Tests 17 (and sub-checks) and 29 green.

## D.5 Client Registration Policies (legacy CRP)

**Path:** Realm settings → Client registration → Anonymous Access Policies [?]

The exact path in 26.6.x may differ — look for "Client registration" as a tab within Realm settings or a top-level sidebar item. Anonymous policies are the relevant scope.

Add each policy below: **Create policy** [?] → select provider → configure → save.

| Provider | Configuration |
|---|---|
| `allowed-client-scopes` | Whitelist: `openid`, `offline_access`, `profile`, `email`, `mcp-default`, all six `yourapp:*` scopes |
| `consent-required` | None (just create the entry — no fields) |
| `trusted-hosts` | Permissive initially; tighten with Cloudflare WAF rate limiting in front |
| `max-clients` | `10000` |

**Optional:** `allowed-protocol-mapper-types`. Skip for v1 — the security-critical mappers are attached to the `mcp-default` scope (not the client), so DCR'd clients can't override them. See PRD §16.4 for the rationale and full whitelist if you want belt-and-suspenders later.

**Verify:** `./smoke.sh` → Test 18 (some sub-checks may still red if other policies aren't configured here; that's expected).

## D.6 Client Policies (newer profile-based system)

**Path:** Realm settings → Client policies

Two parts: create a Profile of executors, then create a Policy with a condition that activates the profile.

### D.6a Profile `mcp-hardening`

Profiles tab → **Create profile** [?]:
- **Name:** `mcp-hardening`
- **Description:** "OAuth 2.1 hardening for DCR'd MCP clients"

After saving, the profile is editable. Add executors via **Add executor** [?].

The table below describes behaviors; match by description in your actual UI dropdown. Keycloak has renamed and split executors across versions; the names below are my best guess for 26.6.x. If your dropdown shows different exact labels, **trust the dropdown** and let me know so this guide can be corrected.

| Behavior | Likely UI name [?] | Configuration |
|---|---|---|
| Enforce PKCE on all requests | `pkce-enforcer` | Code Challenge Method: `S256` |
| Restrict response types to `code` only (forbid implicit) | `secure-response-type` | (default) |
| Force consent required | `consent-required` | (default) |
| Enforce HTTPS / secure redirect URIs | One of `secure-client-uris`, `secure-redirect-uri`, similar | (default) |
| Secure session binding | `secure-session` | (default) |
| Disable client full-scope access | `full-scope-disabled` | (default) |

Save.

### D.6b Policy `mcp-anonymous-dcr`

Policies tab → **Create policy** [?]:
- **Name:** `mcp-anonymous-dcr`
- **Description:** "Apply mcp-hardening to anonymously DCR'd clients"
- **Enabled:** **On**

Add condition: **Condition type:** `client-updater-context`. **Update Client Source:** `ByAnonymous`. (Other values like `ByAuthenticatedUser` exist for non-MCP clients — `ByAnonymous` matches DCR'd ones.)

Add profile reference: `mcp-hardening`.

Save.

**Verify:** Smoke tests 22, 23, 24 (DCR rejects bad inputs) exercise this indirectly after §D.12.

## D.7 Set realm-default Client Scopes

**Path:** Realm settings → Client scopes [?] (a tab within Realm settings, not the top-level Client scopes section)

Move to **Default Client Scopes** (auto-assigned to all new clients):
- `mcp-default`
- `yourapp:read`
- `yourapp:comment`
- `yourapp:curate`
- `yourapp:write`
- `yourapp:share`

Move to **Optional Client Scopes** (clients explicitly request):
- `yourapp:admin`

Save.

**Caveat:** these realm-defaults apply to all newly-created clients. The existing `yourapp-{env}-web` and `yourapp-{env}-admin-api` clients are unaffected. If you ever recreate them, manually remove the MCP scopes from their assignments.

## D.8 Bind the browser flow

Two options:

**Option A — set realm's default browser flow to `browser-mcp-tenant-pick`.** Affects all clients. The SPI Authenticator must short-circuit cleanly for non-MCP clients (those without `mcp-default` scope assigned).

**Path:** Authentication → Bindings → **Browser Flow:** `browser-mcp-tenant-pick`. Save.

**Verify the web client still works:** sign in to `https://prod.yourapp.com` in a fresh browser. If it breaks, switch to Option B.

**Option B — keep realm browser flow as `browser-federated-only`; post-process DCR'd clients in YourApp web.** YourApp web's `/mcp/consent` backend sets `authenticationFlowBindingOverrides.browser` on each DCR'd client at first-use via the Admin API. More surgical. No admin console action here; logic lives in YourApp web (`YOURAPP_WEB_MCP_ENDPOINTS.md`).

## D.9 OAuth 2.1 token settings

**Path:** Realm settings → Tokens

- **Revoke Refresh Token:** **On**
- **Refresh Token Max Reuse:** `0`
- Save.

**Verify:** `./smoke.sh` → Test 19 green.

## D.10 Disable Direct Grant flow (optional hardening)

**Path:** Authentication → Bindings

- **Direct Grant Flow:** unbind, or set to a flow that always fails. Save.

This prevents any client (including DCR'd ones) from using the password grant even if they request it.

**Verify:** `./smoke.sh` → Test 23 green.

## D.11 Verify HMAC handoff key is mounted

Should already be in place from image deploy. Sanity-check:

```bash
gcloud secrets describe yourapp-mcp-handoff-hmac-key-prod
gcloud run services describe keycloak --region=us-central1 \
  --format='value(spec.template.spec.containers[0].env[].valueFrom.secretKeyRef.name)' \
  | grep handoff
```

The same secret value must also be injected into YourApp web's runtime environment.

**Verify:** `./smoke.sh` → Test 20 green.

## D.12 Test DCR end-to-end

```bash
curl -X POST "https://auth.yourapp.com/realms/yourapp-prod/clients-registrations/openid-connect" \
  -H "Content-Type: application/json" \
  -d '{
    "client_name": "DCR smoke-test client",
    "redirect_uris": ["https://example.com/callback"],
    "grant_types": ["authorization_code", "refresh_token"],
    "token_endpoint_auth_method": "none",
    "scope": "openid yourapp:read yourapp:write"
  }'
```

Expected: **HTTP 201** with `client_id`, `registration_access_token`, `registration_client_uri` in the JSON. Save these for cleanup in §D.13.

Inspect the new client in the admin console:
- **Client Scopes** tab: Default = `mcp-default` + 5 author-bundle `yourapp:*` scopes; Optional = `yourapp:admin`
- **Settings** tab: PKCE method = S256; standard flow on; direct grants off
- **Advanced** tab (if D.8 Option A): browser flow override = `browser-mcp-tenant-pick`

**Verify:** Smoke Tests 21–25 green.

## D.13 Cleanup

```bash
curl -X DELETE "https://auth.yourapp.com/realms/yourapp-prod/clients-registrations/openid-connect/<client_id>" \
  -H "Authorization: Bearer <registration_access_token>"
```

Expected: **HTTP 204**.

**Verify:** `./smoke.sh` → Test 26 green.

## D.14 End-to-end MCP handoff test (manual; deferred)

Cannot run until YourApp web's `/mcp/consent` sub-app is deployed. When ready, run smoke Test 33 — the manual end-to-end walkthrough that exercises: federated IdP → silent OIDC bootstrap → 3-step consent wizard → picker-result handoff → Keycloak callback → access token. Decode the resulting access token and verify:
- `aud == "yourapp-mcp-api"`
- `tenant == <chosen tenant UUID>`
- `scope == <user's wizard selection>` (not the originally requested scopes — proves the scope override mapper works)

---

# SECTION E: Verification Checklist

## E.1 Infrastructure + realm foundation

- [ ] `https://auth.yourapp.com/` returns Keycloak welcome page with valid TLS.
- [ ] Real admin works; bootstrap admin disabled; bootstrap env vars removed.
- [ ] All three realms exist.
- [ ] Google federation works in `yourapp-dev` with a test account.
- [ ] Google federation configured in `yourapp-prod` (not yet tested with real users).
- [ ] Microsoft federation works in `yourapp-dev` with a work and a personal MSA account.
- [ ] GitHub federation works in `yourapp-dev`.
- [ ] `yourapp-{env}-web` and `yourapp-{env}-admin-api` clients in all three realms.
- [ ] Token contains only standard OIDC claims (per ops spec §4.5).
- [ ] Database backups configured; restore tested within 7 days.
- [ ] Brute force detection ON; user registration OFF in all realms.
- [ ] All secrets in Secret Manager.
- [ ] (Option B only) UFW enabled; SSH password auth disabled; unattended-upgrades enabled.
- [ ] DNS resolves; TLS valid.
- [ ] Uptime check hits `/realms/yourapp-prod/.well-known/openid-configuration`.
- [ ] Runbook in `/docs/ops/keycloak-runbook.md` covers chosen path, secrets location, admin access, credential rotation, restore, version upgrade.
- [ ] `./smoke.sh` Tests 1–13 all green.

## E.2 MCP setup

- [ ] MCP SPI image deployed to Cloud Run.
- [ ] `./smoke.sh` Test 14 green (SPI loaded).
- [ ] `browser-mcp-tenant-pick` flow exists with SPI Authenticator as Required final step (Test 15 green).
- [ ] All six `yourapp:*` atomic Client Scopes configured (Test 16 green).
- [ ] `mcp-default` Client Scope exists with three mappers: audience, tenant session note, scope override (Tests 17 and 29 green).
- [ ] Client Registration Policies configured: `allowed-client-scopes`, `consent-required`, `trusted-hosts`, `max-clients`.
- [ ] Client Policy profile `mcp-hardening` exists with PKCE + response type + consent + secure URI + secure session + full-scope-disabled executors.
- [ ] Client Policy `mcp-anonymous-dcr` exists with `client-updater-context: ByAnonymous` condition activating `mcp-hardening`.
- [ ] Realm-default Client Scopes set: `mcp-default` + Author bundle as Default; `yourapp:admin` as Optional.
- [ ] Browser flow binding configured (Option A: realm default = `browser-mcp-tenant-pick`, or Option B: post-DCR processing in YourApp web).
- [ ] Refresh token rotation enabled (Test 19 green).
- [ ] Direct Grant flow disabled (Test 23 green).
- [ ] HMAC handoff key present in Secret Manager (Test 20 green).
- [ ] Manual DCR test passes 201 with correct shape; cleanup successful (Tests 21–26 green).
- [ ] `./smoke.sh` Tests 14–29 all green.

## E.3 End-to-end (deferred until YourApp web `/mcp/consent` ready)

- [ ] Smoke Test 33 passes: full MCP handoff flow produces access token with correct `aud`, `tenant`, `scope` claims.

All §E.1 + §E.2 checked → realm-side MCP setup complete. Proceed to Auth0 → Keycloak migration in ops spec §10 (if not already done) and to YourApp web `/mcp/consent` implementation.

---

*End of Keycloak Setup Guide.*
