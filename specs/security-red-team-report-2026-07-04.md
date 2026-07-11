<!-- AGENT: Red-team security review report for the Knobby Keycloak IdP. -->

# Red-Team Security Report — Keycloak IdP

**Date:** 2026-07-04  
**Reviewer role:** Red-team security lead  
**Scope reviewed:** repository history, tracked files, local untracked artifacts, Keycloak setup guide, Cloud Run revision YAML, shell scripts, Dockerfile, Maven SPI build, MCP SPI Java implementation, smoke-test posture, deferred hardening registers, and current upstream Keycloak release/security status.

## Remediation Status (updated 2026-07-09)

Reconciled against the codebase after the MCP hardening work. See `CHANGELOG.md` (2026-07-07…09) and ADR-016/017/018.

| # | Status | Note |
|---|---|---|
| RT-001 | ✅ Fixed | Keycloak 26.6.0 → **26.6.4**; base image now **digest-pinned** (TD-007). |
| RT-002 | ✅ Confirmed | `keycloak_neon.dump` deleted from the workspace (owner-confirmed). |
| RT-003 | ✅ Code done / ⏳ deploy | Both `KC_BOOTSTRAP_ADMIN_*` removed from `cloudrun.yaml` + smoke Test 30; operator to redeploy & rotate the bootstrap secret. |
| RT-004 | ⏳ Ops | Runbook in setup guide **A.4** (real secret names, swap + redeploy steps); operator creates the `keycloak-runner` SA + IAM and swaps it in for the default compute SA. |
| RT-005 | ✅ Fixed | Trusted Hosts ON; B1/AllowedGrantTypes shipped; **Allowed Protocol Mapper Types applied** (setup guide F.2 — owner-confirmed). Optional remaining: negative regression smoke tests (attacker-domain redirect / non-whitelisted mapper). |
| RT-006 | ✅ Ops (owner) | Cloudflare thin proxy + WAF — owner reports done. |
| RT-007 | ✅ Fixed | D.4 type → `None`, E.2 checklist corrected, smoke guard (web client must not carry `mcp-default`). |
| RT-008 | ✅ Fixed | Request↔result binding: `picker_request_jti` + `oauth_state` matched to server state; tenant-id format-validated (ADR-018). |
| RT-009 | ✅ Fixed | `granted_scopes` subset-validated against the client's assigned scopes (ADR-018). |
| RT-010 | 🟡 Mitigated | `maxScale=1` invariant + startup warning; externalize before scale-out. |
| RT-011 | ✅ Fixed | `knobby.web.host` strict validation + per-realm allowlist, fail-closed (ADR-018). |
| RT-012 | ✅ Reconciled | `manage-clients` no longer on the MCP critical path (CRP provisions); split-by-duty recommended. |
| RT-013 | ✅ Fixed | Dependabot: Docker + Maven + GitHub Actions. |
| RT-014 | ✅ Fixed | `SECURITY.md` rewritten for the IdP. |

**Remaining = operator actions:** RT-003 redeploy + secret rotation, RT-004 create the dedicated SA. Accepted deferrals: RT-005 (Allowed Protocol Mapper Types), RT-010 (externalized replay store, gated by `maxScale=1`).

---

## Executive Summary

The implementation has several strong security decisions already in place: per-realm HMAC keys, Secret Manager bindings instead of plaintext Cloud Run secrets, OAuth/MCP specs with explicit threat modeling, PKCE/DCR hardening intent, and tests around the SPI token validation path.

The highest-risk gaps are operational and versioning issues, not basic coding mistakes:

1. Production is pinned to **Keycloak 26.6.0** while upstream current is **26.6.4**, with multiple security fixes between those versions.
2. A local untracked **Keycloak database dump** exists in the workspace and is world-readable by file mode.
3. `cloudrun.yaml` still mounts bootstrap admin credentials, despite the setup guide saying to remove them after first admin creation.
4. DCR and Cloudflare/WAF hardening are explicitly deferred or disabled, which is acceptable only while no untrusted third-party DCR traffic is allowed.
5. The MCP SPI should add defense-in-depth checks around picker-result correlation and granted-scope validation before public MCP exposure.

