# Keycloak Setup From Scratch — Step-by-Step Guide

**Status:** Draft v2 (Cloud Run first; VM path retained as later option)
**Companion to:** `keycloak-operations-spec.md`

This guide covers two deployment paths. Pick one.

- **Option A — Cloud Run + Cloud SQL/Neon/Supabase. Recommended now.** Fastest time-to-market, native secrets integration, one-command deploys, minimal ops. Cold-start latency on first login of a session is the main trade-off; tolerable pre-PMF.
- **Option B — Hetzner VM + Docker Compose + managed Postgres. Recommended later.** When you have 3+ services that benefit from co-location (Keycloak + Elasticsearch + workers + Redis), the economics flip. Migrating Keycloak from Cloud Run to a VM later is hours, not a re-architecture.

Both assume: Keycloak `26.6.x` pinned, platform-managed TLS, realm names per ops spec (`knobby-prod`, `knobby-staging`, `knobby-dev`), hostname `auth.knobby.io`.

**STOP** = human action required.

---

## Pre-flight (both options)

1. **STOP — DNS access** for `auth.knobby.io` confirmed.
2. **STOP — Google OAuth client** created at https://console.cloud.google.com/apis/credentials. Authorized redirect URIs: `https://auth.knobby.io/realms/knobby-{prod,staging,dev}/broker/google/endpoint`. Save Client ID + Secret.
3. **STOP — Auth0 dashboard access + Management API access** confirmed (needed later for migration).
4. **STOP — GCP Secret Manager** chosen as secret store.
5. **Decide Postgres home** (Option A): Cloud SQL, Neon, or Supabase.

---

# OPTION A: Cloud Run + Managed Postgres (Recommended Now)

## A.1 Project setup

```bash
gcloud config set project knobby-prod-XXXXX
gcloud services enable run.googleapis.com sqladmin.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com
```

## A.2 Choose your Postgres

**A.2.1 Cloud SQL (recommended — tightest integration).** Native Cloud Run socket factory; no IP allowlisting needed.

```bash
gcloud sql instances create knobby-keycloak \
  --database-version=POSTGRES_16 --tier=db-f1-micro \
  --region=us-central1 --storage-size=10GB --storage-type=SSD \
  --backup-start-time=03:00 --enable-point-in-time-recovery \
  --availability-type=zonal

gcloud sql databases create keycloak --instance=knobby-keycloak

KC_DB_PASSWORD=$(openssl rand -base64 32)
echo -n "$KC_DB_PASSWORD" | gcloud secrets create keycloak-db-password --data-file=-
gcloud sql users create keycloak --instance=knobby-keycloak --password="$KC_DB_PASSWORD"
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
SQL_CONN="$PROJECT:$REGION:knobby-keycloak"

gcloud run deploy keycloak \
  --image=quay.io/keycloak/keycloak:26.6.0 \
  --region=$REGION --platform=managed \
  --service-account="keycloak-runner@$PROJECT.iam.gserviceaccount.com" \
  --add-cloudsql-instances="$SQL_CONN" \
  --port=8080 --cpu=2 --memory=2Gi \
  --min-instances=0 --max-instances=3 --timeout=300 \
  --args="start,--optimized" \
  --set-env-vars="KC_DB=postgres,KC_DB_URL=jdbc:postgresql:///keycloak?cloudSqlInstance=$SQL_CONN&socketFactory=com.google.cloud.sql.postgres.SocketFactory,KC_DB_USERNAME=keycloak,KC_HOSTNAME=auth.knobby.io,KC_HOSTNAME_STRICT=true,KC_HTTP_ENABLED=true,KC_PROXY_HEADERS=xforwarded,KC_HEALTH_ENABLED=true,KC_METRICS_ENABLED=true,KC_BOOTSTRAP_ADMIN_USERNAME=admin" \
  --set-secrets="KC_DB_PASSWORD=keycloak-db-password:latest,KC_BOOTSTRAP_ADMIN_PASSWORD=keycloak-bootstrap-password:latest"
```

For Neon/Supabase, swap the JDBC URL: `jdbc:postgresql://HOST:5432/keycloak?sslmode=require`, drop `--add-cloudsql-instances`.

**`--min-instances=0`** is the pre-PMF default. Saves ~$15/mo at the cost of cold starts. Flip to `1` when users complain, first paying customer onboards, or cold-start frequency crosses what you can tolerate.

## A.6 Custom domain

```bash
gcloud run domain-mappings create --service=keycloak --domain=auth.knobby.io --region=$REGION
```

**STOP** — add the printed DNS records. TLS is GCP-managed.

## A.7 First admin login + secure bootstrap

1. Browse `https://auth.knobby.io/admin`, log in with bootstrap creds.
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
gcloud sql instances clone knobby-keycloak knobby-keycloak-restore-test \
  --point-in-time="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
