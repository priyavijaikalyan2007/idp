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

### A.2.3 ⚠️ Supabase connection mode for Keycloak (critical — read before deploying)

> **This bit us in production (yourapp-prod, 2026-07-03) and cost a long debugging session.** Getting it wrong produces *intermittent* HTTP 500s on the token endpoint that cascade into user logouts, session-timing weirdness, and flaky admin pages — all of which look like app or realm bugs but are actually a DB connection-mode problem.

**Root cause.** Keycloak (via the PostgreSQL JDBC driver) uses **server-side named prepared statements** (`S_849`, `S_2`, …). A named prepared statement lives on **one physical Postgres connection**. Supabase's **transaction-mode pooler** (PgBouncer, pooler host on port **6543**) hands each statement a *different* backend connection, so Keycloak prepares a statement on connection A and executes it on connection B → `ERROR: prepared statement "S_849" does not exist` → `XA_RBROLLBACK` → **HTTP 500 on `/token`**. It's intermittent (only fails when the pool routes the execute elsewhere), which is what makes it so confusing.

**Supabase connection options and how they interact with Cloud Run:**

| Endpoint | Port | Prepared statements | Cloud Run reachable? |
|---|---|---|---|
| Transaction pooler | 6543 | **Broken** (per-statement pooling) | Yes (IPv4) — but breaks Keycloak |
| **Session pooler** | **5432** | **OK** (one conn per session) | **Yes (IPv4) — use this on Cloud Run** |
| Direct (`db.<ref>.supabase.co`) | 5432 | OK | **No** — IPv6-only; Cloud Run has no native outbound IPv6 |

**Required `KC_DB_URL` on Cloud Run (session-mode pooler + prepared statements disabled):**
```
jdbc:postgresql://<region>.pooler.supabase.com:5432/postgres?sslmode=require&prepareThreshold=0
```
- **Port 5432 on the pooler host** = session mode (prepared statements survive). Do **not** use 6543.
- **`&prepareThreshold=0`** = belt-and-suspenders; tells PgJDBC to never use server-side named prepared statements, so nothing can go missing even under pooling surprises. Safe to keep permanently; negligible overhead on a low-traffic IdP DB.
- Note the **`&`** (not `?`) joining the second param, since `?sslmode=require` is already present.
- The correct param is **`prepareThreshold`**, not `prepareMode` (the latter is silently ignored).
- Keep DB credentials in `KC_DB_USERNAME` / `KC_DB_PASSWORD` (env var / Secret Manager). Do **not** put `user=`/`password=` in the URL query string, even though Supabase's copy-paste URL does.

⚠️ **Do not use the direct connection on Cloud Run.** `db.<ref>.supabase.co` is IPv6-only unless you buy Supabase's IPv4 add-on, and Cloud Run egresses IPv4-only unless you build Direct VPC egress on a dual-stack subnet (custom VPC + dual-stack subnet + egress routing + elevated cold-start latency — far too much for a low-traffic IdP). The session-mode pooler exists precisely to give you IPv4 reachability; use it.

### A.2.3.1 Connection pool sizing (the second half of the Supabase gotcha)

> **Also observed in production (2026-07-04):** after switching to the session-mode pooler, Keycloak became **unusually slow** and scheduled tasks failed with `Acquisition timeout while waiting for new connection` (Agroal pool exhaustion). This is the *counterpart* to the prepared-statement issue — same root theme (Keycloak's pooling assumptions vs. Supabase's pooler), different symptom.

**Why it happens.** Session-mode pooling holds one Supabase backend connection per Keycloak connection for the connection's whole lifetime. Keycloak's Agroal pool defaults to a **max size of 100**. Supabase's session pooler grants far fewer connections per project (tier-dependent, often ~15–30). So Agroal tries to open more connections than Supabase will grant; the excess block until they time out → `Acquisition timeout` → every request queues behind connection acquisition → slowness and failing scheduled tasks (`ClearExpiredEvents`, session purge).

**Fix — cap Agroal below Supabase's pooler limit.** A single-instance IdP needs very few connections:
```yaml
- name: KC_DB_POOL_INITIAL_SIZE
  value: "2"
- name: KC_DB_POOL_MIN_SIZE
  value: "2"
- name: KC_DB_POOL_MAX_SIZE
  value: "8"      # nano tier (Supabase pool size 15); leave ~half as headroom
```

**Supabase gives two limits — know which one binds.** *Pool size* (nano: **15**) = the pooler's connections to Postgres backends, **shared across everything through the pooler**. *Max client connections* (nano: **200**) = how many clients may connect to the pooler — generous, you won't hit it. **Keycloak is constrained by pool size (15), not max client connections.**

⚠️ **Shared vs. dedicated project.** If yourapp.com's app and Keycloak use the **same** Supabase project, they **share** the 15 backend connections — budget both under 15 combined (give Keycloak ~5, the app the rest). If they're **separate** projects, Keycloak has its own 15 and can use ~8.

> **yourapp-prod topology (confirmed):** the app and Keycloak are **separate Supabase projects** in the same account — app in **Mumbai (ap-south-1)**, Keycloak DB in **Singapore (asia-southeast-1)**. They therefore have **independent poolers and independent 15-connection budgets** — no sharing. `KC_DB_POOL_MAX_SIZE = 8` is correct for Keycloak's dedicated project; the app's connection budget is a separate concern against its own pooler. (Note the cross-region hop: Keycloak on Cloud Run reaching a Singapore DB adds some latency vs. co-locating them; fine at current scale, worth revisiting if DB latency ever shows up in login timing.)