## Evidence Sources

- Local files:
  - `Dockerfile`
  - `src/providers/pom.xml`
  - `cloudrun.yaml`
  - `run.sh`
  - `smoke.sh`
  - `specs/keycloak-setup-guide.md`
  - `specs/keycloak.web.mcp.md`
  - `specs/keycloak.spi.mcp.md`
  - `specs/keycloak-tech-debt.md`
  - `TECH_DEBT.md`
  - MCP SPI Java files under `src/providers/src/main/java/io/knobby/keycloak/mcp/`
- Local scans:
  - `rg` secret-pattern scan over tracked/untracked workspace excluding `.git` and `target`
  - `git grep` over all revisions for secret-like assignments and known key prefixes
  - `git log --all --name-only` for historically committed sensitive file names
- Current upstream:
  - Keycloak downloads page shows `26.6.4` as current.
  - Keycloak GitHub releases list security fixes in `26.6.2`, `26.6.3`, and `26.6.4`.

## Credential Exposure Review

### Result

No plaintext production secret value was found in current tracked files or in the git-history pattern scans performed. No AWS/GCP/GitHub/OpenAI/private-key prefix hit was found.

### Dedicated Scanner Follow-Up

After the initial report, Gitleaks `8.30.1` and TruffleHog `3.95.8` were installed under `/tmp/security-tools` and run locally.

| Scanner | Scope | Result |
|---|---|---|
| Gitleaks | Git history, 29 commits | 5 redacted findings: 4 Auth0 curl `Authorization: Bearer YOUR_ACCESS_TOKEN` documentation placeholders and 1 generic API-key false positive in a config example. |
| Gitleaks | Working tree, excluding `.git` and `target` | 3 redacted findings: the same documentation placeholders/config-example false positives. |
| TruffleHog | Git history | 0 verified, 0 unverified secrets. |
| TruffleHog | Working tree, excluding `.git` and `target` | 0 verified, 0 unverified secrets. |

### Important Caveats

- I did **not** open or inspect the local database dump contents, because the file itself is sensitive enough to classify as a finding.
- I did not access live GCP Secret Manager secret payloads, Artifact Registry internals, Keycloak Admin API, or database state.
- A read-only Cloud Run service describe was performed after the initial report and confirmed the production service is inspectable with the active `gcloud` account.

### Sensitive Artifacts Found

| Artifact | Status | Finding |
|---|---|---|
| `keycloak_neon.dump` | Untracked, ignored by `.gitignore`, local file mode `0644`, PostgreSQL custom dump, 405 KiB | Sensitive local artifact. A Keycloak DB dump can contain users, client secrets, password hashes, sessions, identity-provider config, DCR clients, registration access tokens, and realm settings. |
| `build.json` | Untracked now, ignored, historically committed | Contains project/registry/image metadata, not a secret. Still confirms generated artifacts have entered git history before. |
| `cloudrun.yaml` | Tracked | Contains DB hostname, DB username, GCP project number, service account email, image digest, and secret resource names. No plaintext secret values. Treat as internal infrastructure metadata. |

## Findings

### RT-001 — Keycloak Base Is Behind Current Security Release

**Severity:** Critical  
**Affected files:** `Dockerfile`, `src/providers/pom.xml`, `cloudrun.yaml`  
**Evidence:** `Dockerfile` uses `quay.io/keycloak/keycloak:26.6.0`; Maven property `keycloak.version` is `26.6.0`; deployed image is a custom build from that line. Upstream current is `26.6.4`. Keycloak release notes list multiple security fixes in later 26.6.x releases, including JWT algorithm-confusion authentication bypass, privilege escalations, DCR registration-access-token client takeover, XSS, request smuggling, SSRF, session fixation, token disclosure, and DoS fixes.

