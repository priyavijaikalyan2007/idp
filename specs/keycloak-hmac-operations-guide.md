# Keycloak MCP Handoff HMAC — Operations Guide

Operator-facing guide for creating, distributing, rotating, and emergency-revoking the HMAC keys that protect the MCP picker-request and picker-result JWTs exchanged between the Keycloak SPI (this repo) and Knobby web's `/mcp/consent` endpoint.

**One Keycloak instance, multiple realms, multiple keys.** This repo deploys a single Keycloak service that hosts three realms — `knobby-prod`, `knobby-dev`, and (when it exists) `knobby-test`. Each realm holds its **own** HMAC key, paired with its own Knobby web environment. A leak in one realm must not compromise another. All procedures below are per-realm; you can rotate prod without touching dev.

**Audience:** Platform operators and on-call. Not for application developers — app code only reads keys via env var and never sees raw values during normal operation.

**Companion specs:**
- `keycloak.spi.mcp.md` §7 — defines the env-var contract this guide provisions.
- `KEYCLOAK_AUTH_PRD.md` §16.8.5 — defines the rotation policy and overlap window.

---

## 1. What this key does

For each realm, a single shared HMAC-SHA256 key signs and verifies both legs of the MCP consent handoff:

| Direction | Producer | Consumer | Token TTL |
|---|---|---|---|
| Keycloak realm `R` → matching Knobby web | Keycloak SPI signs `picker_request` with realm `R`'s key | Knobby web validates with realm `R`'s key | 5 min |
| Knobby web → Keycloak realm `R` | Knobby web signs `picker_result` with realm `R`'s key | Keycloak SPI validates with realm `R`'s key | 1 min |

Both sides hold the **same** key value **per realm**. Both sides support a current key and an optional previous key per realm, for zero-downtime rotation. There are no asymmetric keypairs in this path — the picker handoff is a closed system between two trusted services we operate.

The Keycloak realm's OIDC token signing keys (issued to MCP clients) are **separate** and managed by Keycloak's own key-rotation features — out of scope for this guide.

---

## 2. Naming conventions

These names are normative. Both sides must use them verbatim — the SPI reads env vars by these exact names (`keycloak.spi.mcp.md` §7.1), and Knobby web will read the same names by convention.

### Environment variables (read at runtime by the application)

For each realm `R` (where `<R>` is the realm name uppercased with `-` replaced by `_`):

| Variable | `<R>` resolved | Required? | Description |
|---|---|---|---|
| `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` | `KNOBBY_PROD`, `KNOBBY_DEV`, `KNOBBY_TEST` | Per realm using the SPI | Current key, base64-encoded 32 bytes (256 bits). |
| `KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__<R>` | same | Only during rotation | Prior key, same encoding. Removed once in-flight tokens have expired. |

The double-underscore (`__`) before the realm suffix is intentional and load-bearing: it makes the boundary between the fixed prefix and the realm suffix unambiguous when parsing.

Use these names on **Keycloak** and **Knobby web** alike. Do not rename per side.

There is **no** `KNOBBY_WEB_HOST` env var. The Knobby web hostname for each realm is configured per-realm in Keycloak's admin console as an Authenticator config property (`knobby.web.host`) — see `keycloak.spi.mcp.md` §7.3.

### Secret Manager resource names

Per-realm secrets — never reuse a single secret across realms:

| Realm | Current key secret | Previous key secret (rotation only) |
|---|---|---|
| `knobby-prod` | `knobby-mcp-handoff-hmac-key-knobby-prod` | `knobby-mcp-handoff-hmac-key-knobby-prod-previous` |
| `knobby-dev` | `knobby-mcp-handoff-hmac-key-knobby-dev` | `knobby-mcp-handoff-hmac-key-knobby-dev-previous` |
| `knobby-test` | `knobby-mcp-handoff-hmac-key-knobby-test` | `knobby-mcp-handoff-hmac-key-knobby-test-previous` |

Secret names are kebab-case mirroring the env-var suffix (just lowercased and joined with hyphens). The suffix-by-realm-name convention keeps secret names recognizable at a glance and aligns Secret Manager browsing with realm taxonomy.

### Key value format