**Budget invariant (re-check whenever any variable changes):**
> **(Keycloak instances) × `KC_DB_POOL_MAX_SIZE`  +  (app's total connections)  <  Supabase pool size**

Violating it either way reproduces the failures you've seen: pool too big → `Acquisition timeout`; overcorrected → starvation under load. Re-check this inequality whenever you scale Keycloak horizontally, resize the Supabase tier, or migrate Keycloak off the pooler.

**Scaling reference (so future resizing isn't a guessing game):**

| Supabase tier | Pool size | KC instances | `KC_DB_POOL_MAX_SIZE` / instance | Notes |
|---|---|---|---|---|
| **Nano (current)** | 15 | 1 | **8** (5 if shared with app) | You are here |
| Small | ~15–30 | 1 | 10–15 | Raise with pool size |
| Medium | ~30–60 | 1–2 | 15–20 | 2 instances → each ≤ pool/2 + headroom |
| Large / Pro | 60–200 | 2–3 | 20–30 | Σ(instances × max) < pool size |

Rule of thumb: `KC_DB_POOL_MAX_SIZE` ≈ **50–66% of Supabase pool size** for a dedicated single-instance project; **divide the budget across instances** when scaling horizontally (each instance has its own independent pool).

**After the Hetzner migration (direct connection):** this pooler-budget math changes entirely. A direct connection bypasses the pooler and counts against Postgres's raw `max_connections` (nano default ~60), not the pooler's 15 — so the caps become more generous, but you then budget against `max_connections`. Keep `KC_DB_POOL_MAX_SIZE` explicit regardless (don't fall back to Agroal's default of 100).

**Symptom-to-cause quick reference for Keycloak-on-Supabase:**
| Log signature | Cause | Fix |
|---|---|---|
| `prepared statement "S_NNN" does not exist` / `XA_RBROLLBACK` / 500 on `/token` | transaction-mode pooler (6543) | session pooler (5432) + `prepareThreshold=0` |
| `Acquisition timeout while waiting for new connection` / slow responses / failing scheduled tasks | Agroal max pool > Supabase pooler cap | cap `KC_DB_POOL_MAX_SIZE` (~10) |

**Verify after deploy:** watch the Keycloak log during a login + a few minutes of clicking — no `prepared statement ... does not exist`, no `XA_RBROLLBACK`, no `500` on `/token`, **and no `Acquisition timeout while waiting for new connection`**. Then `./smoke.sh` → the **Token endpoint stability** check (Test 4b) hammers `/token` 15× and passes only if there are zero intermittent 500s.

**Events cleanup (related):** if event logging is enabled, set an **event expiration** (Realm settings → Events config, e.g. 7–14 days) so the events table doesn't grow unbounded. The `ClearExpiredEvents` scheduled task prunes it; if that task keeps failing (e.g. during pool starvation) the table grows and queries slow further — a compounding loop. Event logging itself does **not** cause pool-acquisition timeouts, but an unbounded events table adds avoidable DB load.

**Dev/staging:** apply the identical `KC_DB_URL` (session pooler 5432 + `prepareThreshold=0`) **and** the Agroal pool caps when standing up `yourapp-dev` / `yourapp-staging`.

**Future Hetzner migration:** when Keycloak moves to the Hetzner VM (planned, §Option B), the IPv6 limitation disappears — a VM can egress IPv6 — so the Supabase **direct** connection becomes viable there and bypasses the pooler entirely. Keep `prepareThreshold=0` regardless, and re-verify with the Token endpoint stability check after the move.

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

For Neon/Supabase, swap the JDBC URL and drop `--add-cloudsql-instances`. **For Supabase specifically, use the session-mode pooler + `prepareThreshold=0` per §A.2.3** — e.g. `jdbc:postgresql://<region>.pooler.supabase.com:5432/postgres?sslmode=require&prepareThreshold=0` (Neon: `jdbc:postgresql://HOST:5432/keycloak?sslmode=require`).

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

## A.9a ⚠️ Cloud Run tuning for a JVM auth server (perf-critical)

> **Observed in production (yourapp-prod, 2026-07): admin console slow, multi-second page loads, intermittent `Timeout when waiting for 3rd party check iframe message`, latency spikes to ~50s with CPU + memory pinned at 100%.** The Cloud Run dashboard showed the cause clearly. Keycloak is a JVM app, and **Cloud Run's defaults are actively hostile to the JVM.** Two settings dominate:

**1. CPU allocation — the non-obvious killer. Set CPU to "always allocated" (`--no-cpu-throttling`).**
Cloud Run has two CPU/billing modes:
- **Request-based billing / CPU only during requests (default):** the container gets **near-zero CPU between requests.**
- **Instance-based billing / CPU always allocated:** continuous CPU.

For a stateless function the default is fine. **For a JVM it is harmful:** the JVM does critical work *between* requests — garbage collection, JIT compilation (what makes Java fast after warmup), and Keycloak's scheduled tasks. Throttled between requests, JIT never optimizes hot paths, GC falls behind then catches up in CPU-spiking bursts, and the "warm" `min-instances=1` container still behaves cold on the next request. **This, not cold starts, is usually the real cause of "warm instance but still slow."**

**2. Memory floor — 512Mi is too small.** The JVM sizes its heap as a % of container memory, so 512Mi → tiny heap → constant GC pressure → CPU + latency spikes together (the classic GC-thrash signature: memory chart climbing to ~100% alongside CPU spikes). **Give Keycloak ≥1Gi (2Gi safer.)**

**Apply all at once:**
```
gcloud run services update yourappauth --region=<region> \
  --no-cpu-throttling --min-instances=1 --memory=2Gi --cpu=1
```
- `--no-cpu-throttling` → CPU always allocated (switches to instance-based billing). **The highest-value single change.**
- `--min-instances=1` → no scale-to-zero cold starts.
- `--memory=2Gi` (or start at 1Gi, watch the memory chart, bump to 2Gi if still tight).
- `--cpu=1` is usually fine *once CPU is always-allocated*; go `--cpu=2` if spikes persist.

**Verify:** re-watch the Cloud Run metrics for a day — instance-count flickering should stop (one steady warm instance), latency spikes flatten, memory stops pinning, and the check-session iframe timeouts disappear.

**The strategic point (feeds A.10):** once you're paying for one always-on, always-CPU'd, ≥1Gi instance for a JVM, you've **recreated a small VM at Cloud Run prices** — and lost scale-to-zero's benefit. Keycloak wants always-warm + steady CPU + steady memory, which is a VM's *native* model and Cloud Run's *expensive exception*. This tuning is the pragmatic fix to stabilize now; it's also the empirical argument for the Hetzner migration (A.10 / Option B). Tune first, get end-to-end working, then migrate from a known-good baseline — not while chasing flakiness.

**Admin-console-specific note.** The perf pain shows up most in the **admin console** (a heavy SPA firing many Admin REST calls per page), not the login path (fewer calls). If login feels fine but admin pages are slow, that's expected and this tuning still helps. The `Timeout when waiting for 3rd party check iframe message` error is the admin console's session-status iframe timing out — worsened by cold/throttled CPU and cross-region latency, and by browsers blocking third-party cookies (try allowing third-party cookies for `auth.yourapp.com`, or use `kcadm.sh` for routine ops). Your app uses back-channel logout, not the check-session iframe, so end users never hit this path.

## A.10 Outgrowing Cloud Run

Triggers for Option B:
- 3+ services that would benefit from co-location.
- Cold starts become user-visible *and* `min-instances=1` costs more than a multi-service VM.
- You add Elasticsearch or another service that doesn't fit Cloud Run.
- **JVM-on-Cloud-Run tuning (A.9a) stabilizes perf only by making the instance effectively always-on + always-CPU + ≥1Gi — i.e. a small VM at Cloud Run prices.** Once you're there, a Hetzner VM gives more resources for less, with none of Cloud Run's JVM-hostile defaults. yourapp-prod reached this point in 2026-07 (perf tuning applied as a stopgap; migration planned next).

Migration when needed: export realms, stand up VM per Option B, import realms, repoint DNS. A couple of hours.

## A.11 Keycloak behind Cloudflare (proxy gotchas)

> **Observed in production (2026-07-04):** with `auth.yourapp.com` proxied through Cloudflare, the admin console spun forever on load and the smoke tests' admin-API calls returned HTML `429` pages (surfacing as `jq: parse error: Invalid numeric literal`). Same class of issue as the Supabase pooler — infrastructure *in front of* Keycloak breaking it in non-obvious ways.

**Symptoms:**
- Admin console (`keycloak.v2` SPA) hangs on load; browser console shows `rocket-loader.min.js` errors like *"preload ... credentials mode does not match"*.
- Asset/API requests to `/resources/*` and `/admin/*` return **429**.
- Smoke tests fail with non-JSON parse errors (an HTML 429/challenge page instead of realm JSON).

**Causes and fixes** (Cloudflare dashboard, scoped to `auth.yourapp.com`):
1. **Rocket Loader mangles the admin SPA.** Turn it **off** for `auth.yourapp.com` (Speed → Optimization, or a Configuration Rule scoped to the hostname). Rocket Loader rewrites/defers JS and breaks the module-preload the console relies on.
2. **Rate-limit / Bot Fight rules 429 the console.** The admin console legitimately fires dozens of asset + API requests per second on load; a blanket per-IP rule throttles it. **Scope rate-limit rules away from `/admin/*` and `/resources/*`**, or raise the threshold, or restrict rules to the abuse-prone endpoints only (`/realms/*/clients-registrations/*`, `/realms/*/protocol/openid-connect/token`).
3. **Auto Minify / other "optimizations"** — off for this hostname; Keycloak serves its own optimized assets.

**Fastest confirmation:** set `auth.yourapp.com` to **DNS-only (grey cloud)** or enable Cloudflare **Development Mode**. If the console loads cleanly, Cloudflare is confirmed; re-enable the proxy with Rocket Loader off and rate-limits scoped.

**Recommended posture for an IdP behind Cloudflare:** thin proxy — DNS proxy on (DDoS/TLS) but **Rocket Loader, Auto Minify, aggressive Bot Fight Mode OFF**, and rate-limits scoped narrowly to abuse-prone endpoints rather than blanket. Keycloak's admin console and asset pipeline don't tolerate Cloudflare's content optimizations. (yourapp-prod currently runs `auth.yourapp.com` **DNS-only** after this incident — the simplest safe posture pre-PMF.)

## A.12 Observability — metrics into Grafana Cloud (or GCP)

> **Status:** operational hardening, not launch-blocking. But the DB-pool metric alone would have turned two multi-session debugging incidents (prepared-statement 500s, pool exhaustion) into a single glance at a graph — so it earns its place early.

### A.12.0 What Keycloak exposes, and the security model

Enable via build/runtime flags (already set in the A.5 deploy: `KC_HEALTH_ENABLED=true`, `KC_METRICS_ENABLED=true`):
- **`/metrics`** (Prometheus/Micrometer format) and **`/health/*`** are served on a **separate management port — 9000 by default**, NOT the main app port 8080. This isolation is deliberate (Keycloak docs: exposing metrics on the main port is "not recommended for security reasons").
- To also break down user-event metrics, add **`--event-metrics-user-enabled=true`** (fully supported since 26.2), optionally **`--event-metrics-user-tags=realm,idp,clientId`** to tag by client/IdP (only for low client/IdP counts — it increases memory + monitoring cardinality).
- For HTTP latency heatmaps, add **`http-metrics-histograms-enabled=true`**.

**🔒 Security of `/metrics` — your instinct is correct.** On **Cloud Run, port 9000 is not mapped** (Cloud Run routes only the single `--port=8080` you configure), so `/metrics` and `/health` are **unreachable from the internet** — no auth needed on them because nothing external can route to them. This is why:
- **You do NOT expose 9000 publicly.** Leave it unmapped. Never put `auth.yourapp.com/metrics` on the public hostname.
- **On Cloud Run's single-exposed-port model, a pull/scrape from outside the container can't reach port 9000** — so scrape-based options (sidecar, cron-scrape) either run *inside* the container's network namespace (sidecar) or don't work (external cron). Only **push** (Keycloak dials out) works cleanly on Cloud Run without a co-located scraper. This is a *current-platform* constraint, not an architectural verdict.
- **Target-state (VPC) note:** the intended future architecture — all containers, DBs, and sidecars inside a VPC with only load-balancer ports internet-routable — makes a **private scrape the *right* model**: a collector on the private network scrapes `:9000` over private networking, nothing is public, and the LB exposes only what you choose. So the scrape/sidecar paths below aren't wrong; they're simply not reachable on Cloud Run's single-port model *today*. Plan for private scrape once the VPC exists.
- **Post-Hetzner (interim):** on the VM, bind 9000 to `localhost` only (`http-management-host=127.0.0.1`) or firewall it, so a local scraper (Alloy/OTel collector) can reach it but the internet cannot.

### A.12.1 Three export paths — pick by where you run and what you'll pay

| Path | How | Cost | Works on Cloud Run? | Best when |
|---|---|---|---|---|
| **Direct OTLP push** | Keycloak → Grafana Cloud OTLP endpoint, no collector | $0 extra | ✅ Yes (push, dials out) | **Recommended now** — single container, free Grafana Cloud |
| **Sidecar collector** | Alloy/OTel sidecar scrapes `:9000`, remote-writes | ~$15–20/mo (always-on sidecar) | ✅ Yes | Later — when you run several containers and one collector serves all |
| **Cron-scrape** | Scheduled job scrapes `/metrics`, remote-writes | ~$0 (ephemeral) | ❌ **Not on Cloud Run** (can't reach 9000 externally) | Only on a VM/host where 9000 is locally reachable |

### A.12.2 Path 1 — Direct OTLP push to Grafana Cloud (recommended)

Keycloak 26.x exports metrics over OTLP via the Micrometer→OTel bridge. ⚠️ **This is an *experimental* feature in 26.5/26.6** (`opentelemetry-metrics`). **Traces** and **event metrics** are more mature; if you want zero experimental surface on a production IdP, start with traces + event metrics and add app-metrics-over-OTLP once you've validated it on your build.

#### A.12.2.1 Grafana Cloud setup — get your endpoint, instance ID, and token

Do this first; it produces the three values Keycloak needs. (Grafana Cloud's Free tier includes the OTLP gateway.)

1. **Create/sign in to a Grafana Cloud account** at `grafana.com` → you land on the Cloud Portal (`https://grafana.com/orgs/<org>`). A new account has one **organization** with one **stack** (a stack = your hosted Grafana + Mimir/Loki/Tempo backends). Free tier is fine.
2. From the Portal, select your **stack**. Under **"Manage your Grafana Cloud Stack,"** find the **OpenTelemetry** tile → click **Configure**.
3. On the OpenTelemetry configuration page you'll see:
   - **OTLP Endpoint URL** — pattern `https://otlp-gateway-<zone>.grafana.net/otlp` (e.g. `otlp-gateway-prod-ap-south-1...` — the zone matches where your stack lives). This is your `OTEL_EXPORTER_OTLP_ENDPOINT`.
   - **Instance ID** — a numeric ID shown on this card. This is the **basic-auth username** for OTLP.
4. In the **Password / API Token** section on that same page, click **Generate now** to create a token. ⚠️ **The token is shown only once — copy it immediately into Secret Manager.** (Under the hood this creates an **Access Policy** with `metrics:write` / `traces:write` / `logs:write` scopes and issues a token; you can also manage these under **Security → Access Policies** in the Portal. Note: Grafana Cloud replaced the older "API Keys" flow with Access Policies + tokens — if a tutorial mentions "MetricsPublisher API key," that's the legacy path.)
5. **The page generates the exact env-var values for you** — including a ready-made `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(instanceID:token)>`. **Copy that pre-encoded header rather than base64-ing by hand** (fewer mistakes). Keep `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_HEADERS` from this page.

What you now have:
- `OTLP endpoint` → `https://otlp-gateway-<zone>.grafana.net/otlp`
- `instance ID` (numeric, the basic-auth username)
- `token` (the basic-auth password; store in Secret Manager — shown once)
- a pre-built `Authorization: Basic <base64(instanceID:token)>` header value

#### A.12.2.2 Keycloak-side configuration

Grafana Cloud's endpoint is **OTLP/HTTP**, so point Keycloak's telemetry endpoint straight at it — no collector:

```
# Feature + enablement (build-time features may require rebuilding the optimized image)
--features=opentelemetry-metrics
--telemetry-metrics-enabled=true
--metrics-enabled=true
# (optional, mature) traces:
--tracing-enabled=true --features=opentelemetry

# Global telemetry endpoint (Grafana Cloud OTLP gateway; HTTP, not the gRPC default)
--telemetry-endpoint=https://otlp-gateway-<zone>.grafana.net/otlp
--telemetry-protocol=http/protobuf
--telemetry-service-name=keycloak-yourapp-prod

# Auth header for metrics export — the Basic value from A.12.2.1 step 5
--telemetry-metrics-header-Authorization=Basic <BASE64_INSTANCEID_TOKEN>
```

As env vars on Cloud Run, these map to `KC_*` forms (e.g. `KC_TELEMETRY_ENDPOINT`, `KC_TELEMETRY_PROTOCOL`, `KC_TELEMETRY_SERVICE_NAME`, `KC_TRACING_ENABLED`). ⚠️ **Verify the exact env-var spellings and the experimental-feature flag names against the 26.6.0 docs for your build before deploying** — the `telemetry-*` CLI ↔ `KC_TELEMETRY_*` env mapping and the `opentelemetry-metrics` feature name are version-sensitive and have been changing release-to-release. **Put the `Authorization` header value in Secret Manager** (`--set-secrets`), not inline in `--set-env-vars`.

#### A.12.2.3 Verify it's flowing

1. Redeploy Keycloak, generate some activity (a few logins).
2. In Grafana Cloud → **Explore** → select the Prometheus/Mimir data source (usually `grafanacloud-<stack>-prom`) → query for a Keycloak metric (e.g. a JVM or `http_server_*` metric, or a `keycloak_*` event metric). Allow 1–2 minutes for first data.
3. If nothing arrives: check the Keycloak log for OTLP export errors (401 = bad/expired token or wrong instance ID in the header; 404 = wrong endpoint zone), and confirm the endpoint zone matches your stack.
4. Import a prebuilt **Keycloak Grafana dashboard** (Grafana.com dashboards library) as a starting visualization.

### A.12.3 Path 2 — Sidecar collector (defer until multi-container)

Run **Grafana Alloy** (or an OTel collector) as a Cloud Run **sidecar container**; it scrapes `http://localhost:9000/metrics` (reachable within the container network) and remote-writes to Grafana Cloud's Prometheus endpoint. This is the standard Grafana pattern and avoids Keycloak's experimental OTLP-metrics path (it uses the stable `/metrics` pull). The downside is an always-on sidecar (~$15–20/mo). **Revisit when you run Keycloak + app + worker etc. and one Alloy can serve them all** — at that point the per-service cost amortizes and this becomes the cleanest option.

### A.12.4 Path 3 — Cron-scrape / private scrape (VM or VPC, NOT single-port Cloud Run)

A scheduled job (or a persistent collector) scrapes `/metrics` and remote-writes to Grafana Cloud. **This does not work on Cloud Run's single-exposed-port model** — port 9000 isn't externally reachable and there's no persistent localhost to scrape between requests. It becomes the natural low-cost choice wherever 9000 *is* reachable on a private network: after the Hetzner migration (bind 9000 to localhost, run Alloy/a cron scraper on the same host), or in the **target VPC architecture** (a collector on the private network scrapes `:9000` over private networking; nothing public). In the VPC end-state this is arguably the cleanest model — private scrape, no experimental push feature, LB exposes only chosen ports.

### A.12.5 Metrics to watch, and starter alert thresholds

**Performance (Keycloak health):**
| Metric (approx. name — verify) | Signal | Starter alert |
|---|---|---|
| Agroal `*active*` / `*available*` connections | DB pool saturation (your recent incident) | available ≤ 1 for > 2 min |
| Agroal acquisition-timeout counter | pool exhaustion | any increase over 5 min |
| HTTP request duration p95/p99 (`/token`, `/auth`) | login latency | p99 > 1s for > 5 min |
| JVM heap used / max, GC pause time | memory pressure on small instance | heap > 85% sustained |

**Abuse / attack (event metrics):**
| Metric | Signal | Starter alert |
|---|---|---|
| `LOGIN_ERROR` rate (tag: realm, client) | credential stuffing / probing | > N failures/min, or error:success ratio spike |
| Token refresh rate per client | runaway client / refresh storm (see §8.6.1) | sharp per-client spike |
| DCR registration rate (`/clients-registrations/*`) | abuse of anonymous DCR endpoint | > N registrations/min from one source |
| 429 rate (once a rate-limiter is back in front) | throttling activity / attack | sustained non-zero |

Red Hat/Keycloak ship **prebuilt Grafana dashboards** for Keycloak metrics — import those as a starting point rather than building from scratch.

### A.12.6 Recommendation for now

Given pre-PMF cost/effort constraints and a production IdP: **do Path 1 (direct OTLP push) with event metrics + traces first** (both mature), and treat full app-metrics-over-OTLP as opt-in after validating the experimental flag on 26.6.0. This gives the abuse signals (login failures, DCR rate) and, via the stable `/metrics` if you later add a scraper, the pool/JVM/HTTP performance metrics — at ~$0. Move to Path 2 (shared Alloy sidecar) when you have several containers, and Path 3/localhost-Alloy after the Hetzner migration. **Never expose port 9000 publicly** regardless of path.

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
      # Supabase: session-mode pooler + prepareThreshold=0 (see §A.2.3). On the
      # Hetzner VM (unlike Cloud Run) outbound IPv6 is available, so the Supabase
      # DIRECT connection (db.<ref>.supabase.co:5432) is also viable here and
      # bypasses the pooler. Keep prepareThreshold=0 regardless.
      KC_DB_URL: "jdbc:postgresql://${KC_DB_HOST}:5432/keycloak?sslmode=require&prepareThreshold=0"
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

⚠️ **Flow structure matters — a naive "add the step at the bottom" produces a broken flow that returns HTTP 400 on every login it governs.** Keycloak forbids mixing **Required** and **Alternative** executions at the same level. The SPI picker must run *after* authentication as a Required step, which means the authentication executions have to be wrapped in their own Required sub-flow. Target structure:

```
browser-mcp-tenant-pick:
  ├── Authentication              [Required]  (sub-flow)
  │     ├── Cookie                       [Alternative]
  │     ├── Identity Provider Redirector [Alternative]
  │     └── Username Password Form       [Alternative]  (execution — NOT a nested Forms sub-flow)
  └── YourApp MCP Tenant Picker    [Required]  (top level, AFTER the sub-flow)
```

The wrong structure (picker as a top-level Required sibling to the Alternative auth steps) makes Keycloak treat the alternatives as invalid, so no authentication path runs and `/auth` returns 400 before any IdP redirect. Note also that a *nested* sub-flow (e.g. moving the `Forms` sub-flow inside `Authentication`) cannot be set to Alternative in 26.6.0 — only Required/Disabled — so use the `Username Password Form` **execution** directly instead (see build steps).

**Build it:**
1. Find `browser-federated-only` → row action menu → **Duplicate**. Name the copy `browser-mcp-tenant-pick`. Open it.
2. The duplicate has Cookie / Identity Provider Redirector / Forms at the **top level** as Alternatives. Wrap the authentication executions in a Required sub-flow:
   - Add a sub-flow at the top level (**Add sub-flow**), name it `Authentication`, set it **Required**.
   - Move **Cookie** and **Identity Provider Redirector** into `Authentication` (drag-and-drop), keeping each **Alternative**.
   - ⚠️ **Federated-only: DROP the Username Password Form entirely — you don't have local passwords.** yourapp.com authenticates via Google/Microsoft (Invariant 1), so the Username Password Form renders a password box no user can use. **Delete the `Forms` sub-flow and do not re-add the password form.** Federated login needs only two paths: Cookie (existing session) and Identity Provider Redirector (redirect to the IdP) — both Alternative. This sidesteps the whole "can't make Username Password Form Alternative" problem, because you remove the piece that doesn't belong rather than fighting Keycloak's flow model.

     **⚠️ One thing to verify before deleting:** what renders the **IdP-selection page** for a user arriving with no `kc_idp_hint` and no cookie? In the stock flow, the Username Password Form page *also* shows the "Sign in with Google/Microsoft" buttons.
       - **If MCP clients always send `kc_idp_hint`** (or the app/picker specifies the IdP): the Identity Provider Redirector fires directly — delete the form, done.
       - **If a user must interactively choose Google vs Microsoft:** you need something to render that choice. Then keep the password form, but structure it the **idiomatic** way (next bullet) — NOT as a bare Alternative execution.

   - **If you must keep the login/selection page:** use a **generic sub-flow set to Alternative**, containing **Username Password Form set to Required *inside* it**. ⚠️ **In 26.6.0 the built-in `Forms` sub-flow, once nested inside `Authentication`, only offers Required/Disabled — NOT Alternative.** A freshly-created *generic* sub-flow at the same position *does* offer Alternative. So: delete the stock `Forms` sub-flow, then on the `Authentication` row → **Add sub-flow** → name it (e.g. `password-auth`) → set it **Alternative** → then **Add step → Username Password Form** inside it, set **Required**. The key insight is unchanged: you make the *sub-flow* Alternative and the form Required *within* it — you do not (and cannot) make the form itself Alternative. Use a **generic** sub-flow, not the built-in `Forms`, because only the generic one accepts Alternative when nested. (If the sub-flow contains an OTP Form, set it **Disabled** — federated-only means MFA is authoritative at the upstream IdP, Invariant 2.)
3. At the **top level** (a sibling of the `Authentication` sub-flow, positioned **after** it), **Add step** → find **YourApp MCP Tenant Picker** [?]. Set it **Required**.
4. Confirm the final tree — **federated-only (recommended):**
   ```
   browser-mcp-tenant-pick:
     ├── Authentication [Required] (sub-flow)
     │     ├── Cookie                       [Alternative]
     │     └── Identity Provider Redirector [Alternative]
     └── YourApp MCP Tenant Picker           [Required]
   ```
   Or, **if you need the IdP-selection page** (generic sub-flow — NOT the built-in Forms, which won't take Alternative when nested in 26.6.0):
   ```
   browser-mcp-tenant-pick:
     ├── Authentication [Required] (sub-flow)
     │     ├── Cookie                       [Alternative]
     │     ├── Identity Provider Redirector [Alternative]
     │     └── password-auth                [Alternative] (GENERIC sub-flow, created new)
     │           └── Username Password Form [Required]    (inside; OTP Form Disabled if present)
     └── YourApp MCP Tenant Picker           [Required]
   ```
5. Save.

⚠️ **Prerequisite for the IdP-selection page to actually work: each IdP must have "Display on login page" ON.** The `Username Password Form` renders the social/IdP login buttons ("Sign in with Google/Microsoft") **only for IdPs whose per-IdP setting "Display on login page" (a.k.a. `hideOnLoginPage=false`) is enabled.** If it's off, the login page renders a bare username/password box with **no IdP buttons** — and since MCP clients can't send `kc_idp_hint` (they speak standard OIDC/DCR and have no concept of Keycloak's upstream IdPs), a first-time MCP user would be **stranded with no way to reach Google/Microsoft.** Verify: Identity providers → (each of Google, Microsoft) → **Display on login page = On**. This is the piece that makes the selection page functional rather than merely present.

> **Which login page do MCP clients see? Keycloak's — not yourapp.com's.** yourapp.com hosts its own web-app login page (`prod.yourapp.com/auth/login.html`, branded, IdP-only), but **MCP clients never see it** — they hit Keycloak's authorize endpoint directly (standard OIDC/DCR), so they land on **Keycloak's** login page at `auth.yourapp.com` (the `browser-mcp-tenant-pick` flow's Username Password Form execution). These are two separate surfaces (PRD §9). Consequences: (1) the MCP login page is styled by the **Keycloak theme** (`KEYCLOAK_THEMING_GUIDE.md`), not the app's `login.html` — you can't reuse the app page for MCP. (2) Un-themed, it shows a dead username/password box (federated-only) next to the working IdP buttons — functional but not pretty. (3) For MCP clients this Keycloak page is the **primary** login surface (every login), not a rare fallback — so theme it before the MCP pilot if first-impression branding matters.

**Note — the nested-subflow-Alternative constraint is NOT a 26.6.0 bug and won't be fixed by upgrading.** A *nested* sub-flow's requirement options (and how conditionals/alternatives nest) are longstanding Keycloak design, not a regression. Do not upgrade to "fix" this — the fix is structural (drop the form, or use the idiomatic Forms-sub-flow nesting above). Upgrade for other reasons (CVE-2026-9792, the `[null]` form-serialization bug), not this.

**Verify:**
- `./smoke.sh` → Test 15 green (SPI step present in the flow).
- **Do not bind this flow realm-wide to test it** — that is Option A and it is not recommended (see D.8). Test it via a per-client binding on a DCR'd MCP client instead.

**Verify the structure is not broken:** temporarily bind this flow to a *throwaway test client* (not the realm default, not the web client) and attempt a login. If you get HTTP 400 at `/auth`, the Required/Alternative structure is still wrong — recheck that the auth executions are inside the Required sub-flow, not siblings of the picker.

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

**Path:** Clients → Client Registration → **Anonymous Access Policies** [?]

Not under Realm settings — the DCR policies live under **Clients → Client Registration**, with separate **Anonymous Access Policies** and **Authenticated Access Policies** sub-sections. Anonymous is the relevant one for MCP (clients self-register without presenting a token).

Add each policy below: **Create policy** [?] → select provider → configure → save.

⚠️ **Keycloak seeds several anonymous policies by default** — when you open this screen you'll likely already see `allowed-client-scopes`, `max-clients`, `trusted-hosts`, `full-scope-disabled`, and others pre-created. **Edit the existing ones rather than creating duplicates.** Only add a policy fresh if it's genuinely absent (e.g., `consent-required` may not be seeded).

| Provider | Configuration |
|---|---|
| `allowed-client-scopes` | **Edit the seeded one.** Add to the whitelist: `openid`, `offline_access`, `profile`, `email`, `mcp-default`, all six `yourapp:*` scopes |
| `consent-required` | **Add if absent.** No config fields — just create the entry |
| `max-clients` | **Edit the seeded one.** See note below on choosing a value |

**On `trusted-hosts` (seeded by default):** Keycloak pre-creates this policy and **requires at least one of its two toggles to be ON** — you'll get an error trying to turn both off, so a fully-permissive version isn't achievable. Don't delete it reflexively; instead configure it as: "Host Sending Client Registration Request Must Match" **OFF** (MCP clients register from unpredictable IPs), "Client URIs Must Match" **ON**, with the Trusted Hosts list containing the hostnames MCP redirect URIs will use — at minimum `localhost` for desktop/CLI clients.

✅ **VERIFIED behavior (2026-07-05):** Keycloak 26.6.0's "Client URIs Must Match" **matches on host regardless of port** — a registration with `http://localhost:53789/callback` or `http://127.0.0.1:53789/callback` (arbitrary high ports) **succeeds** with `localhost`/`127.0.0.1` in the trusted list. So Trusted Hosts is **viable to keep ON** for MCP desktop clients (which use arbitrary loopback ports) — it constrains redirect hosts for real security while allowing legitimate loopback clients. **Keep it enabled**; put both `localhost` and `127.0.0.1` in the list. (Earlier drafts said to consider deleting it; that's superseded — keeping it on is the better posture now that loopback-port handling is confirmed.)

**On `max-clients` value:** the number's job is DoS protection — stop a script from creating millions of clients and exhausting Postgres. Size it above legitimate use but well below "database problem." At friends-of-founders scale (tens of users × a few MCP clients each), legitimate use is in the low hundreds at most. Keycloak's default is **200**; `1000` gives comfortable growth headroom. Either is fine; pick based on how much you want to avoid a future "bump the limit" admin change. 10000 (an earlier draft value) is meaninglessly high for your scale — it would never trip before a DoS became a storage problem.

**Optional:** `allowed-protocol-mappers` (⚠️ the seeded policy in 26.6.0 is named `allowed-protocol-mappers`, not `allowed-protocol-mapper-types` as earlier drafts assumed — verified against a live realm). Skip for v1 — the security-critical mappers are attached to the `mcp-default` scope (not the client), so DCR'd clients can't override them. See PRD §16.4 for the rationale and full whitelist if you want belt-and-suspenders later.

**Verify:** `./smoke.sh` → Test 18. Note: Test 18's sub-checks may expect specific policy providers; if you skip `trusted-hosts` and `allowed-protocol-mapper-types`, the test's "expected providers" list should be updated to match your actual minimal set (see the smoke test's `EXPECTED_POLICIES` array).

## D.6 Client Policies (newer profile-based system)

**Path:** Realm settings → Client policies

Two parts: create a Profile of executors, then create a Policy with a condition that activates the profile.

### D.6a Profile `mcp-hardening`

Profiles tab → **Create profile** [?]:
- **Name:** `mcp-hardening`
- **Description:** "OAuth 2.1 hardening for DCR'd MCP clients"

After saving, the profile is editable. Add executors via **Add executor** [?].

**The Auto-configure pattern (26.6.0):** most executors no longer expose granular config fields (e.g. `pkce-enforcer` no longer shows a "Code Challenge Method" field). Instead each executor offers an **Auto-configure** toggle. Auto-configure ON means the executor *writes the compliant setting onto the client automatically* (and enforces the secure default), rather than only rejecting non-compliant requests. For DCR'd clients you can't hand-configure, this is exactly the desired behavior.

**General rule: turn Auto-configure ON for every executor.** The only toggles to leave OFF are ones that *loosen* security (see `secure-response-type` note below).

| Behavior | Provider ID [verify] | Settings |
|---|---|---|
| Enforce PKCE (S256) | `pkce-enforcer` | **Auto-configure: ON** (auto-stamps S256 on clients; rejects non-S256 auth requests). The old explicit "Code Challenge Method" field is gone in 26.6.0 — Auto-configure replaces it. |
| Restrict response types to `code` (forbid implicit) | `secure-response-type` | **Auto-configure: ON.** ⚠️ **"Allow token response type": leave OFF** — ON would re-permit the insecure implicit flow (`token` response type), defeating the executor. OAuth 2.1 / MCP clients use auth-code + PKCE only. |
| Force consent required | `consent-required` | **Auto-configure: ON** |
| Enforce secure redirect URIs | **swap `secure-client-uris` → `secure-redirect-uris-enforcer`** | ⚠️ **The default `secure-client-uris` has NO loopback config and rejects all MCP desktop clients — you MUST swap it. See below.** |
| Secure session binding | `secure-session` | **Auto-configure: ON** |
| Disable client full-scope access | `full-scope-disabled` | **Auto-configure: ON** |

⚠️ **Confidence note:** I'm confident about `pkce-enforcer` Auto-configure and about leaving "Allow token response type" OFF. The exact Auto-configure semantics on the *other* executors are inferred from the same pattern, not individually verified. If any executor's Auto-configure writes a client setting you didn't expect, inspect that one. The D.12 DCR test plus decoding an actually-issued token is the end-to-end confirmation that the profile behaves correctly.

**🔑 The redirect-URI executor MUST allow loopback — and the DEFAULT executor can't. You must SWAP it.** This bit yourapp-prod in production (2026-07-05): DCR registrations with loopback redirects were rejected with `client_policy_error_detail="Invalid redirectUris"`. The cause is subtle — **there are two different redirect-URI executors, and they behave very differently:**

| Executor | Config options | Loopback (`http://127.0.0.1:PORT`)? | Origin |
|---|---|---|---|
| **`secure-client-uris`** | **NONE** (empty config) | **Rejected — no way to allow it** | FAPI 2.0; mandates HTTPS on all client URIs |
| **`secure-redirect-uris-enforcer`** | loopback/http/scheme flags | **Yes, when configured** | OAuth 2.1; honors RFC 8252 loopback exception |

Per Keycloak's own upgrade notes, `secure-client-uris` "enforce[s] stricter validation... mandating TLS (HTTPS) for client endpoints" — it is an **all-or-nothing HTTPS rule with no configuration and no loopback exception.** If your `mcp-hardening` profile has `secure-client-uris` (the older default), it will reject every loopback MCP desktop client (Claude Code, Cursor, Claude Desktop — all use `http://127.0.0.1:PORT` per RFC 8252), and there is **no config flag to fix it.**

**Fix — swap the executor in the `mcp-hardening` profile:**
1. **Delete `secure-client-uris`** (trash icon next to it).
2. **Add `secure-redirect-uris-enforcer`** (a.k.a. `secure-redirect-uri`) from the executor dropdown.
3. Configure the new executor (top-level Form view / JSON editor for the profile) with loopback allowed:
```json
"executor": "secure-redirect-uris-enforcer",
"configuration": {
    "allow-http-scheme": true,
    "allow-ipv4-loopback-address": true,
    "allow-ipv6-loopback-address": true,
    "allow-private-use-uri-scheme": true,
    "allow-open-redirect": false,
    "allow-wildcard-context-path": false,
    "oauth-2-1-compliant": false
}
```
- `allow-ipv4-loopback-address` / `allow-ipv6-loopback-address` → permit `http://127.0.0.1:PORT` / `http://[::1]:PORT`.
- `allow-http-scheme` → loopback is inherently `http`; without this it still fails.
- `allow-private-use-uri-scheme` → permit `com.example.app:/callback` custom schemes some native clients use.
- **`allow-open-redirect: false`** → KEEP false. This is the flag that matters for security (open-redirector prevention); loosening loopback does NOT loosen this.
- **`oauth-2-1-compliant: false`** → leave false; `true` re-imposes strict rules that can reject loopback-by-hostname.

⚠️ **"Allow permitted domains" — the UI can persist a poison `[null]` value that 500s all DCR. Fix via JSON editor, not the form.** Leave this genuinely empty (you're not restricting redirects to domains — Trusted Hosts handles host constraints). **The bug:** the form renders an empty input row for this list; saving the executor with that blank row present persists `"allow-permitted-domains": [null]` (an array with one null element) — **NOT** `[]`. On every DCR request the executor calls `Pattern.matches(null, ...)` on that null → `java.lang.NullPointerException: ... "this.pattern" is null` in `SecureRedirectUrisEnforcerExecutor.matchDomain` → **uncaught 500 on `/clients-registrations/*`**. Confirmed on yourapp-prod 2026-07-05: DCR worked in early manual tests (before the executor was saved), then every registration 500'd after a save persisted `[null]`.

**The UI can't fix it** — the `–`/remove button next to the empty row does nothing (it can't remove the null element). **Fix via the JSON editor:** Realm settings → Client policies → Profiles → toggle **Configure via: JSON editor** → find `"allow-permitted-domains": [null]` in the `secure-redirect-uris-enforcer` config → change to `"allow-permitted-domains": []` (or delete the key) → Save. (Or PUT the corrected profile via `PUT /admin/realms/{realm}/client-policies/profiles`.) **Verify the fix** by re-reading the profile: `GET /admin/realms/{realm}/client-policies/profiles` should show `[]`, not `[null]`. This is a Keycloak UI defect (issues #27344, #33734, terraform-provider #1142 describe the same empty-URI NPE family); a later 26.6.x patch may fix the form serialization — worth upgrading (also needed for CVE-2026-9792).

⚠️ **`127.0.0.1` vs `localhost` — subsystems disagree, so register both / test.** RFC 8252 §7.3 recommends the IP literal `http://127.0.0.1:PORT`, and the `secure-redirect-uris-enforcer` loopback flags key on the IP literals. But Keycloak's *Trusted Hosts* loopback verification (a different subsystem) was changed to normalize/recognize only `localhost` and `*.localhost`. Because the two subsystems are inconsistent, the pragmatic move is to **register both `http://127.0.0.1:PORT/callback` and `http://localhost:PORT/callback`** on MCP clients (or test which your build accepts) rather than assume one. Communicate the working form to anyone piloting an MCP client.

**Do NOT use `secure-client-uris-pattern`** (URI pattern allowlist) — it reintroduces the localhost-vs-vendor-domain problem and can't accommodate arbitrary loopback ports from unknown user machines.

### FAPI-tier executors — skip for v1

The `secure-*` executor dropdown includes many executors from Keycloak's FAPI (Financial-grade API) support — a much stricter profile than pre-PMF MCP needs. **The decision rule:** each executor is a constraint DCR'd MCP clients must satisfy; if real MCP clients (Claude Desktop, Cursor, CLI tools) don't do the thing an executor requires, that executor will *reject* them.

MCP clients **do**: authorization-code flow, PKCE (S256), plain unsigned auth requests, loopback or HTTPS redirects, consent.
MCP clients **do not**: sign request objects, use JARM-signed responses, use DPoP/mTLS sender-constraining, use pushed authorization requests (PAR).

So **skip these for v1** (they require behaviors MCP clients don't exhibit and will break legitimate clients):

| Executor [names approximate] | What it requires (inferred) | Why skip for v1 |
|---|---|---|
| `secure-response-object` | Signed authorization response (JARM) | MCP clients don't request signed responses; FAPI-tier |
| `secure-request-object` / `signed-request` [?] | Signed request objects (JAR) | MCP clients send plain auth requests; FAPI-tier |
| `secure-signature-algorithm` / `secure-signature-algorithm-signed-jwt` [?] | Specific signing algs on client-signed artifacts | MCP clients don't sign artifacts in this flow |
| `holder-of-key` / `dpop` [?] | Sender-constrained (DPoP / mTLS) tokens | Stricter than MCP v1 needs; possible future hardening |
| `secure-client-authenticator` [?] | Restricts client auth methods (e.g. require mTLS/private-key-JWT) | MCP public clients use `none` (PKCE-protected); this would break them |
| `secure-client-uris-pattern` | URI pattern allowlist | Reintroduces localhost/vendor-domain problem; see above |

These are **compliance hardening you can layer on later** if you ever need FAPI-grade security (e.g. an enterprise/regulated customer requires it). Don't add them speculatively — each one risks breaking MCP clients, and none is needed for the v1 threat model (which is handled by PKCE + secure redirect URIs + consent + audience validation + server-side RBAC).

Save.

### D.6b Policy `mcp-anonymous-dcr`

Policies tab → **Create policy** [?]:
- **Name:** `mcp-anonymous-dcr`
- **Description:** "Apply mcp-hardening to anonymously DCR'd clients"
- **Enabled:** **On**

Add condition: **Condition type:** `client-updater-context`. **Update Client Source:** select **`ByAnonymous` ONLY**.

⚠️ **Select only `ByAnonymous`. Do NOT also select `ByAuthenticatedUser`.** The source is a multi-select, and it's easy to leave `ByAuthenticatedUser` checked. But `ByAuthenticatedUser` matches any client created or updated **by an authenticated user — including an admin editing a client in the console.** With it selected, this policy matches your first-party clients (`yourapp-{env}-web`, `yourapp-{env}-admin-api`) every time you edit them, and the `mcp-hardening` profile's executors get force-applied to them. The most visible symptom: the `consent-required` executor (auto-configure) sets `consentRequired = true` on the web client, so regular users start seeing Keycloak's "Grant Access to …" consent screen on login. `ByAnonymous` alone matches only anonymously-registered DCR clients (your MCP clients), which is the entire intent.

Add profile reference: `mcp-hardening`.

Save.

**Verify:** Smoke tests 22, 23, 24 (DCR rejects bad inputs) exercise this indirectly after §D.12.

## D.7 Assign MCP scopes to DCR'd clients

**⚠️ Do NOT set these as realm-default scopes.** Doing so assigns `mcp-default` to *every* client including `yourapp-{env}-web`, which pollutes non-MCP clients and breaks the SPI short-circuit's MCP-client detection. Keep `mcp-default` and the `yourapp:*` scopes as **`None`** assigned type (not auto-attached to any client).

**Settled: the McpClientRegistrationPolicy CRP assigns these at registration (SPI design §5.8, D.8).** The CRP assigns, on each DCR'd MCP client, atomically at registration:
- **Default:** `mcp-default`, `yourapp:read`, `yourapp:comment`, `yourapp:curate`, `yourapp:write`, `yourapp:share`
- **Optional:** `yourapp:admin`

This replaces the earlier plan of assigning scopes from the app at `/mcp/consent` (which was too late for the first authorization's MCP detection — see D.8). The app's `/mcp/consent` may still assign idempotently as belt-and-suspenders, but the CRP is the authoritative bootstrap.

For **manual testing** before the CRP is deployed, assign these to your throwaway test client by hand (client → Client scopes tab → Add).

## D.8 Bind the browser flow to MCP clients

**The problem this solves:** DCR'd MCP clients must authenticate through `browser-mcp-tenant-pick` (the flow with your SPI step) so the consent handoff fires. Something must bind that flow to those clients — and critically, it must happen **before the client's first authorization**, or that first login falls through the realm-default flow, shows Keycloak's own consent, and never reaches the app.

### ✅ Recommended: the McpClientRegistrationPolicy CRP binds at registration (atomic)

**Settled design:** a custom **Client Registration Policy** (`McpClientRegistrationPolicy`, SPI design §5.8) marks every MCP client **atomically at registration time** — it assigns `mcp-default` + the author bundle as default scopes, sets a `yourapp.mcp=true` attribute, and binds the `browser-mcp-tenant-pick` flow, all on the `ClientModel` inside the registration transaction. Because it's in-transaction, either the client registers fully-marked or registration rolls back — **no partial states, and the first authorization already routes through the MCP flow.** This closes the bootstrapping gap (a fresh client couldn't otherwise be detected as MCP on its first login).

- Realm default browser flow **stays `browser-federated-only`** — web login is never affected by MCP flow issues. **Never bind the MCP flow realm-wide.**
- The CRP does the scope + flow **bootstrap**; the app's `/mcp/consent` still does the tenant-picker wizard and the `mcp_provisioned_clients` record (web spec §7.5). Both are idempotent, so both touching the client is safe.
- **Deploy the CRP** as an **anonymous** Client Registration Policy: Clients → Client registration → Anonymous Access Policies (same CRP system as Trusted Hosts). See SPI design §5.8 for the interface and the anonymous-binding rationale.
- **For manual testing** before the CRP is built/deployed: on a throwaway test client, set `authenticationFlowBindingOverrides.browser` to `browser-mcp-tenant-pick` via the client's **Advanced** tab (Authentication flow overrides → Browser Flow), and assign the MCP scopes per D.7 by hand.

**Why not bind at `/mcp/consent` (the earlier plan)?** Binding at first `/mcp/consent` is too late: to *reach* `/mcp/consent`, the SPI in `browser-mcp-tenant-pick` must run, which requires the client already be bound to that flow — a circular dependency. The first authorization would fall through `browser-federated-only`, show Keycloak's native consent, and never provision. Binding at registration (this CRP) breaks the cycle. The app may still bind idempotently as a belt-and-suspenders, but correctness comes from the CRP.

**Why not Option A (realm-wide binding)? NOT recommended.**
- Action would be: Authentication → Bindings → Browser Flow → `browser-mcp-tenant-pick`.
- **Why not:** any MCP-flow bug breaks *all* logins (observed in testing — a malformed flow bound realm-wide returns HTTP 400 for every login). Per-client binding via the CRP confines any MCP-flow problem to MCP clients. The SPI short-circuit remains only as a safety net for this misconfiguration, not as a relied-upon control.

**Do not bind the MCP flow realm-wide.**

## D.9 OAuth 2.1 token settings (refresh token rotation)

**Path:** Realm settings → Tokens

⚠️ **Do not enable strict rotation until the app implements single-flight token refresh (PRD §8.6.1).** Refresh-token rotation is realm-wide, so it applies to the confidential web client too. If the app fires concurrent authenticated requests that each independently refresh the same session's token (the default SPA behavior), strict rotation (`Max Reuse = 0`) causes the losing requests to hit "Maximum allowed refresh token reuse exceeded," which triggers session revocation and logs users out. This was observed in production on 2026-07-02.

**Sequencing:**
- **Interim (until the app ships single-flight refresh): leave `Revoke Refresh Token` Off.** A `Refresh Token Max Reuse` grace window is **not reliable** here — it only tolerates the "reuse exceeded" error, while concurrent rotation also triggers a separate "Session doesn't have required client" error that the reuse counter doesn't govern. Observed in production: `Max Reuse = 5` did not stop the logouts; only turning rotation off did. Also note the setting applies to newly issued tokens, so testing a grace change requires a fresh login.
- **Target (after PRD §8.6.1 is implemented and verified):** `Revoke Refresh Token` **On**, `Refresh Token Max Reuse` = `0`. Strict rotation matters most for the MCP clients (public, tokens on the user's machine); the confidential web client tolerates it once single-flight refresh is in place.

Settings:
- **Revoke Refresh Token:** On (target) — but see sequencing above before enabling with maxReuse=0.
- **Refresh Token Max Reuse:** `0` (target) / small grace value (interim).
- Save.

**Verify:** `./smoke.sh` → Test 19. It now recognizes three states (strict / grace / off) and reminds you of the §8.6.1 app prerequisite rather than pushing you straight to strict.

## D.10 Ensure the password grant (ROPC) is disabled where it shouldn't be

**Goal:** no client should be able to use the Resource Owner Password Credentials grant (`grant_type=password`). yourapp.com is federated-only — there are no local passwords to grant against, so ROPC has no legitimate use (Invariant 1).

⚠️ **The old "Authentication → Bindings" tab does not exist in 26.x**, and the `direct grant` **flow** (Authentication → Flows → `direct grant`) is *not* the right lever — that flow only defines *how* a direct-grant request is authenticated *if a client is allowed to make one*. The actual on/off control is **per client**:

**The real control — per-client "Direct access grants" capability:**
- **Clients → `yourapp-{env}-web` → Settings → Capability config → "Direct access grants" → Off.** (Already off — smoke Test 11 verifies `directAccessGrantsEnabled=false`.)
- **Clients → `yourapp-{env}-admin-api` → same → Off.** (Already off — service account uses client-credentials, not ROPC.)

⚠️ **DCR'd MCP clients — important nuance.** No *redirect/response* executor rejects a DCR registration for requesting `grant_types:["password"]`. But Keycloak **does** have a purpose-built executor for ROPC: **`reject-resource-owner-password-credentials-grant`** (a.k.a. `reject-ropc`). Use it. Layer the controls so no single failure re-enables ROPC:

**Layer 1 — per-client capability (already done):**
- **Clients → `yourapp-{env}-web` → Settings → Capability config → "Direct access grants" → Off.** (Smoke Test 11 verifies.)
- **Clients → `yourapp-{env}-admin-api` → same → Off.**

**Layer 2 — `reject-ropc` executor (primary, declarative control):**
Add the **`reject-resource-owner-password-credentials-grant`** executor to a client-policy profile. For a realm-wide guarantee (correct here — federated-only means ROPC has zero legitimate use for *any* client), bind it via a policy with an **`any-client`** condition, not only the anonymous-DCR policy. This is cleaner than the old "neuter the flow" approach: it's declarative, lives with your other executors, and fails with a clear token-endpoint error instead of the confusing "flow has no executions" behavior.

> 🔴 **SECURITY — CVE-2026-9792 (know this before relying on reject-ropc).** A flaw allows `reject-ropc` to be **silently bypassed** when the *policy* carrying it uses `client-type`, `client-roles`, `client-attributes`, or `client-scopes` conditions — an attacker can then still obtain tokens via ROPC even though the policy looks configured to block it. **Mitigations:** (1) **Patch** — confirm your Keycloak build includes the fix (filed May 2026; verify 26.6.x patch level and upgrade if needed — this is a security patch for your IdP regardless of ROPC). (2) **Bind reject-ropc via an `any-client` condition, NOT the affected condition types.** (3) **Don't rely on it alone** — keep Layers 1 and 3 too. The CVE is precisely why single-layer ROPC control isn't enough.

**Layer 3 — neuter the Direct Grant flow (backstop the CVE can't bypass):**
- **Authentication → Flows → `direct grant`** → set its executions to **Disabled**. Because the CVE bypasses the *client-policy* layer specifically, a control at the *flow* layer is what still holds if reject-ropc is bypassed. For a federated-only realm (no local passwords, Invariant 1) this is correct and costs nothing.

**Why all three:** each fails independently. The per-client toggle is a client flag (CVE-unaffected); reject-ropc is the clean primary control (but CVE-bypassable via bad conditions); the disabled flow is a different-layer backstop. For a realm where ROPC must *never* work, layered is right.

**Verify — the smoke test checks the EFFECT, not the config (which is why it catches a silently-bypassed control):** `./smoke.sh` → `Web client / Admin API Direct Access Grants` `disabled` (Test 11); **`Password grant unusable (DCR)` green (Test 23)**. Test 23 registers a DCR client requesting the password grant (expects 201) then confirms `grant_type=password` **yields no token**. Because it tests whether a token is actually issued — not whether reject-ropc is "configured" — it would catch a CVE-2026-9792 bypass. If Test 23 ever goes red, ROPC is live: check the patch level, the policy condition type, and that the flow is disabled.

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

# SECTION F: Deferred DCR Hardening

> **Source of truth for all deferrals:** `DEFERRED_ITEMS.md` — the consolidated register with triggers and blast-radius for every consciously-postponed item across all the auth docs. Review it before public GA. This section covers the *how* for the DCR-specific rows (B1–B3); the register says *whether/when/what-if-forgotten*.

These Client Registration Policies were removed (or never added) during initial v1 setup to unblock development. None is a launch-blocker at friends-of-founders scale where you control the whole surface. All should be revisited before the MCP surface is exposed to untrusted third-party clients (roughly: before public GA, or before anyone you don't know registers clients against prod). Build them as **one hardening pass**, not piecemeal.

**The set (register rows B1–B3):**
- **F.1 Trusted Hosts** (register B2) — constrain redirect-URI hosts.
- **F.2 Allowed Protocol Mapper Types** (register B3) — constrain self-attached mappers.
- **F.3 Custom `AllowedGrantTypesPolicy` SPI** (register B1) — reject disallowed grant types at registration. See below.

## F.0 Custom grant-types registration policy (register B1)

**What:** a custom `ClientRegistrationPolicy` SPI provider that rejects a DCR registration requesting disallowed grant types (password/implicit/client_credentials on public clients) with a 400 — *fail-at-registration* instead of the current *fail-at-token-time*. Full spec in `KEYCLOAK_MCP_SPI_DESIGN.md` §13a.1 (interface, packaging, allowed-grants set).

**Important — this is NOT currently a security gap.** ROPC is already blocked by the disabled Direct Grant flow (D.10, verified by smoke Test 23). This SPI adds cleaner rejection ergonomics and broader registration-time enforcement (auth method, response types), and is the right home for the whole registration-time grant posture. It's deferred because (a) the existing control already provides the security property, and (b) it's a second SPI, doubling Keycloak-version-coupling maintenance.

**Trigger:** the DCR-hardening milestone — build it alongside F.1 and F.2. When deployed, smoke Test 23 will flip from "registered 201 but ROPC unusable" to "registration rejected outright" automatically (no test change needed).

## F.1 Trusted Hosts — when and how to re-add

> **⚠️ Trusted Hosts is NOT an executor. Two different systems govern DCR:**
> 1. **Client Policies** (newer) — Realm settings → *Client policies* tab → profiles + **executors** (this is where `mcp-hardening` and `secure-redirect-uris-enforcer` live). If you're looking at the executor list, you will NOT find Trusted Hosts here.
> 2. **Client Registration Policies (CRP)** (older) — Clients → *Client registration* → **Trusted Hosts** lives here, alongside Allowed Client Scopes, Allowed Protocol Mappers, etc. (In the log/API these are `type=...ClientRegistrationPolicy` components.)
>
> Both systems can reject a DCR registration, which is why their errors look similar. Deleting Trusted Hosts (a CRP) does **not** affect the redirect-URI executor (a Client Policy) and vice-versa — they're independent. Keycloak's roadmap is to eventually fold CRPs into Client Policies, but in 26.6.0 both are active. **Design note (register B2):** because the executor system is the future, part of the pre-GA decision is whether to re-add the legacy Trusted Hosts CRP *at all*, versus using an executor-based or custom-SPI control. For the isolation test now, re-adding the CRP is fine to characterize its behavior.

**Add back when:** you want to constrain which redirect-URI hosts DCR'd clients may use, i.e., before untrusted parties can register against prod. It's a meaningful control against a class of token-redirection attacks (an attacker registering a client whose redirect URI points at infrastructure they control).

**Why it was removed (historical):** during early dev the handling of `localhost:<arbitrary-port>` for desktop/CLI MCP clients was unverified, so rather than fight it, it was deleted. **This is now resolved** — testing (2026-07-05) confirmed Trusted Hosts matches on host regardless of port, so it works fine for loopback clients. Keep it on.

**Path:** Clients → **Client registration** → **Anonymous Access Policies** → Create policy → **Trusted Hosts**. (This is the CRP system — a different tab from Client policies/executors above.)

**Configuration:**
- **Host Sending Client Registration Request Must Match:** OFF — MCP clients POST the DCR request from wherever the end user is (laptops, CI, arbitrary networks); their source IP is unpredictable and can't be whitelisted.
- **Client URIs Must Match:** ON — this is the toggle that does the useful work; it constrains redirect URIs to hosts in the list below.
- **Trusted Hosts list:** the hostnames legitimate MCP redirect URIs will use. Start with:
  - `localhost` and `127.0.0.1` — for desktop/CLI clients (Claude Desktop, Cursor, CLI tools) that use loopback redirect URIs
  - Any known vendor domains for web-hosted MCP clients you intend to support

**✅ localhost-port behavior — VERIFIED (2026-07-05).** The open question that caused the original removal is resolved: with `localhost` in the Trusted Hosts list and "Client URIs Must Match" ON, a DCR registration with `"redirect_uris":["http://localhost:53789/callback"]` (an arbitrary high port) **succeeds** — Trusted Hosts matches on host regardless of port. So Trusted Hosts is viable to keep ON for GA: it constrains redirect hosts (real protection) while allowing legitimate loopback MCP desktop clients on any port. **Include both `localhost` AND `127.0.0.1` in the trusted list** — the executor (`secure-redirect-uris-enforcer`) and Trusted Hosts spell loopback differently (RFC 8252 `127.0.0.1` vs Keycloak's `localhost` normalization), so listing both ensures either redirect spelling a client uses satisfies both policies. (Confirm the `127.0.0.1` literal form specifically if your clients use it.)

**Interaction with the DCR smoke test (D.12):** if you re-add Trusted Hosts with "Client URIs Must Match" ON, the D.12 test's default `https://example.com/callback` redirect URI will be **rejected** unless `example.com` is in the trusted list. Update the test's redirect URI to a trusted host, or temporarily add `example.com` to the list while testing, or run the DCR test before re-adding this policy.

## F.2 Allowed Protocol Mapper Types — when and how to re-add

**Add back when:** before exposing DCR to untrusted third parties. It's defense-in-depth, not a primary control — see the "why it's optional" reasoning below.

**Why it's optional for v1:** this policy restricts which protocol-mapper *types* a DCR'd client may attach **to itself** during registration. The security-critical claims (`aud`, `tenant`, `scope`) come from mappers on the `mcp-default` **client scope**, which DCR'd clients inherit but cannot modify. A rogue self-attached mapper can only inject claims the yourapp.com MCP resource server should be ignoring anyway. So the primary defense is server-side: the MCP server trusts only the claims it expects (`aud == yourapp-mcp-api`, `tenant`, `scope`, `sub`) and ignores anything else a client may have injected. This policy is a belt-and-suspenders layer on top of that.

**Path:** Clients → Client Registration → Anonymous Access Policies → Create policy → **Allowed Protocol Mapper Types**.

The config presents a multi-select list of mapper types **by provider ID** (verified in 26.6.0 — e.g. `oidc-sub-mapper`, not a friendly name). Your SPI's `yourapp-mcp-scope-override` appears in this list (confirms the SPI registered the mapper for policy enumeration).

**Configuration — select these seven provider IDs** (the ones legitimately needed by DCR'd MCP clients):
- `oidc-audience-mapper`
- `oidc-usersessionmodel-note-mapper`
- `yourapp-mcp-scope-override` (your SPI's custom mapper)
- `oidc-sub-mapper`
- `oidc-full-name-mapper`
- `oidc-usermodel-attribute-mapper`
- `oidc-usermodel-property-mapper`

Anything not on the list is rejected at registration time. Note: because the security-critical mappers live on the `mcp-default` client scope (not attached by the client), you could whitelist an even narrower set — the standard OIDC built-ins only — and DCR'd clients would still function. Start with the list above and tighten if you have a reason to.

**Verify after re-adding:** run the D.12 DCR test; a compliant registration should still succeed (201). If it fails, the error names a mapper type the registration needs that isn't whitelisted — add that provider ID and retry. Optionally, test that a registration attempting to attach a non-whitelisted mapper type (e.g., `oidc-hardcoded-claim-mapper`) is rejected.

---

*End of Keycloak Setup Guide.*