**Impact:** Internet-facing IdP remains exposed to vulnerabilities fixed upstream after 26.6.0. Several listed fixes touch exactly this repo's active surface: OIDC, identity brokering, DCR/client registration, token handling, admin/API surfaces, and request parsing.

**Recommended remediation:**

1. Upgrade base image and SPI BOM together to `26.6.4`.
2. Run `./test.sh`.
3. Run smoke tests against a non-prod realm.
4. Build and deploy.
5. Pin the base image by digest as part of the same change or immediately after.
6. Add automated dependency monitoring for Docker and Maven.

### RT-002 — Local Keycloak DB Dump Present and World-Readable

**Severity:** High  
**Affected artifact:** `keycloak_neon.dump`  
**Evidence:** Local file exists, ignored but untracked; file mode `-rw-r--r--`; file type is PostgreSQL custom database dump.

**Impact:** If the dump is production or near-production, compromise of the developer machine or accidental copy/sync exposes identity data and likely credentials. Keycloak databases commonly include confidential client secrets, identity-provider config, offline sessions, user metadata, password hashes for any local users, DCR clients, and registration access tokens.

**Recommended remediation:**

1. Determine whether this dump is production, staging, or local-only.
2. Move it outside the repo immediately.
3. Store only encrypted dumps, preferably `age`/GPG encrypted, mode `0600`, outside synced folders.
4. If production-derived, rotate all Keycloak client secrets, IdP secrets, HMAC keys, registration access tokens, and DB credentials that could be present in the dump.
5. Add a pre-commit secret/dump guard.

### RT-003 — Bootstrap Admin Credentials Still Mounted in Cloud Run Config

**Severity:** High  
**Affected file:** `cloudrun.yaml`  
**Evidence:** `KC_BOOTSTRAP_ADMIN_USERNAME=admin` and `KC_BOOTSTRAP_ADMIN_PASSWORD` Secret Manager binding remain in the revision YAML. The setup guide explicitly says to remove bootstrap env vars after the real admin is created.

**Live confirmation:** `gcloud run services describe knobbyauth --region=asia-southeast1 --project=stellar-zoo-478023-v4` shows both bootstrap env vars still present on the latest ready revision.

**Impact:** Bootstrap credentials should not remain part of steady-state runtime. Anyone with access to that Secret Manager secret or a future clean-database scenario has an admin bootstrap path. It also increases the number of high-value secrets mounted into the IdP process.

**Recommended remediation:**

1. Confirm a real admin account exists and is protected by strong MFA/upstream IdP controls.
2. Remove `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD` from Cloud Run.
3. Disable/destroy/rotate the bootstrap password secret after removal.
4. Add a smoke check that fails if bootstrap env vars are present in prod.

### RT-004 — Production Uses the Default Compute Service Account

**Severity:** High  
**Affected file:** `cloudrun.yaml`  
**Evidence:** Cloud Run revision uses `871965503155-compute@developer.gserviceaccount.com` rather than a dedicated `keycloak-runner` service account.

**Live confirmation:** the latest Cloud Run service template still uses `871965503155-compute@developer.gserviceaccount.com`.

**Impact:** Default compute service accounts are commonly over-privileged or reused across workloads. If Keycloak or its container is compromised, the attacker inherits whatever IAM that default service account has.

**Recommended remediation:**

1. Create a dedicated Cloud Run runtime service account for Keycloak.
2. Grant only the required Secret Manager secret access for DB password and per-realm HMAC keys.
3. Avoid project-wide roles where possible.
4. Review and remove broad roles from the default compute service account.

### RT-005 — DCR Redirect-Host and Protocol-Mapper Hardening Is Deferred

**Severity:** High before untrusted DCR; Medium while only trusted users can register  
**Affected files:** `specs/keycloak-setup-guide.md`, `specs/keycloak-tech-debt.md`  
**Evidence:** Trusted Hosts and Allowed Protocol Mapper Types are listed as GA blockers/deferred hardening. The setup guide also states Trusted Hosts can be deleted and reliance placed on `max-clients` plus WAF rate limiting.