gcloud sql instances delete knobby-keycloak-restore-test
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
sudo adduser knobby --disabled-password --gecos ""
sudo usermod -aG sudo knobby
sudo mkdir -p /home/knobby/.ssh
sudo cp ~/.ssh/authorized_keys /home/knobby/.ssh/
sudo chown -R knobby:knobby /home/knobby/.ssh
sudo chmod 700 /home/knobby/.ssh && sudo chmod 600 /home/knobby/.ssh/authorized_keys
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

Official Docker repo, add `knobby` to `docker` group. Standard. Log out and back in. Verify `docker run --rm hello-world`.

## B.4 Secrets pattern: fetch from GCP Secret Manager at boot

You don't need Nomad or Vault. ~30 min one-time setup.

1. Create a GCP service account with `roles/secretmanager.secretAccessor` only.
2. Generate a key, copy to VM at `/etc/knobby/gcp-sa.json` (chmod 600, root).
3. Install gcloud, activate the service account.
4. Fetch script `/opt/knobby/scripts/fetch-secrets.sh`:
   ```bash
   #!/bin/bash
   set -euo pipefail
   ENV_FILE=/opt/knobby/.env
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
5. Systemd unit `/etc/systemd/system/knobby-secrets.service` running this before docker-compose. Enable.

Rotation: update in Secret Manager → `sudo systemctl restart knobby-secrets && docker compose up -d`.

This inherits GCP Secret Manager's audit, rotation, and IAM. Same secret store as Cloud Run uses; VM just fetches on boot.

## B.5 Layout

```bash
sudo mkdir -p /opt/knobby && sudo chown knobby:knobby /opt/knobby
cd /opt/knobby && mkdir -p {keycloak,caddy,backups,scripts}
mkdir -p keycloak/{themes,providers} caddy/{data,config}
```

## B.6 Compose stack

`/opt/knobby/docker-compose.yml`:

```yaml
name: knobby-auth

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
      KC_HOSTNAME: auth.knobby.io
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

`/opt/knobby/caddy/Caddyfile`:

```
auth.knobby.io {
    reverse_proxy keycloak:8080
    encode gzip
    log { output file /data/access.log; format json }
}
```

## B.7 First boot, first admin, backups

```bash
sudo systemctl start knobby-secrets
docker compose up -d
docker compose logs -f keycloak
```

Then §A.7 conceptually for the admin bootstrap, and §A.8's equivalent for backups (managed Postgres provider's PITR + weekly realm export to GCS via cron).

## B.8 Adjacent containers later

Each new service under `/opt/knobby/<service>/`, shared `knobby-internal` Docker network, additional Caddy site blocks. Bump VM size before Elasticsearch. Keep memory limits explicit so neighbors can't starve Keycloak.

---

# SECTION C: Realm and Federation Configuration (Both Options)

Identical once Keycloak is reachable.

## C.1 Realms

Create `knobby-prod`, `knobby-staging`, `knobby-dev` via admin console.

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

Per realm:
- **`knobby-web-ui`** — confidential, standard flow only. Redirect URI: `https://app.knobby.io/auth/callback`. Web origin: `https://app.knobby.io`. Copy secret to Secret Manager.
- **`knobby-backend-api`** — confidential, service accounts only. Backend JWT validation uses public JWKS; no secret required for that path.
- **`knobby-mcp-server`** — deferred to Layer 1 MCP work; uses Dynamic Client Registration.

## C.5 Verify minimal token shape

Per ops spec §4.5. Clients → `knobby-web-ui` → Client scopes → Evaluate.

Must contain: `iss`, `sub`, `aud`, `azp`, `exp`, `iat`, `email`, `email_verified`, `preferred_username`.
Must NOT contain: `tenant`, `organization`, `roles`, `groups`.

If extras appear, remove the offending client scope or mapper. The minimal-token contract is what makes future IdP migration cheap; protect it.

---

# SECTION D: Verification Checklist

- [ ] `https://auth.knobby.io/` returns Keycloak welcome page with valid TLS.
- [ ] Real admin works; bootstrap admin disabled; bootstrap env vars removed.
- [ ] All three realms exist.
- [ ] Google federation works in `knobby-dev` with a test account.
- [ ] Google federation configured in `knobby-prod` (not yet tested with real users).
- [ ] `knobby-web-ui` and `knobby-backend-api` clients in all three realms.
- [ ] Token contains only standard OIDC claims.
- [ ] Database backups configured; restore tested within 7 days.
- [ ] Brute force detection ON; user registration OFF in all realms.
- [ ] All secrets in Secret Manager.
- [ ] (Option B) UFW enabled; SSH password auth disabled; unattended-upgrades enabled.
- [ ] DNS resolves; TLS valid.
- [ ] Uptime check hits `/realms/knobby-prod/.well-known/openid-configuration`.
- [ ] Runbook in `/docs/ops/keycloak-runbook.md` covers chosen path, secrets location, admin access, credential rotation, restore, version upgrade.

All checked → proceed to Auth0 → Keycloak migration in ops spec §10.

---

*End of Keycloak Setup Guide.*