- **Length:** exactly 32 bytes (256 bits) — the SPI rejects anything else.
- **Encoding:** standard base64 (with `+`, `/`, `=` padding). **Not** base64url. The SPI uses `java.util.Base64.getDecoder()`.
- **Source:** cryptographically secure RNG (`openssl rand` or `/dev/urandom`).

---

## 3. Initial setup — one-time per realm

Do this once per realm (`knobby-prod`, `knobby-dev`, and `knobby-test` when it exists). All commands target GCP; adapt if Knobby web is hosted on a different platform (see §3.5).

### 3.1 Prerequisites

- `gcloud` CLI authenticated as a principal with `roles/secretmanager.admin` in the target GCP project.
- `openssl` available locally.
- The GCP project ID hosting the shared Keycloak deployment.
- The service-account email for each consumer (Keycloak Cloud Run runtime SA and Knobby web runtime SA for the matching environment).

Set these as shell variables. The realm name drives every other name:

```bash
REALM=knobby-prod                                           # or knobby-dev, knobby-test
REALM_SUFFIX=$(echo "$REALM" | tr 'a-z-' 'A-Z_')            # → KNOBBY_PROD
SECRET_NAME=knobby-mcp-handoff-hmac-key-${REALM}            # kebab-case mirror

PROJECT_ID=knobby-idp                                       # adjust to actual project hosting Keycloak
KEYCLOAK_SA=keycloak-runtime@${PROJECT_ID}.iam.gserviceaccount.com
KNOBBY_WEB_SA=knobby-web-runtime@${PROJECT_ID}.iam.gserviceaccount.com   # adjust if Knobby web is in a different project
```

### 3.2 Generate the key

```bash
KEY=$(openssl rand -base64 32)
[ ${#KEY} -eq 44 ] && echo "OK: 44 chars" || { echo "FAIL: length ${#KEY}"; return 1; }
```

44 chars = 32 bytes base64-encoded with padding.

### 3.3 Store in Secret Manager

```bash
gcloud secrets create "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --replication-policy=automatic \
    --labels="purpose=mcp-handoff-hmac,realm=${REALM}"

printf '%s' "$KEY" | gcloud secrets versions add "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --data-file=-
```

Use `printf '%s'` (not `echo`) — `echo` appends a newline, which the SPI would then fail to base64-decode as 32 bytes.

### 3.4 Stash an offline copy

Before unsetting the shell variable, store `$KEY` in your team password vault (1Password, Bitwarden, etc.) under an entry named `knobby/mcp-handoff-hmac/${REALM}/current`. This is the **only** copy outside Secret Manager; treat it as such. If Secret Manager is ever corrupted or accidentally deleted, this is your recovery copy.

```bash
unset KEY
```

Never paste the key into Slack, email, ticket bodies, log statements, or commit messages.

### 3.5 Grant runtime access

```bash
# Keycloak (this repo) — required immediately.
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${KEYCLOAK_SA}" \
    --role="roles/secretmanager.secretAccessor"

# Knobby web (matching environment) — required when /mcp/consent ships. Safe to grant now.
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${KNOBBY_WEB_SA}" \
    --role="roles/secretmanager.secretAccessor"
```

If Knobby web runs on a platform other than GCP Cloud Run, mirror the value into that platform's secret store at provision time and confirm with a SHA-256 fingerprint match (see §6.4). Update this guide with the exact procedure when that platform is chosen.

### 3.6 Wire env vars into the container runtime

#### Keycloak — GCP Cloud Run (this repo)

Edit `cloudrun.yaml`. The Keycloak container's `env:` block accumulates one entry per realm that uses the SPI:

```yaml
env:
  # knobby-prod
  - name: KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD
    valueFrom:
      secretKeyRef:
        name: knobby-mcp-handoff-hmac-key-knobby-prod
        key: latest
  # knobby-dev
  - name: KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_DEV
    valueFrom:
      secretKeyRef:
        name: knobby-mcp-handoff-hmac-key-knobby-dev
        key: latest
  # knobby-test — uncomment when the realm is created and the secret exists
  # - name: KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_TEST
  #   valueFrom:
  #     secretKeyRef:
  #       name: knobby-mcp-handoff-hmac-key-knobby-test
  #       key: latest
```