**Impact:** Anonymous DCR is an internet-facing control plane. Without redirect-host constraints, a malicious client can register redirect URIs on attacker-controlled infrastructure. Without mapper constraints, a malicious client can attempt claim injection through self-attached mappers; downstream validation may mitigate this, but Keycloak should reject it early.

**Recommended remediation:**

1. Do not expose anonymous DCR to untrusted parties until Trusted Hosts and Allowed Protocol Mapper Types are re-enabled and tested.
2. Explicitly support loopback redirects for desktop clients without allowing arbitrary internet hosts.
3. Add negative smoke tests for attacker domains and non-whitelisted mapper types.
4. Consider implementing the planned `AllowedGrantTypesPolicy` in the same hardening pass.

### RT-006 — Cloudflare/WAF Protection Is Currently DNS-Only

**Severity:** High for public DCR/token exposure; Medium pre-launch  
**Affected file:** `specs/keycloak-setup-guide.md`  
**Evidence:** Setup guide says `auth.knobby.io` currently runs DNS-only after Cloudflare broke admin/API requests. The guide recommends scoped rate limits later.

**Impact:** Keycloak token, authorization, login, and DCR endpoints remain directly exposed to volumetric abuse at Cloud Run. Cloud Run maxScale is currently 1, which limits cost blowout but also makes availability easier to exhaust. `containerConcurrency=10`, `timeoutSeconds=300`, and expensive auth/token paths make this worth hardening before public traffic.

**Recommended remediation:**

1. Re-enable Cloudflare proxy in a thin configuration: no Rocket Loader, no Auto Minify, no aggressive bot features on Keycloak assets/admin.
2. Add narrowly scoped WAF/rate limits for:
   - `/realms/*/clients-registrations/*`
   - `/realms/*/protocol/openid-connect/token`
   - login error bursts
3. Exclude `/admin/*` and `/resources/*` from aggressive rate limits.
4. Add alerts on 429s, login failures, DCR registration rate, token grant errors, and Cloud Run request saturation.

### RT-007 — Setup Guide Contains Contradictory `mcp-default` Instructions

**Severity:** High operational risk  
**Affected file:** `specs/keycloak-setup-guide.md`  
**Evidence:** D.7/D.8 correctly say Option B must not make `mcp-default` realm-default. However D.4 still says the `mcp-default` Client Scope type is `Default` so it can be assigned realm-default, and E.2 checklist says realm-default Client Scopes should include `mcp-default` plus the Author bundle.

**Impact:** If an operator follows the checklist, every client can acquire `mcp-default`. The SPI uses the presence of `mcp-default` to identify MCP clients. This breaks the discriminator and can route normal web clients into the MCP consent path or make MCP flow failures affect normal login.

**Recommended remediation:**

1. Correct D.4 to create `mcp-default` in a way that does not imply realm-default assignment.
2. Correct E.2 to say per-client assignment only under Option B.
3. Add a smoke test that fails if `knobby-{env}-web` has `mcp-default`.
4. Keep TD-009 visible until the SPI has a harder client attribute signal.

### RT-008 — MCP Picker Result Is Not Bound Strongly Enough to Original Request

**Severity:** Medium now; High before public MCP if Knobby web is a large TCB  
**Affected files:** `McpTenantPickerAuthenticator.java`, `McpPickerCallbackResourceProvider.java`, `HandoffTokenValidator.java`  
**Evidence:** Authenticator builds a picker request with `jti`, requested scopes, OAuth state, auth session ID, client ID, and tab ID. Callback validates the signed result, finds the auth session, checks user echo, and writes `chosenTenantId`/`grantedScopes`. It does not store the request `jti`/nonce/requested scope set in the auth session and does not compare `picker_request_jti` to server-side state.

**Impact:** The SPI trusts Knobby web to echo and constrain everything correctly. If the web consent endpoint has a bug, is compromised, or signs a result for the wrong request, Keycloak will accept any HMAC-valid result for the referenced user/auth session. The protocol spec says the result `jti` should match the request `jti`; the implementation does not enforce that independently.

**Recommended remediation:**

1. Store request `jti`, nonce, requested scopes, client ID, and OAuth state in auth-session notes before redirect.
2. On callback, require `picker_request_jti`, nonce, `oauth_state`, client ID, tab ID, and auth session ID to match server-side notes.
3. Reject `granted_scopes` unless they are a subset of originally requested and allowed MCP scopes.
4. Validate `chosen_tenant_id` format before writing it into the token path.

### RT-009 — `granted_scopes` Are Written Directly to Access Token Scope

**Severity:** Medium now; High if Knobby web has a signing/authorization bug  
**Affected files:** `McpPickerCallbackResourceProvider.java`, `McpScopeOverrideMapper.java`  
**Evidence:** Callback writes `knobby_scopes = String.join(" ", token.getGrantedScopes())`; scope override mapper sets the access-token `scope` claim directly from that note.

**Impact:** A single bug in the consent service can mint arbitrary scope strings into Keycloak-issued access tokens. Downstream resource servers may treat unknown or elevated scopes inconsistently.

**Recommended remediation:**

1. Hardcode the allowed MCP scope set in the SPI or load it from realm config.
2. Reject unknown scopes and duplicates.
3. Require granted scopes to be a subset of request scopes or of the configured consent bundle.
4. Consider normalizing order to avoid policy/cache ambiguity.

### RT-010 — Replay Cache Is In-Memory and Single-Instance Only

**Severity:** Medium  
**Affected file:** `ReplayCache.java`  
**Evidence:** Replay cache is a per-JVM `LinkedHashMap`. The code comment acknowledges multi-instance Keycloak would need backing storage. Cloud Run currently has `maxScale: 1`, but earlier docs/scripts discuss higher scaling and migration scenarios.

**Impact:** A picker-result token can potentially be replayed after container restart or against another instance if scaling changes. The token TTL is short, but the path writes session notes and resumes auth, so replay guarantees should not silently depend on single-instance runtime shape.

**Recommended remediation:**

1. Keep `maxScale=1` documented as a security invariant until replay cache is externalized.
2. Add a startup warning if multiple instances/scaling are enabled without a distributed replay store.
3. Before scale-out, move replay state to Keycloak/Infinispan, database, Redis, or another short-TTL shared store.

### RT-011 — `knobby.web.host` Is Not Syntax-Validated or Allowlisted

**Severity:** Medium  
**Affected file:** `McpTenantPickerAuthenticator.java`  
**Evidence:** Authenticator reads `knobby.web.host` from admin config and constructs a redirect URI by string concatenation.

**Impact:** Misconfiguration or admin compromise can redirect signed picker-request tokens to an unintended host. The token is HMAC-protected but contains user/client/auth-session metadata and OAuth state. This is a privacy leak and can become a phishing/control-plane issue.

**Recommended remediation:**

1. Validate the host strictly: hostname only, no scheme, no path, no query, no userinfo, no port unless explicitly allowed.
2. Enforce per-realm allowlist:
   - `knobby-prod` → `prod.knobby.io`
   - `knobby-dev` → `dev.knobby.io`
   - test/local explicitly separate
3. Fail closed on invalid config.

### RT-012 — Admin API Service Account Role Model Is Inconsistent and Likely Over-Broad

**Severity:** Medium to High depending on deployment  
**Affected files:** `specs/keycloak.prd.md`, `specs/keycloak.web.mcp.md`, `smoke.sh`  
**Evidence:** PRD/smoke tests intentionally forbid `manage-clients`, while the web MCP spec says Option B post-DCR provisioning needs `manage-clients`. The same `knobby-{env}-admin-api` service account also has powerful user and IdP management roles.