Notes:
- `key: latest` resolves at revision-deploy time, not request time. After rotating any realm's secret (§4), redeploy Cloud Run to pick up the new version.
- Do **not** add `KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__<R>` entries during steady state — only during a rotation window for the realm being rotated.
- Commit the `cloudrun.yaml` change. The secret names are not sensitive; the secret values are.
- The Knobby web hostname per realm is **not** an env var on Keycloak. It is configured per-realm in the Keycloak admin console as an Authenticator config property (`knobby.web.host`) on the `browser-mcp-tenant-pick` flow's Authenticator step — see `keycloak.spi.mcp.md` §7.3 and `KEYCLOAK_AUTH_PRD.md` §16.11.

Apply via `./deploy.sh` (rolls Cloud Run to a new revision).

#### Knobby web — env per its deployment platform

Document Knobby web's wiring in its own repo when MCP work activates. The shape is identical: same `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` env-var name per environment, populated from the same Secret Manager secret. Each Knobby web environment reads exactly one realm's key (prod Knobby web reads `KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD`, dev reads `KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_DEV`, etc.). Cross-reference this guide from Knobby web's repo.

### 3.7 Configure the per-realm Knobby web host (admin console)

In Keycloak's admin console, for realm `R`:

1. **Authentication** → **Flows** → `browser-mcp-tenant-pick` → expand to find the `Knobby MCP Tenant Picker` Authenticator step.
2. **Actions** → **Config** (or the gear icon).
3. Set **Knobby web host** (`knobby.web.host`) to the matching hostname:
   - `knobby-prod` → `prod.knobby.io`
   - `knobby-dev` → `dev.knobby.io`
   - `knobby-test` → `test.knobby.io` (or whatever is decided when the realm is created)
4. Save.

This value is captured by realm export. If you re-import a realm, the value is reinstated.

### 3.8 Verify

After Cloud Run rolls the new revision:

```bash
./monitor.sh    # stream logs
```

Expect a startup line confirming the realms with HMAC keys loaded:

```
INFO Loaded MCP SPI provider knobby-mcp-tenant-picker.
     HMAC keys configured for realms: [knobby-prod, knobby-dev]
```

Then run the smoke suite:

```bash
./smoke.sh
```

Test 14 (SPI loaded) must pass for any realm using the SPI. The handoff round-trip (Test 33) will not pass until Knobby web's `/mcp/consent` ships.

---

## 4. Rotation procedure — scheduled, per-realm

Rotate each realm's key at least every 90 days. The procedure overlaps two keys for that realm so neither side experiences a validation failure during the window. Other realms are unaffected.

### 4.1 When to rotate

- **Scheduled:** every 90 days per realm, tracked in the team calendar.
- **On personnel change:** any operator with vault access leaves the team — rotate all realms.
- **On suspected exposure:** see §5 (emergency rotation) — the steps differ.

### 4.2 Pre-flight check

Confirm both sides currently run on the realm's current key alone (no `_PREVIOUS__<R>` env var set on either):

```bash
REALM=knobby-prod
REALM_SUFFIX=$(echo "$REALM" | tr 'a-z-' 'A-Z_')

gcloud run services describe knobby-keycloak \
    --project="$PROJECT_ID" --region="$REGION" \
    --format='value(spec.template.spec.containers[0].env[].name)' \
    | grep -E "^KNOBBY_MCP_HANDOFF_HMAC_KEY(_PREVIOUS)?__${REALM_SUFFIX}$"
```

If `_PREVIOUS__<R>` is still wired from a previous rotation of this realm, finish §4.7 of that prior rotation first.

### 4.3 Generate the new key

```bash
NEW_KEY=$(openssl rand -base64 32)
[ ${#NEW_KEY} -eq 44 ] || { echo "FAIL: bad length"; return 1; }
```

### 4.4 Promote current → previous, install new → current