**Impact:** If the broad admin API client secret leaks, attackers can modify users and IdP settings, and if `manage-clients` is added to the same client, they can also mutate clients and flow bindings. Conversely, without `manage-clients`, Option B provisioning cannot work.

**Recommended remediation:**

1. Split admin clients by duty:
   - read-only smoke/drift client
   - user-management client
   - MCP client-provisioner client
2. Avoid adding `manage-clients` to the general admin API client.
3. Prefer using DCR registration access tokens for per-client updates if Knobby web can safely receive/store them.
4. Rotate and isolate secrets per function.

### RT-013 — Automated Security Update Coverage Is Misconfigured

**Severity:** Medium  
**Affected file:** `.github/dependabot.yml`  
**Evidence:** Dependabot is configured only for `pip` in `/`. This repo's live dependencies are Docker base images and Maven dependencies.

**Impact:** Security updates for Keycloak base images and Maven/test dependencies will not be surfaced automatically. This likely contributed to the stale `26.6.0` posture.

**Recommended remediation:**

1. Configure Dependabot or Renovate for:
   - Dockerfile base images
   - Maven module at `src/providers`
   - GitHub Actions if workflows are added
2. Add a scheduled job that checks Keycloak latest 26.x patch release.
3. Treat Keycloak patch releases as security-relevant by default.

**Follow-up completed:** Dependabot alerts and automated security fixes were enabled through the GitHub API. `.github/dependabot.yml` was updated to cover Docker, Maven, and GitHub Actions. CodeQL and Dependency Review workflows were added. GitHub API rejected secret scanning / push protection for this private repository with `Secret scanning is not available for this repository`; enabling that requires the relevant GitHub Code Security / Advanced Security plan or organization setting.

### RT-014 — `SECURITY.md` Describes the Wrong Project

**Severity:** Low to Medium  
**Affected file:** `SECURITY.md`  
**Evidence:** It says the project is a client-side UI theme/component library with no backend/API/auth/database. This repository is an IdP with Keycloak, Java SPIs, OAuth/MCP, Cloud Run, and DB-backed identity state.

**Impact:** Vulnerability reporters and internal responders get the wrong scope, wrong threat model, and wrong expected vulnerability classes.

**Recommended remediation:**

1. Rewrite `SECURITY.md` for this IdP.
2. Include private reporting path, supported Keycloak versions, urgent rotation contacts, and what to include for auth/OAuth reports.
3. Explicitly state no public GitHub issues for vulnerabilities.

## Positive Controls Observed

- Per-realm HMAC key design prevents cross-realm handoff replay if one realm key leaks.
- HMAC key values are not logged by SPI exceptions.
- Picker-result validation checks signature, issuer, audience, expiry, future `iat`, and replay `jti`.
- Callback verifies `user_sub_echo` against the authentication session user.
- Cloud Run config mounts DB password and HMAC key from Secret Manager, not plaintext YAML.
- `target/`, dumps, `.env`, and build artifacts are ignored.
- Smoke tests include useful checks for PKCE, DCR, direct grant posture, admin client roles, and token endpoint stability.

## Immediate Priority Order

1. Upgrade Keycloak to `26.6.4` and redeploy.
2. Remove/secure `keycloak_neon.dump`; rotate secrets if production-derived.
3. Remove bootstrap admin env vars from Cloud Run and rotate/delete that secret.
4. Switch Cloud Run to a dedicated least-privilege service account.
5. Fix the `mcp-default` setup-guide/checklist contradiction before any operator follows it again.
6. Re-enable thin Cloudflare/WAF protection with scoped rate limits.
7. Add SPI defense-in-depth checks for request/result correlation and granted scopes.
8. Resolve the admin API role split for Option B post-DCR provisioning.
9. Add Docker/Maven dependency monitoring.

## Report Limitations

This review did not perform live exploitation, active probing against `auth.knobby.io`, database dump inspection, cloud IAM enumeration, Keycloak Admin API inspection, or full entropy scanning with a dedicated secret scanner. Those should be done as a separate authorized runtime assessment.