```bash
REALM=knobby-prod                                             # or whichever realm is being rotated
CURRENT=knobby-mcp-handoff-hmac-key-${REALM}
PREVIOUS=knobby-mcp-handoff-hmac-key-${REALM}-previous

# Read the current key value into memory.
CURRENT_KEY=$(gcloud secrets versions access latest \
    --project="$PROJECT_ID" --secret="$CURRENT")

# Ensure the -previous secret container exists (idempotent).
gcloud secrets describe "$PREVIOUS" --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud secrets create "$PREVIOUS" \
        --project="$PROJECT_ID" \
        --replication-policy=automatic \
        --labels="purpose=mcp-handoff-hmac,realm=${REALM},role=previous"

# Promote: previous secret now holds the (soon-to-be) old current key.
printf '%s' "$CURRENT_KEY" | gcloud secrets versions add "$PREVIOUS" \
    --project="$PROJECT_ID" --data-file=-

# Install: current secret now holds the new key.
printf '%s' "$NEW_KEY" | gcloud secrets versions add "$CURRENT" \
    --project="$PROJECT_ID" --data-file=-

# Stash the new key in the team vault under knobby/mcp-handoff-hmac/${REALM}/current.
# Move the prior vault entry to knobby/mcp-handoff-hmac/${REALM}/previous.

unset CURRENT_KEY NEW_KEY
```

Grant the same IAM bindings on `$PREVIOUS` as on `$CURRENT` (one-time per realm; idempotent):

```bash
for SA in "$KEYCLOAK_SA" "$KNOBBY_WEB_SA"; do
    gcloud secrets add-iam-policy-binding "$PREVIOUS" \
        --project="$PROJECT_ID" \
        --member="serviceAccount:${SA}" \
        --role="roles/secretmanager.secretAccessor"
done
```

### 4.5 Add the `_PREVIOUS__<R>` env var on both sides, deploy

For example, rotating `knobby-prod`:

```yaml
env:
  - name: KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD
    valueFrom:
      secretKeyRef:
        name: knobby-mcp-handoff-hmac-key-knobby-prod
        key: latest
  - name: KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__KNOBBY_PROD       # add this
    valueFrom:
      secretKeyRef:
        name: knobby-mcp-handoff-hmac-key-knobby-prod-previous
        key: latest
  # Other realms unaffected — leave them alone.
  - name: KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_DEV
    valueFrom:
      secretKeyRef:
        name: knobby-mcp-handoff-hmac-key-knobby-dev
        key: latest
```

Deploy:

```bash
./deploy.sh
```

Do the equivalent on the matching Knobby web environment (e.g., prod Knobby web for the `knobby-prod` rotation). Other Knobby web environments are not involved.

Order does not matter — both sides accept either key during the overlap.

### 4.6 Wait out the overlap window

Wait **at least 15 minutes** after both deployments complete. Rationale:

- Longest token TTL is `picker_request` at 5 minutes (`keycloak.spi.mcp.md` §6.1).
- Plus deploy propagation, client retry windows, and clock skew tolerance.
- 15 minutes is a comfortable margin; longer is harmless.

During the wait, run `./smoke.sh` on Keycloak and exercise the consent flow on the matching Knobby web environment (when available). Both should pass.

### 4.7 Remove `_PREVIOUS__<R>` from both sides, deploy

Edit `cloudrun.yaml` and remove the `KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__<R>` env entry for the realm just rotated. Deploy:

```bash
./deploy.sh
```

Do the equivalent on the matching Knobby web environment.

### 4.8 Destroy the previous key version (recommended)

After 24 hours of healthy operation on the new key alone:

```bash
gcloud secrets versions destroy $(gcloud secrets versions list "$PREVIOUS" \
    --project="$PROJECT_ID" --format='value(name)' --limit=1) \
    --project="$PROJECT_ID"
```

Leave the empty `$PREVIOUS` secret container in place — it will be reused on the next rotation of this realm.

Remove the matching offline copy from the team vault.

### 4.9 Record the rotation

Append an entry to `agentknowledge/history.jsonl`:

```json
{"date":"2026-06-07","task":"hmac rotation","realm":"knobby-prod","operator":"<your-name>","summary":"Rotated knobby-mcp-handoff-hmac-key-knobby-prod. Overlap window 15 min. No incidents."}
```

---

## 5. Emergency rotation — suspected compromise of one realm

Use this procedure if a realm's key may have been exposed (leaked credential, lost laptop with vault access, unexpected secret access in audit logs, etc.). The goal is to invalidate the old key as fast as possible, accepting some user-facing breakage of in-flight consent flows for that realm.

Other realms are not affected by a single-realm compromise.

### 5.1 Decide whether to overlap

| Threat | Overlap? | Why |
|---|---|---|
| Possible exposure, no evidence of active use | Yes (15-min window, §4) | Standard rotation; preserves UX. |
| Confirmed exposure or active misuse | **No** | Skip overlap; cut over immediately. In-flight consent flows in this realm fail and users must restart — acceptable cost. |

### 5.2 Cut-over without overlap

```bash
REALM=knobby-prod                                             # the compromised realm
REALM_SUFFIX=$(echo "$REALM" | tr 'a-z-' 'A-Z_')
CURRENT=knobby-mcp-handoff-hmac-key-${REALM}

NEW_KEY=$(openssl rand -base64 32)
printf '%s' "$NEW_KEY" | gcloud secrets versions add "$CURRENT" \
    --project="$PROJECT_ID" --data-file=-
unset NEW_KEY

# DO NOT promote the old key to _PREVIOUS — that would keep it valid.
# DO NOT wire _PREVIOUS__<R> env vars.

./deploy.sh                 # Keycloak
# Equivalent deploy on the matching Knobby web environment — coordinate so both flip within minutes.
```

### 5.3 Destroy all prior versions of the current secret

```bash
gcloud secrets versions list "$CURRENT" --project="$PROJECT_ID" --format='value(name)' \
    | tail -n +2 \
    | xargs -I {} gcloud secrets versions destroy {} --secret="$CURRENT" --project="$PROJECT_ID"
```

### 5.4 Audit

```bash
gcloud logging read \
    "protoPayload.serviceName=\"secretmanager.googleapis.com\"
     AND protoPayload.resourceName=~\"knobby-mcp-handoff-hmac-key-${REALM}\"" \
    --project="$PROJECT_ID" \
    --format=json \
    --freshness=30d
```

Review for any access by principals other than the expected runtime service accounts.

### 5.5 File an incident record

Create `playbooks/incident-<date>-hmac-compromise-${REALM}.md` documenting the timeline, scope of suspected exposure, cut-over time, and audit findings. Link from the on-call channel.

### 5.6 Consider cross-realm exposure

If the same person or process had access to multiple realms' keys (e.g., a single operator with vault access to all realms), rotate all realms — repeat §5.2–§5.5 for each. Per-realm isolation defends against an HMAC key leaking *in isolation*; it does not defend against a compromised operator.

---

## 6. Verification and troubleshooting

### 6.1 Confirm the SPI loaded keys for the expected realms

```bash
./logs.sh | grep -i 'HMAC keys configured for realms'
```

Expected line at startup:

```
INFO Loaded MCP SPI provider knobby-mcp-tenant-picker.
     HMAC keys configured for realms: [knobby-prod, knobby-dev]
```

If a realm you expected is missing, the env var is not wired in `cloudrun.yaml`.

### 6.2 Confirm the env var binding for a specific realm

```bash
REALM=knobby-prod
REALM_SUFFIX=$(echo "$REALM" | tr 'a-z-' 'A-Z_')

gcloud run services describe knobby-keycloak \
    --project="$PROJECT_ID" --region="$REGION" \
    --format='value(spec.template.spec.containers[0].env)' \
    | grep -E "KNOBBY_MCP_HANDOFF_HMAC_KEY(_PREVIOUS)?__${REALM_SUFFIX}"
```

### 6.3 Confirm a secret value is non-empty and correctly encoded

```bash
gcloud secrets versions access latest --secret="$CURRENT" --project="$PROJECT_ID" \
    | wc -c
# Expect: 44 (standard base64 of 32 bytes, no trailing newline)
```

If you see 45, the secret was created with a trailing newline — recreate the version using `printf '%s'`.

### 6.4 Compare both sides hold the same key value for a realm

Without ever printing the key, compare SHA-256 fingerprints:

```bash
gcloud secrets versions access latest \
    --secret="knobby-mcp-handoff-hmac-key-${REALM}" \
    --project="$PROJECT_ID" \
    | sha256sum
# Should match the equivalent on the Knobby web side for that realm.
```

### 6.5 Confirm `knobby.web.host` Authenticator config per realm

Via admin console: **Authentication** → **Flows** → `browser-mcp-tenant-pick` → Knobby MCP Tenant Picker step → Config.

Via kcadm CLI (scriptable):

```bash
kcadm.sh get authentication/flows/browser-mcp-tenant-pick/executions \
    -r "$REALM" \
    | jq -r '.[] | select(.providerId=="knobby-mcp-tenant-picker") | .authenticationConfig'
```

Then `kcadm.sh get authentication/config/<config-id> -r "$REALM"` to inspect the config object — expect `config.knobby.web.host` set to the matching hostname.

### 6.6 Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Keycloak log: `MISSING_HMAC_KEY realm=knobby-test` on first MCP login through that realm | `KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_TEST` not wired in `cloudrun.yaml` | Add the env entry and redeploy. |
| `WRONG_KEY_LENGTH ... got 33` | Trailing newline in the secret value | Recreate the secret version using `printf '%s'`. |
| `MALFORMED_BASE64` | URL-safe base64 used instead of standard, or whitespace in the secret value | Re-encode with `openssl base64` (standard), not `openssl base64 -url`. |
| `MISSING_WEB_HOST realm=knobby-dev` | `knobby.web.host` Authenticator config not set for that realm | Set via admin console (§3.7). |
| Picker-result validation fails with `BAD_SIGNATURE` after a rotation of one realm | The matching Knobby web environment still on the old key; `_PREVIOUS__<R>` not wired on one side | Either re-wire `_PREVIOUS__<R>` on the lagging side, or finish the cut-over on both. |
| Picker-result `BAD_SIGNATURE` consistently for a realm | Keys actually differ between sides for that realm | Compare SHA-256 fingerprints per §6.4. |
| Cross-realm replay attempt fails (correctly) | A `picker_result` from realm A POSTed to `/realms/B/mcp-picker-callback` | Expected behavior — per-realm key isolation. Log line will show `BAD_SIGNATURE realm=B`. |
| Smoke Test 14 fails after a clean deploy | SPI failed to load due to an exception | Check `./logs.sh` for startup stack trace. |

---

## 7. Quick reference

### Per-realm rotation cheat-sheet

```
[per realm R]
generate → promote-to-previous → install-current → grant-iam → wire _PREVIOUS__<R> → deploy both → wait 15m → unwire _PREVIOUS__<R> → deploy both → destroy old version after 24h → record in history.jsonl
```

### Env vars summary

| Env var | Set on | When |
|---|---|---|
| `KNOBBY_MCP_HANDOFF_HMAC_KEY__<R>` | Keycloak + matching Knobby web | Always, per realm using the SPI |
| `KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__<R>` | Keycloak + matching Knobby web | Only during the rotation overlap window for that realm |

There is **no** `KNOBBY_WEB_HOST` env var — that lives as a per-realm Authenticator config in the Keycloak admin console (`knobby.web.host`).

### Secrets summary (per realm)

| Secret | Holds | Lifetime |
|---|---|---|
| `knobby-mcp-handoff-hmac-key-<realm>` | Current signing/validation key | Permanent; new version on each rotation |
| `knobby-mcp-handoff-hmac-key-<realm>-previous` | Prior key during rotation | Versions destroyed 24h after rotation completes; container persists for reuse |

### Realm-to-resource map (today)

| Realm | Env-var suffix | Secret (current) | Knobby web `knobby.web.host` |
|---|---|---|---|
| `knobby-prod` | `__KNOBBY_PROD` | `knobby-mcp-handoff-hmac-key-knobby-prod` | `prod.knobby.io` |
| `knobby-dev` | `__KNOBBY_DEV` | `knobby-mcp-handoff-hmac-key-knobby-dev` | `dev.knobby.io` |
| `knobby-test` | `__KNOBBY_TEST` | `knobby-mcp-handoff-hmac-key-knobby-test` | TBD when realm is created |
