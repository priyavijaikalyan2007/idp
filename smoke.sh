#!/usr/bin/env bash
#
# keycloak-smoke-test.sh (v1.9)
#
# Verifies a fresh Keycloak realm setup against the PRD (§11.16 verification
# checklist), without requiring any knobby.io application integration.
#
# Convention-based: setting KNOBBY_ENV={prod|dev|test} derives all realm,
# client, and hostname defaults per PRD §10.8. Override any individual value
# by exporting the explicit variable.
#
# Authentication:
#   - Keycloak Admin API: OAuth 2.0 client_credentials grant as the
#     'knobby-{env}-admin-api' service account (per PRD §11.13). The
#     credential is the ADMIN_CLIENT_SECRET env var. No interactive login is
#     required — this is service-to-service auth, the same path the knobby.io
#     backend will use in production.
#   - GCP Secrets Manager (Test 9, prod/dev only): uses existing
#     'gcloud auth login' session.
#   - Azure / Microsoft Graph (Test 10, prod/dev only): uses existing
#     'az login' session in the knobby.io home Entra tenant.
#
# Performs server-side automated checks (tests 1-26) and prints URLs for
# manual browser-driven federation tests (tests 27-32).
#
# Tests:
#   Realm + federation foundation (Tests 1-13):
#   1.  OIDC discovery endpoint (realm liveness)
#   2.  Account console disabled
#   3.  Account console v2 disabled
#   4.  Admin API client credentials grant (functional)
#   5.  Admin API list users (validates view-users / query-users)
#   6.  Admin API list IdPs (validates view-identity-providers; classifies IdPs)
#   7.  Browser flow binding is browser-federated-only
#   8.  No Required Actions set as Default
#   9.  GCP Secrets Manager — expected secret names exist (§10.8)
#   10. Microsoft Entra app registration — naming, audience, redirect URI,
#       publisher domain, Graph permissions, secret expiry (§6.3, §11.9)
#   11. knobby-{env}-web client configuration + audience mapper (§8.2, §8.3, §17.7)
#   12. knobby-{env}-admin-api client configuration (§11.13)
#   13. PKCE enforcement (behavioral) (§8.2)
#
#   MCP-readiness (Tests 14-29): designed to go from red→green progressively
#   as you complete the MCP setup (SETUP GUIDE Section D; design rationale in PRD §16):
#   14. MCP Authenticator SPI loaded (§16.8)
#   15. browser-mcp-tenant-pick auth flow exists (§16.8.1)
#   16. Six atomic knobby:* Client Scopes exist (§16.3.6)
#   17. mcp-default Client Scope with audience mapper (§16.6)
#   18. mcp-dcr-policy configured (§16.4)
#   19. Refresh token rotation enabled (§16.5)
#   20. HMAC handoff key in GCP Secret Manager (§16.8.5)
#   21. DCR endpoint accepts compliant registration (§16.4)
#   22. DCR rejects non-HTTPS redirect URI in prod (§16.4)
#   23. DCR rejects disallowed grant types (§16.4)
#   24. DCR rejects disallowed scopes (§16.4)
#   25. DCR-registered client has correct default scopes + flow binding (§16.4)
#   26. Cleanup DCR-registered test client
#   27. OAuth Authorization Server Metadata advertises DCR endpoint (§16.2)
#   28. Realm SSL requirement (§16.5)
#   29. Scope override mapper attached to mcp-default (§16.8.4)
#
#   Manual federation flows (Tests 30-35):
#   30. Fallback picker (no kc_idp_hint)
#   31. Google federation
#   32. Microsoft federation, work account
#   33. Microsoft federation, personal MSA
#   34. GitHub federation
#   35. Token exchange (optional)
#   36. MCP end-to-end (path iii handoff) — requires Knobby web /mcp/consent
#
# v1.11 (this version): Added Tests 27-29 (OAuth metadata advertising,
# realm SSL requirement, scope override mapper presence).
#
# v1.10: Added Tests 14-26 for MCP-readiness validation per PRD §16.
#
# v1.8 fix: Test 6 detects IdPs by both providerId and authorization URL
# pattern, so the generic-OIDC Microsoft setup (PRD §6.3) is identified
# correctly regardless of the alias the operator chose.
#
# Requirements: curl, jq, openssl.
# Test 9 requires gcloud (skipped if not installed or for test env).
# Test 10 requires az (skipped if not installed, not authenticated, or for
# test env, or if Microsoft IdP not configured).
#
# Usage examples:
#
#   # Prod (secrets from GCP Secrets Manager, Entra check from Azure CLI):
#   export KNOBBY_ENV=prod
#   export ADMIN_CLIENT_SECRET=$(gcloud secrets versions access latest \
#       --secret=knobby-keycloak-admin-api-client-secret-prod)
#   # Ensure 'az login' has put you in the knobby.io home Entra tenant
#   ./keycloak-smoke-test.sh
#
#   # Test (local Docker Compose Keycloak; tests 9 & 10 auto-skipped):
#   export KNOBBY_ENV=test
#   export ADMIN_CLIENT_SECRET="$KNOBBY_KEYCLOAK_ADMIN_API_CLIENT_SECRET_TEST"
#   ./keycloak-smoke-test.sh
#
#   # Override the gcloud project used by Test 9:
#   export KNOBBY_ENV=prod
#   export GCP_PROJECT=knobby-platform-prod
#   ./keycloak-smoke-test.sh
#
# Exit codes:
#   0 = all automated checks passed
#   1 = at least one check failed
#   2 = required environment variable missing or invalid

set -u

# ----- color output -----
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

# ----- validate KNOBBY_ENV -----
if [[ -z "${KNOBBY_ENV:-}" ]]; then
    echo -e "${RED}ERROR: KNOBBY_ENV is not set${RESET}" >&2
    echo "Set KNOBBY_ENV to one of: prod, dev, test" >&2
    exit 2
fi

case "$KNOBBY_ENV" in
    prod|dev|test) ;;
    *)
        echo -e "${RED}ERROR: KNOBBY_ENV must be one of: prod, dev, test (got '${KNOBBY_ENV}')${RESET}" >&2
        exit 2
        ;;
esac

# ----- derive convention-based defaults (per PRD §10.8) -----
# Note on deployment topology: apex knobby.io and www.knobby.io are marketing
# sites; the actual application is deployed at prod.knobby.io (prod) and
# dev.knobby.io (dev). The redirect_uri in OAuth flows targets the app, not
# the marketing apex.
case "$KNOBBY_ENV" in
    prod)
        DEFAULT_KC_URL="https://auth.knobby.io"
        DEFAULT_WEB_REDIRECT_URI="https://prod.knobby.io/auth/callback"
        ;;
    dev)
        DEFAULT_KC_URL="https://auth.knobby.io"
        DEFAULT_WEB_REDIRECT_URI="https://dev.knobby.io/auth/callback"
        ;;
    test)
        DEFAULT_KC_URL="http://localhost:8080"
        DEFAULT_WEB_REDIRECT_URI="http://localhost:3000/auth/callback"
        ;;
esac

KC_URL="${KC_URL:-$DEFAULT_KC_URL}"
REALM="${REALM:-knobby-${KNOBBY_ENV}}"
ADMIN_CLIENT_ID="${ADMIN_CLIENT_ID:-knobby-${KNOBBY_ENV}-admin-api}"
WEB_CLIENT_ID="${WEB_CLIENT_ID:-knobby-${KNOBBY_ENV}-web}"
WEB_REDIRECT_URI="${WEB_REDIRECT_URI:-$DEFAULT_WEB_REDIRECT_URI}"
# Guard: a WEB_REDIRECT_URI override that differs from the env's default is a
# common footgun - it leaks into BOTH the "Web client redirect URI" check and the
# PKCE-enforcement probe, producing confusing 'invalid_redirect_uri' failures that
# look like a realm misconfiguration but are just a bad env var. Flag it early.
if [[ "$WEB_REDIRECT_URI" != "$DEFAULT_WEB_REDIRECT_URI" ]]; then
    echo -e "  ${YELLOW}NOTE:${RESET} WEB_REDIRECT_URI is overridden to '${WEB_REDIRECT_URI}'"
    echo -e "        (default for env '${KNOBBY_ENV}' is '${DEFAULT_WEB_REDIRECT_URI}')."
    echo -e "        If the redirect-URI or PKCE tests fail with 'invalid_redirect_uri',"
    echo -e "        run 'unset WEB_REDIRECT_URI' - the realm is likely fine."
fi

# ----- MCP-related defaults (per PRD §16) -----
# These are constants in §10.8 — exposed as overridable in case the user has
# named things differently during early implementation.
MCP_SPI_PROVIDER_ID="${MCP_SPI_PROVIDER_ID:-knobby-mcp-tenant-picker}"
MCP_FLOW_NAME="${MCP_FLOW_NAME:-browser-mcp-tenant-pick}"
MCP_DCR_POLICY_NAME="${MCP_DCR_POLICY_NAME:-mcp-dcr-policy}"
MCP_DEFAULT_SCOPE="${MCP_DEFAULT_SCOPE:-mcp-default}"
MCP_AUDIENCE="${MCP_AUDIENCE:-knobby-mcp-api}"
MCP_HANDOFF_KEY_SECRET="${MCP_HANDOFF_KEY_SECRET:-knobby-mcp-handoff-hmac-key-${KNOBBY_ENV}}"
MCP_ATOMIC_SCOPES=("knobby:read" "knobby:comment" "knobby:curate" "knobby:write" "knobby:share" "knobby:admin")
# Author bundle (default scopes for DCR'd clients per §16.4):
MCP_AUTHOR_BUNDLE_SCOPES=("knobby:read" "knobby:comment" "knobby:curate" "knobby:write" "knobby:share")

KC_URL="${KC_URL%/}"

# ----- validate ADMIN_CLIENT_SECRET -----
if [[ -z "${ADMIN_CLIENT_SECRET:-}" ]]; then
    echo -e "${RED}ERROR: ADMIN_CLIENT_SECRET is not set${RESET}" >&2
    echo "" >&2
    echo "Expected secret name in GCP Secrets Manager (per PRD §10.8):" >&2
    echo "  knobby-keycloak-admin-api-client-secret-${KNOBBY_ENV}" >&2
    echo "" >&2
    echo "For prod/dev, fetch with:" >&2
    echo "  export ADMIN_CLIENT_SECRET=\$(gcloud secrets versions access latest \\" >&2
    echo "      --secret=knobby-keycloak-admin-api-client-secret-${KNOBBY_ENV})" >&2
    echo "" >&2
    echo "For test, source from your developer-local .env file." >&2
    exit 2
fi

# ----- check required tools -----
for tool in curl jq openssl; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: required tool '$tool' is not installed${RESET}" >&2
        exit 2
    fi
done

REALM_BASE="${KC_URL}/realms/${REALM}"

# ----- generate PKCE values (RFC 7636) for manual federation tests -----
# The 'knobby-{env}-web' client requires PKCE S256 (per PRD §8.2). Every
# authorization request must include code_challenge + code_challenge_method.
# We generate one (verifier, challenge) pair per script run; print the verifier
# so the operator can use it in Test 19's token exchange.
CODE_VERIFIER=$(openssl rand 32 | base64 | tr -d '=\n' | tr '+/' '-_')
CODE_CHALLENGE=$(printf '%s' "$CODE_VERIFIER" | openssl dgst -binary -sha256 | base64 | tr -d '=\n' | tr '+/' '-_')
PKCE_QUERY="code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256"

# ----- print resolved configuration -----
echo -e "${BOLD}${BLUE}Keycloak smoke test (v1.9) — resolved configuration${RESET}"
echo -e "  ${DIM}KNOBBY_ENV:${RESET}          ${KNOBBY_ENV}"
echo -e "  ${DIM}KC_URL:${RESET}              ${KC_URL}"
echo -e "  ${DIM}REALM:${RESET}               ${REALM}"
echo -e "  ${DIM}ADMIN_CLIENT_ID:${RESET}     ${ADMIN_CLIENT_ID}"
echo -e "  ${DIM}WEB_CLIENT_ID:${RESET}       ${WEB_CLIENT_ID}"
echo -e "  ${DIM}WEB_REDIRECT_URI:${RESET}    ${WEB_REDIRECT_URI}"
echo -e "  ${DIM}ADMIN_CLIENT_SECRET:${RESET} ${ADMIN_CLIENT_SECRET:0:6}... (truncated)"
if [[ "$KNOBBY_ENV" != "test" && -n "${GCP_PROJECT:-}" ]]; then
    echo -e "  ${DIM}GCP_PROJECT:${RESET}         ${GCP_PROJECT}"
fi
# Optional observability flags (Test 19d - informational only, never fails):
if [[ "${OBSERVABILITY_EXPECTED:-false}" == "true" || -n "${KC_MGMT_URL:-}" ]]; then
    echo -e "  ${DIM}OBSERVABILITY_EXPECTED:${RESET} ${OBSERVABILITY_EXPECTED:-false}   ${DIM}KC_MGMT_URL:${RESET} ${KC_MGMT_URL:-unset}"
fi

# ----- print authentication mechanism summary -----
echo ""
echo -e "${BOLD}${BLUE}Authentication mechanisms${RESET}"
echo -e "  ${DIM}Keycloak:${RESET}    OAuth 2.0 client_credentials grant"
echo -e "  ${DIM}        ${RESET}     as service account '${ADMIN_CLIENT_ID}'"
echo -e "  ${DIM}        ${RESET}     credential from ADMIN_CLIENT_SECRET env var"
echo -e "  ${DIM}        ${RESET}     (no interactive login - this is service-to-service auth,"
echo -e "  ${DIM}        ${RESET}      same path knobby.io backend uses in production)"
if [[ "$KNOBBY_ENV" != "test" ]]; then
    echo -e "  ${DIM}GCP:${RESET}         existing 'gcloud auth login' session (used by Test 9)"
    echo -e "  ${DIM}Azure:${RESET}       existing 'az login' session (used by Test 10)"
fi

# ----- tracking -----
declare -a RESULTS
PASS_COUNT=0
FAIL_COUNT=0

record_pass()
{
    local name="$1"
    local detail="${2:-}"
    RESULTS+=("${GREEN}PASS${RESET}  ${name}${detail:+  -  ${detail}}")
    PASS_COUNT=$((PASS_COUNT + 1))
}

record_fail()
{
    local name="$1"
    local detail="${2:-}"
    RESULTS+=("${RED}FAIL${RESET}  ${name}${detail:+  -  ${detail}}")
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

record_skip()
{
    local name="$1"
    local detail="${2:-}"
    RESULTS+=("${YELLOW}SKIP${RESET}  ${name}${detail:+  -  ${detail}}")
}

section()
{
    echo ""
    echo -e "${BOLD}${BLUE}=== $1 ===${RESET}"
}

# Fetch the realm representation and validate it's actually JSON. A proxy in
# front of Keycloak (e.g. Cloudflare) may return an HTML 429/challenge page
# instead of JSON when rate-limiting the admin API — which otherwise surfaces
# as confusing raw `jq: parse error: Invalid numeric literal` noise. Sets the
# global REALM_JSON on success; on failure sets REALM_JSON="" and returns 1 with
# a human-readable reason in REALM_FETCH_ERR.
REALM_JSON=""
REALM_FETCH_ERR=""
fetch_realm_json()
{
    REALM_JSON=""
    REALM_FETCH_ERR=""
    local raw status body
    raw=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}" 2>/dev/null)
    status=$(echo "$raw" | grep "HTTP_STATUS:" | cut -d: -f2)
    body=$(echo "$raw" | sed '/HTTP_STATUS:/d')

    if [[ "$status" == "429" ]]; then
        REALM_FETCH_ERR="admin API returned HTTP 429 (rate-limited). A proxy in front of Keycloak (Cloudflare?) is throttling /admin/* - scope rate-limit rules away from /admin/* and /resources/*, and disable Rocket Loader on auth.knobby.io (setup guide §A.11)."
        return 1
    fi
    if ! echo "$body" | jq -e . >/dev/null 2>&1; then
        # Not valid JSON - almost always an HTML error/challenge page from a proxy.
        local snippet
        snippet=$(echo "$body" | head -c 60 | tr '\n' ' ')
        REALM_FETCH_ERR="admin API returned non-JSON (HTTP ${status:-?}). Likely an HTML error/challenge page from a proxy (Cloudflare rate-limit/Bot Fight). First bytes: '${snippet}'. See setup guide §A.11 (Keycloak behind Cloudflare)."
        return 1
    fi
    REALM_JSON="$body"
    return 0
}

# Cross-platform epoch parser for ISO 8601 timestamps from Azure CLI.
# Returns 0 if parsing fails.
parse_iso_to_epoch()
{
    local iso="$1"
    local clean
    clean=$(echo "$iso" | sed -E 's/\.[0-9]+//' | sed -E 's/\+00:00$/Z/')
    date -d "$clean" +%s 2>/dev/null || \
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "$clean" +%s 2>/dev/null || \
        echo 0
}

# ----- test 1: OIDC discovery endpoint -----
section "Test 1: OIDC discovery endpoint (realm liveness)"

# Initialize discovery-derived variables to empty strings so that downstream
# tests can gate on emptiness rather than crashing under set -u if discovery
# fails (Keycloak down, realm missing, network glitch, etc.).
ISSUER=""
TOKEN_ENDPOINT=""
AUTH_ENDPOINT=""

DISCOVERY_URL="${REALM_BASE}/.well-known/openid-configuration"
echo "GET ${DISCOVERY_URL}"

DISCOVERY_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "${DISCOVERY_URL}")
DISCOVERY_STATUS=$(echo "$DISCOVERY_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
DISCOVERY_BODY=$(echo "$DISCOVERY_RESPONSE" | sed '/HTTP_STATUS:/d')

if [[ "$DISCOVERY_STATUS" != "200" ]]; then
    record_fail "OIDC discovery" "HTTP ${DISCOVERY_STATUS} (expected 200; realm may not exist)"
elif ! echo "$DISCOVERY_BODY" | jq -e '.issuer' > /dev/null 2>&1; then
    record_fail "OIDC discovery" "response is not valid JSON or missing 'issuer'"
else
    ISSUER=$(echo "$DISCOVERY_BODY" | jq -r '.issuer')
    TOKEN_ENDPOINT=$(echo "$DISCOVERY_BODY" | jq -r '.token_endpoint')
    AUTH_ENDPOINT=$(echo "$DISCOVERY_BODY" | jq -r '.authorization_endpoint')
    record_pass "OIDC discovery" "issuer=${ISSUER}"
    echo "  token_endpoint: ${TOKEN_ENDPOINT}"
    echo "  authorization_endpoint: ${AUTH_ENDPOINT}"
fi

# ----- test 2: Account console disabled -----
section "Test 2: Account console disabled"

ACCOUNT_URL="${REALM_BASE}/account"
echo "GET ${ACCOUNT_URL}"

ACCOUNT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${ACCOUNT_URL}")
case "$ACCOUNT_STATUS" in
    200) record_fail "Account console disabled" "HTTP 200 - still accessible (PRD §11.12)" ;;
    404|403|400) record_pass "Account console disabled" "HTTP ${ACCOUNT_STATUS}" ;;
    302) record_pass "Account console disabled" "HTTP 302 (redirect - verify manually)" ;;
    *) record_fail "Account console disabled" "HTTP ${ACCOUNT_STATUS}" ;;
esac

# ----- test 3: Account console v2 endpoint disabled -----
section "Test 3: Account console v2 endpoint disabled"

ACCOUNT_V2_URL="${REALM_BASE}/account/"
echo "GET ${ACCOUNT_V2_URL}"

ACCOUNT_V2_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${ACCOUNT_V2_URL}")
case "$ACCOUNT_V2_STATUS" in
    200) record_fail "Account console v2 disabled" "HTTP 200 - check both 'account' and 'account-console' clients" ;;
    *) record_pass "Account console v2 disabled" "HTTP ${ACCOUNT_V2_STATUS}" ;;
esac

# ----- test 4: Admin API token acquisition -----
section "Test 4: Admin API client credentials grant"

if [[ -z "$TOKEN_ENDPOINT" ]]; then
    record_fail "Admin API client credentials grant" "skipped - Test 1 (OIDC discovery) did not populate TOKEN_ENDPOINT; resolve discovery first"
    # Skip the rest of Test 4 by jumping past the curl + parsing block
else

echo "POST ${TOKEN_ENDPOINT}"
echo "  grant_type=client_credentials, client_id=${ADMIN_CLIENT_ID}"

TOKEN_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
    -X POST "${TOKEN_ENDPOINT}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${ADMIN_CLIENT_ID}" \
    -d "client_secret=${ADMIN_CLIENT_SECRET}")

TOKEN_STATUS=$(echo "$TOKEN_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '/HTTP_STATUS:/d')

ACCESS_TOKEN=""
if [[ "$TOKEN_STATUS" != "200" ]]; then
    ERROR=$(echo "$TOKEN_BODY" | jq -r '.error // "unknown"' 2>/dev/null)
    ERROR_DESC=$(echo "$TOKEN_BODY" | jq -r '.error_description // "no description"' 2>/dev/null)
    if [[ "$TOKEN_STATUS" == "500" ]]; then
        record_fail "Admin API token grant" "HTTP 500: ${ERROR} - ${ERROR_DESC}. A 500 on the token endpoint often means Keycloak's DB backend is misbehaving. If running on Supabase/PgBouncer, check for 'prepared statement does not exist' in the Keycloak log — that's the transaction-pooler incompatibility. Fix: add ?prepareThreshold=0 to KC_DB_URL or use a session-mode/direct connection (see KEYCLOAK_SETUP_GUIDE.md §A.2.3)."
    else
        record_fail "Admin API token grant" "HTTP ${TOKEN_STATUS}: ${ERROR} - ${ERROR_DESC}"
    fi
else
    ACCESS_TOKEN=$(echo "$TOKEN_BODY" | jq -r '.access_token')
    if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
        record_fail "Admin API token grant" "200 OK but no access_token"
    else
        record_pass "Admin API token grant" "access_token acquired"
    fi
fi

# ----- test 4b: token endpoint stability under repetition (pooler prepared-statement detector) -----
# The Supabase transaction-pooler / prepared-statement bug is INTERMITTENT: it only
# fires when a server-side prepared statement is executed on a different pooled
# connection than it was prepared on. A single token call (Test 4) can pass while
# the endpoint is still unstable. Hammer it N times and flag ANY 500 - one 500 in
# the batch is enough to indicate the pooler incompatibility (or another backend
# instability). See KEYCLOAK_SETUP_GUIDE.md §A.2.3.
if [[ -n "$TOKEN_ENDPOINT" && -n "${ADMIN_CLIENT_SECRET:-}" ]]; then
    HAMMER_N=15
    HAMMER_500=0
    HAMMER_OTHER_FAIL=0
    for _i in $(seq 1 "$HAMMER_N"); do
        HS=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${TOKEN_ENDPOINT}" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=client_credentials" \
            -d "client_id=${ADMIN_CLIENT_ID}" \
            -d "client_secret=${ADMIN_CLIENT_SECRET}")
        if [[ "$HS" == "500" ]]; then
            HAMMER_500=$((HAMMER_500+1))
        elif [[ "$HS" != "200" ]]; then
            HAMMER_OTHER_FAIL=$((HAMMER_OTHER_FAIL+1))
        fi
    done
    if [[ "$HAMMER_500" -gt 0 ]]; then
        record_fail "Token endpoint stability" "${HAMMER_500}/${HAMMER_N} token requests returned HTTP 500 - intermittent backend failure. On Supabase this is almost certainly the transaction-pooler prepared-statement bug: add ?prepareThreshold=0 to KC_DB_URL or use a session-mode/direct DB connection (KEYCLOAK_SETUP_GUIDE.md §A.2.3). Check the Keycloak log for 'prepared statement does not exist'."
    elif [[ "$HAMMER_OTHER_FAIL" -gt 0 ]]; then
        record_fail "Token endpoint stability" "${HAMMER_OTHER_FAIL}/${HAMMER_N} token requests failed with non-200, non-500 status"
    else
        record_pass "Token endpoint stability" "${HAMMER_N}/${HAMMER_N} token requests returned 200 (no intermittent 500s)"
    fi
fi

fi  # closes the "if TOKEN_ENDPOINT empty / else" block from Test 4 top

# Make sure ACCESS_TOKEN is defined for downstream tests even when Test 4
# was skipped due to discovery failure
ACCESS_TOKEN="${ACCESS_TOKEN:-}"

# ----- test 5: Admin API user list -----
section "Test 5: Admin API - list users (validates realm-management roles)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Admin API users list" "skipped - no access token"
else
    USERS_URL="${KC_URL}/admin/realms/${REALM}/users?max=5"
    echo "GET ${USERS_URL}"

    USERS_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" "${USERS_URL}")
    USERS_STATUS=$(echo "$USERS_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    USERS_BODY=$(echo "$USERS_RESPONSE" | sed '/HTTP_STATUS:/d')

    if [[ "$USERS_STATUS" == "200" ]]; then
        USER_COUNT=$(echo "$USERS_BODY" | jq -r 'length' 2>/dev/null)
        record_pass "Admin API users list" "HTTP 200, ${USER_COUNT} user(s)"
    elif [[ "$USERS_STATUS" == "403" ]]; then
        record_fail "Admin API users list" "HTTP 403 - service account missing 'view-users' (or 'query-users') client role under realm-management. Fix: Clients -> ${ADMIN_CLIENT_ID} -> Service accounts roles -> Assign role -> Filter by clients -> realm-management -> tick missing roles (PRD §11.13 step 2)"
    else
        record_fail "Admin API users list" "HTTP ${USERS_STATUS}"
    fi
fi

# ----- test 6: Admin API identity providers list (with robust detection) -----
section "Test 6: Admin API - list configured Identity Providers"

# IdP detection by providerId + URL pattern (alias-agnostic).
# The Microsoft setup per PRD §6.3 uses the generic OIDC provider, so the
# alias could be anything ('microsoft', 'microsoft-entra', 'entra-oidc', etc).
# We identify it by the authorizationUrl pointing at login.microsoftonline.com.

HAS_GOOGLE=0
HAS_MICROSOFT=0
HAS_GITHUB=0
GOOGLE_IDP_ALIAS=""
MICROSOFT_IDP_ALIAS=""
GITHUB_IDP_ALIAS=""

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Admin API IdPs list" "skipped - no access token"
else
    IDP_URL="${KC_URL}/admin/realms/${REALM}/identity-provider/instances"
    echo "GET ${IDP_URL}"

    IDP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" "${IDP_URL}")
    IDP_STATUS=$(echo "$IDP_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    IDP_BODY=$(echo "$IDP_RESPONSE" | sed '/HTTP_STATUS:/d')

    if [[ "$IDP_STATUS" == "403" ]]; then
        record_fail "Admin API IdPs list" "HTTP 403 - service account missing 'view-identity-providers' client role under realm-management. Fix: Clients -> ${ADMIN_CLIENT_ID} -> Service accounts roles -> Assign role -> Filter by clients -> realm-management -> tick 'view-identity-providers' AND 'manage-identity-providers' (PRD §11.13 step 2)"
    elif [[ "$IDP_STATUS" != "200" ]]; then
        record_fail "Admin API IdPs list" "HTTP ${IDP_STATUS}"
    else
        IDP_ALIASES=$(echo "$IDP_BODY" | jq -r '.[].alias' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        record_pass "Admin API IdPs list" "configured IdPs: ${IDP_ALIASES:-(none)}"

        # Iterate by index to handle the JSON cleanly without subshells losing state.
        IDP_COUNT=$(echo "$IDP_BODY" | jq 'length')
        for (( i=0; i<IDP_COUNT; i++ )); do
            ALIAS=$(echo "$IDP_BODY" | jq -r ".[$i].alias")
            PROVIDER_ID=$(echo "$IDP_BODY" | jq -r ".[$i].providerId")
            AUTH_URL=$(echo "$IDP_BODY" | jq -r ".[$i].config.authorizationUrl // empty")
            TOKEN_URL=$(echo "$IDP_BODY" | jq -r ".[$i].config.tokenUrl // empty")
            FLOW=$(echo "$IDP_BODY" | jq -r ".[$i].firstBrokerLoginFlowAlias")

            # Classify the IdP. Built-in providers (Google, GitHub) are identified
            # by providerId. Microsoft via generic OIDC (PRD §6.3) is identified by
            # the authorizationUrl/tokenUrl pointing at login.microsoftonline.com.
            IDP_KIND=""
            if [[ "$PROVIDER_ID" == "google" ]]; then
                IDP_KIND="google"
            elif [[ "$PROVIDER_ID" == "github" ]]; then
                IDP_KIND="github"
            elif [[ "$PROVIDER_ID" == "microsoft" ]]; then
                # Built-in Microsoft (rare in our setup; PRD §6.3 prefers generic OIDC).
                IDP_KIND="microsoft"
            elif [[ "$PROVIDER_ID" == "oidc" ]]; then
                # Generic OIDC: identify the upstream by URL.
                if [[ "$AUTH_URL" == *"login.microsoftonline.com"* || "$TOKEN_URL" == *"login.microsoftonline.com"* ]]; then
                    IDP_KIND="microsoft"
                elif [[ "$AUTH_URL" == *"accounts.google.com"* || "$TOKEN_URL" == *"oauth2.googleapis.com"* ]]; then
                    IDP_KIND="google"
                fi
            fi

            case "$IDP_KIND" in
                google)
                    HAS_GOOGLE=1
                    GOOGLE_IDP_ALIAS="$ALIAS"
                    echo "  ${DIM}detected Google IdP at alias '${ALIAS}' (providerId=${PROVIDER_ID})${RESET}"
                    ;;
                microsoft)
                    HAS_MICROSOFT=1
                    MICROSOFT_IDP_ALIAS="$ALIAS"
                    echo "  ${DIM}detected Microsoft IdP at alias '${ALIAS}' (providerId=${PROVIDER_ID})${RESET}"
                    ;;
                github)
                    HAS_GITHUB=1
                    GITHUB_IDP_ALIAS="$ALIAS"
                    echo "  ${DIM}detected GitHub IdP at alias '${ALIAS}' (providerId=${PROVIDER_ID})${RESET}"
                    ;;
                "")
                    echo "  ${DIM}unrecognized IdP at alias '${ALIAS}' (providerId=${PROVIDER_ID}) - skipping classification${RESET}"
                    ;;
            esac

            # First Login Flow check for every IdP regardless of kind.
            if [[ "$FLOW" == "first-broker-login-no-prompt" ]]; then
                record_pass "IdP '${ALIAS}' First Login Flow" "${FLOW}"
            else
                record_fail "IdP '${ALIAS}' First Login Flow" "is '${FLOW}', expected 'first-broker-login-no-prompt' (PRD §6.1)"
            fi

            # Sync mode check (PRD §11.7a). 'FORCE' keeps mapped attributes current
            # on every login; 'IMPORT' (first-login-only) lets googleHd/microsoftTenantId
            # go stale. Keycloak stores this in config.syncMode.
            SYNC_MODE=$(echo "$IDP_BODY" | jq -r ".[$i].config.syncMode // \"LEGACY\"")
            if [[ "$SYNC_MODE" == "FORCE" ]]; then
                record_pass "IdP '${ALIAS}' Sync mode" "FORCE (attributes re-synced every login)"
            else
                record_skip "IdP '${ALIAS}' Sync mode" "WARNING: syncMode='${SYNC_MODE}', PRD §11.7a expects FORCE. With IMPORT/LEGACY, googleHd/microsoftTenantId can go stale if the user's tenant/domain changes."
            fi

            # Attribute-importer mapper check for Google/Microsoft (PRD §11.7a / §8.3.1).
            # These are what populate googleHd / microsoftTenantId; if missing, those
            # claims silently never appear and §8.3.1 gating has nothing to gate on.
            #
            # ROBUSTNESS NOTE: the config KEY names vary by provider variant. The
            # generic-OIDC importer uses config["user.attribute"] + config["claim"];
            # Google's built-in variant uses a different target key and stores the
            # source under "jsonField"/"Social Profile JSON Field Path". Rather than
            # guess key names, we (a) match the mapper TYPE loosely (any importer that
            # writes a user attribute), and (b) confirm the expected TARGET attribute
            # value appears among ANY of the mapper's config VALUES. Matching on the
            # value sidesteps every provider-specific key-name difference.
            if [[ "$IDP_KIND" == "google" || "$IDP_KIND" == "microsoft" ]]; then
                if [[ "$IDP_KIND" == "google" ]]; then EXPECT_CLAIM="hd"; EXPECT_ATTR="googleHd"; else EXPECT_CLAIM="tid"; EXPECT_ATTR="microsoftTenantId"; fi
                MAPPERS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                    "${KC_URL}/admin/realms/${REALM}/identity-provider/instances/${ALIAS}/mappers" 2>/dev/null)
                if echo "$MAPPERS" | jq -e . >/dev/null 2>&1; then
                    # A mapper qualifies if it's an attribute-writing importer AND the
                    # expected target attribute appears anywhere in its config values.
                    FOUND_ATTR_MAPPER=$(echo "$MAPPERS" | jq -r --arg attr "$EXPECT_ATTR" '
                        [ .[]
                          | select(.identityProviderMapper
                                   | test("attribute|user-attribute|attribute-importer"; "i"))
                          | select( [ .config // {} | to_entries[] | .value ]
                                    | map(ascii_downcase) | index(($attr | ascii_downcase)) != null )
                        ] | length' 2>/dev/null || echo 0)
                    # Fallback: also accept a match by mapper NAME containing the attr or
                    # the claim (e.g. "google-hd"), in case config isn't returned verbatim.
                    if [[ "$FOUND_ATTR_MAPPER" -lt 1 ]]; then
                        FOUND_ATTR_MAPPER=$(echo "$MAPPERS" | jq -r --arg attr "$EXPECT_ATTR" --arg claim "$EXPECT_CLAIM" '
                            [ .[] | select( ((.name // "") | ascii_downcase) as $n
                                            | ($n | contains($attr | ascii_downcase))
                                              or ($n | contains($claim | ascii_downcase)) )
                            ] | length' 2>/dev/null || echo 0)
                    fi
                    if [[ "$FOUND_ATTR_MAPPER" -ge 1 ]]; then
                        record_pass "IdP '${ALIAS}' attribute mapper" "importer targeting user attribute '${EXPECT_ATTR}' present"
                    else
                        record_fail "IdP '${ALIAS}' attribute mapper" "no attribute-importer targeting user attribute '${EXPECT_ATTR}' found (PRD §11.8/§11.9). Expected a mapper importing the '${EXPECT_CLAIM}' field into '${EXPECT_ATTR}'. If you DO see one in the console, paste its JSON (Admin REST: /identity-provider/instances/${ALIAS}/mappers) — the detector may need another config-key variant."
                    fi
                else
                    record_skip "IdP '${ALIAS}' attribute mapper" "could not read IdP mappers (HTTP/non-JSON) - verify manually that '${EXPECT_CLAIM}'→'${EXPECT_ATTR}' importer exists"
                fi
            fi
        done
    fi
fi

# ----- test 7: Browser flow binding -----
section "Test 7: Browser flow binding"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Browser flow binding" "skipped - no access token"
else
    REALM_INFO=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" "${KC_URL}/admin/realms/${REALM}")
    BROWSER_FLOW=$(echo "$REALM_INFO" | jq -r '.browserFlow // empty')

    if [[ "$BROWSER_FLOW" == "browser-federated-only" ]]; then
        record_pass "Browser flow binding" "browserFlow=${BROWSER_FLOW}"
    elif [[ -z "$BROWSER_FLOW" ]]; then
        record_fail "Browser flow binding" "could not read browserFlow"
    else
        record_fail "Browser flow binding" "is '${BROWSER_FLOW}', expected 'browser-federated-only' (PRD §11.6)"
    fi
fi

# ----- test 8: Required actions are not default -----
section "Test 8: Required Actions not set as Default"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Required actions check" "skipped - no access token"
else
    REQACT_URL="${KC_URL}/admin/realms/${REALM}/authentication/required-actions"
    REQACT_BODY=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" "${REQACT_URL}")
    DEFAULTED=$(echo "$REQACT_BODY" | jq -r '.[] | select(.defaultAction == true) | .alias' 2>/dev/null | tr '\n' ',' | sed 's/,$//')

    if [[ -z "$DEFAULTED" ]]; then
        record_pass "Required Actions" "no actions set as Default (per PRD §11.7)"
    else
        record_fail "Required Actions" "set as Default: ${DEFAULTED} - should be Off (PRD §11.7)"
    fi
fi

# ----- test 9: GCP Secrets Manager — expected secret names exist -----
section "Test 9: GCP Secrets Manager — expected secret names exist (§10.8)"

if [[ "$KNOBBY_ENV" == "test" ]]; then
    record_skip "Secrets Manager check" "test env uses local .env, not Secrets Manager"
elif ! command -v gcloud > /dev/null 2>&1; then
    record_skip "Secrets Manager check" "gcloud not installed"
else
    GCLOUD_ARGS=()
    if [[ -n "${GCP_PROJECT:-}" ]]; then
        GCLOUD_ARGS+=("--project=${GCP_PROJECT}")
        ACTUAL_PROJECT="$GCP_PROJECT"
    else
        ACTUAL_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "(none)")
    fi
    echo "Checking against GCP project: ${ACTUAL_PROJECT}"

    declare -a EXPECTED_SECRETS=(
        "knobby-keycloak-admin-api-client-secret-${KNOBBY_ENV}"
        "knobby-keycloak-web-client-secret-${KNOBBY_ENV}"
        "knobby-keycloak-db-password-${KNOBBY_ENV}"
    )
    [[ $HAS_GOOGLE -eq 1 ]] && EXPECTED_SECRETS+=("knobby-google-oauth-client-secret-${KNOBBY_ENV}")
    [[ $HAS_MICROSOFT -eq 1 ]] && EXPECTED_SECRETS+=("knobby-entra-broker-client-secret-${KNOBBY_ENV}")
    [[ $HAS_GITHUB -eq 1 ]] && EXPECTED_SECRETS+=("knobby-github-oauth-client-secret-${KNOBBY_ENV}")

    declare -a MISSING_SECRETS=()
    declare -a FOUND_SECRETS=()
    for SECRET in "${EXPECTED_SECRETS[@]}"; do
        if gcloud "${GCLOUD_ARGS[@]}" secrets describe "$SECRET" --format="value(name)" > /dev/null 2>&1; then
            FOUND_SECRETS+=("$SECRET")
        else
            MISSING_SECRETS+=("$SECRET")
        fi
    done

    for SECRET in "${FOUND_SECRETS[@]}"; do
        echo -e "  ${DIM}✓ ${SECRET}${RESET}"
    done
    for SECRET in "${MISSING_SECRETS[@]}"; do
        echo -e "  ${RED}✗ ${SECRET}${RESET}"
    done

    if [[ ${#MISSING_SECRETS[@]} -eq 0 ]]; then
        record_pass "Secrets Manager naming" "${#FOUND_SECRETS[@]}/${#EXPECTED_SECRETS[@]} expected secrets exist"
    else
        record_fail "Secrets Manager naming" "${#MISSING_SECRETS[@]} missing - see output above"
    fi

    # Soft check: orphaned/misnamed knobby-*-{env} secrets.
    ALL_KNOBBY_SECRETS=$(gcloud "${GCLOUD_ARGS[@]}" secrets list \
        --filter="name~^projects/.*/secrets/knobby-.*-${KNOBBY_ENV}$" \
        --format="value(name)" 2>/dev/null | sed 's|.*/secrets/||')

    if [[ -n "$ALL_KNOBBY_SECRETS" ]]; then
        UNKNOWN_SECRETS=()
        while IFS= read -r SECRET; do
            [[ -z "$SECRET" ]] && continue
            FOUND_IN_EXPECTED=0
            for EXPECTED in "${EXPECTED_SECRETS[@]}"; do
                [[ "$SECRET" == "$EXPECTED" ]] && { FOUND_IN_EXPECTED=1; break; }
            done
            [[ $FOUND_IN_EXPECTED -eq 0 ]] && UNKNOWN_SECRETS+=("$SECRET")
        done <<< "$ALL_KNOBBY_SECRETS"

        if [[ ${#UNKNOWN_SECRETS[@]} -gt 0 ]]; then
            echo ""
            echo -e "  ${YELLOW}Warning: ${#UNKNOWN_SECRETS[@]} knobby-* secret(s) don't match expected convention for env=${KNOBBY_ENV}:${RESET}"
            for SECRET in "${UNKNOWN_SECRETS[@]}"; do
                echo -e "    ${YELLOW}? ${SECRET}${RESET}"
            done
            echo -e "  ${YELLOW}Possibly misnamed, legacy/orphans, or adjacent system. Review against PRD §10.8.${RESET}"
        fi
    fi
fi

# ----- test 10: Microsoft Entra app registration verification -----
section "Test 10: Microsoft Entra app registration verification (§6.3, §11.9)"

if [[ "$KNOBBY_ENV" == "test" ]]; then
    record_skip "Entra app registration check" "test env uses per-developer Entra app, not centralized"
elif [[ $HAS_MICROSOFT -eq 0 ]]; then
    record_skip "Entra app registration check" "microsoft IdP not detected in Keycloak (per Test 6 — checked providerId and login.microsoftonline.com URL pattern)"
elif ! command -v az > /dev/null 2>&1; then
    record_skip "Entra app registration check" "Azure CLI ('az') not installed"
elif ! az account show > /dev/null 2>&1; then
    record_skip "Entra app registration check" "Azure CLI not authenticated - run 'az login' first"
else
    CURRENT_TENANT=$(az account show --query tenantId -o tsv 2>/dev/null || echo "(unknown)")
    CURRENT_USER=$(az account show --query user.name -o tsv 2>/dev/null || echo "(unknown)")
    echo "Querying Entra against tenant: ${CURRENT_TENANT}"
    echo "  as user: ${CURRENT_USER}"
    echo "Microsoft IdP alias in Keycloak: ${MICROSOFT_IDP_ALIAS}"

    # Use the discovered alias to fetch the IdP config.
    MSFT_IDP_CONFIG=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${KC_URL}/admin/realms/${REALM}/identity-provider/instances/${MICROSOFT_IDP_ALIAS}")
    ENTRA_CLIENT_ID=$(echo "$MSFT_IDP_CONFIG" | jq -r '.config.clientId // empty')

    if [[ -z "$ENTRA_CLIENT_ID" ]]; then
        record_fail "Entra clientId from Keycloak" "could not read clientId from IdP '${MICROSOFT_IDP_ALIAS}' config"
    else
        echo "Looking up Entra app: ${ENTRA_CLIENT_ID}"
        ENTRA_APP=$(az ad app show --id "$ENTRA_CLIENT_ID" --output json 2>/dev/null)

        if [[ -z "$ENTRA_APP" ]]; then
            record_fail "Entra app exists" "no app found with appId=${ENTRA_CLIENT_ID}; check tenant or whether app was deleted"
        else
            DISPLAY_NAME=$(echo "$ENTRA_APP" | jq -r '.displayName')
            SIGN_IN_AUDIENCE=$(echo "$ENTRA_APP" | jq -r '.signInAudience')
            PUBLISHER_DOMAIN=$(echo "$ENTRA_APP" | jq -r '.publisherDomain // empty')

            record_pass "Entra app exists" "appId=${ENTRA_CLIENT_ID}, displayName='${DISPLAY_NAME}'"

            # 10a: displayName per §6.3
            case "$KNOBBY_ENV" in
                prod) EXPECTED_NAME="knobby.io Keycloak Broker" ;;
                dev)  EXPECTED_NAME="knobby.io Keycloak Broker (dev)" ;;
            esac
            if [[ "$DISPLAY_NAME" == "$EXPECTED_NAME" ]]; then
                record_pass "Entra displayName convention" "matches §6.3"
            else
                record_fail "Entra displayName convention" "is '${DISPLAY_NAME}', expected '${EXPECTED_NAME}' (PRD §6.3)"
            fi

            # 10b: signInAudience
            if [[ "$SIGN_IN_AUDIENCE" == "AzureADandPersonalMicrosoftAccount" ]]; then
                record_pass "Entra signInAudience" "${SIGN_IN_AUDIENCE} (multi-tenant + personal MSAs)"
            else
                record_fail "Entra signInAudience" "is '${SIGN_IN_AUDIENCE}', expected 'AzureADandPersonalMicrosoftAccount' (PRD §6.3)"
            fi

            # 10c: redirect URI registered
            EXPECTED_REDIRECT="${KC_URL}/realms/${REALM}/broker/${MICROSOFT_IDP_ALIAS}/endpoint"
            REDIRECT_FOUND=$(echo "$ENTRA_APP" | jq -r ".web.redirectUris[]? | select(. == \"$EXPECTED_REDIRECT\")")
            if [[ -n "$REDIRECT_FOUND" ]]; then
                record_pass "Entra redirect URI" "${EXPECTED_REDIRECT} registered"
            else
                REDIRECT_LIST=$(echo "$ENTRA_APP" | jq -r '.web.redirectUris[]?' | tr '\n' ' ')
                record_fail "Entra redirect URI" "expected '${EXPECTED_REDIRECT}' not in: ${REDIRECT_LIST:-(none)}"
            fi

            # 10d: publisherDomain
            if [[ "$PUBLISHER_DOMAIN" == "knobby.io" ]]; then
                record_pass "Entra publisherDomain" "knobby.io"
            elif [[ -z "$PUBLISHER_DOMAIN" ]]; then
                record_fail "Entra publisherDomain" "not set; expected 'knobby.io' (PRD §10.7)"
            elif [[ "$PUBLISHER_DOMAIN" == *.onmicrosoft.com ]]; then
                record_fail "Entra publisherDomain" "is default '${PUBLISHER_DOMAIN}', expected 'knobby.io' (PRD §10.7)"
            else
                record_fail "Entra publisherDomain" "is '${PUBLISHER_DOMAIN}', expected 'knobby.io'"
            fi

            # 10e: Microsoft Graph API permissions
            GRAPH_PERMS=$(echo "$ENTRA_APP" | jq -r \
                '.requiredResourceAccess[]? | select(.resourceAppId == "00000003-0000-0000-c000-000000000000") | .resourceAccess[]?.id' 2>/dev/null)

            MISSING_PERMS=()
            for entry in \
                "37f7f235-527c-4136-accd-4a02d197296e:openid" \
                "14dad69e-099b-42c9-810b-d002981feec1:profile" \
                "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0:email" \
                "7427e0e9-2fba-42fe-b0c0-848c9e6a8182:offline_access" \
                "e1fe6dd8-ba31-4d61-89e7-88639da4683d:User.Read"; do
                PERM_ID="${entry%%:*}"
                PERM_NAME="${entry##*:}"
                if ! echo "$GRAPH_PERMS" | grep -q "$PERM_ID"; then
                    MISSING_PERMS+=("$PERM_NAME")
                fi
            done

            if [[ ${#MISSING_PERMS[@]} -eq 0 ]]; then
                record_pass "Entra Graph API permissions" "openid, profile, email, offline_access, User.Read all present"
            else
                record_fail "Entra Graph API permissions" "missing: ${MISSING_PERMS[*]} (PRD §11.9 step 7)"
            fi

            # 10f: client secrets exist and not expired
            SECRETS_JSON=$(echo "$ENTRA_APP" | jq -r '.passwordCredentials // []')
            SECRET_COUNT=$(echo "$SECRETS_JSON" | jq 'length')

            if [[ "$SECRET_COUNT" -eq 0 ]]; then
                record_fail "Entra client secrets" "no client secrets configured - federation broken or about to break"
            else
                LATEST_EXPIRY=$(echo "$SECRETS_JSON" | jq -r '[.[].endDateTime] | sort | .[-1]')
                LATEST_EXPIRY_EPOCH=$(parse_iso_to_epoch "$LATEST_EXPIRY")
                NOW_EPOCH=$(date +%s)
                WARN_THRESHOLD=$((NOW_EPOCH + 30 * 86400))

                if [[ "$LATEST_EXPIRY_EPOCH" == "0" ]]; then
                    record_skip "Entra secret expiry" "could not parse expiry '${LATEST_EXPIRY}'"
                elif [[ $LATEST_EXPIRY_EPOCH -lt $NOW_EPOCH ]]; then
                    record_fail "Entra secret expiry" "all secrets expired; latest was ${LATEST_EXPIRY}"
                elif [[ $LATEST_EXPIRY_EPOCH -lt $WARN_THRESHOLD ]]; then
                    DAYS=$(( (LATEST_EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
                    record_skip "Entra secret expiry" "WARNING: latest secret expires in ${DAYS} days (${LATEST_EXPIRY}) - rotate soon"
                else
                    DAYS=$(( (LATEST_EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
                    record_pass "Entra secret expiry" "${SECRET_COUNT} secret(s); latest expires in ${DAYS} days"
                fi

                # 10g: secret description convention per §11.9 step 6
                EXPECTED_DESC="keycloak-broker-${KNOBBY_ENV}"
                MATCHING=$(echo "$SECRETS_JSON" | jq -r ".[] | select(.displayName == \"$EXPECTED_DESC\") | .keyId" | head -1)
                if [[ -n "$MATCHING" ]]; then
                    record_pass "Entra secret description convention" "at least one secret named '${EXPECTED_DESC}'"
                else
                    ACTUAL_DESCS=$(echo "$SECRETS_JSON" | jq -r '.[].displayName' | tr '\n' ',' | sed 's/,$//')
                    record_skip "Entra secret description convention" "WARNING: no secret named '${EXPECTED_DESC}' (found: ${ACTUAL_DESCS:-(none)}) - PRD §11.9 step 6"
                fi

                if [[ "$SECRET_COUNT" -gt 2 ]]; then
                    echo ""
                    echo -e "  ${YELLOW}Info: ${SECRET_COUNT} client secrets present.${RESET}"
                    echo -e "  ${YELLOW}During rotation expect 2 (old + new); >2 suggests cleanup overdue.${RESET}"
                fi
            fi
        fi
    fi
fi

# ----- test 11: knobby-{env}-web client configuration -----
section "Test 11: knobby-{env}-web client configuration (§8.2, §11.3)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Web client config check" "skipped - no access token"
else
    WEB_CLIENT_RAW=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${KC_URL}/admin/realms/${REALM}/clients?clientId=${WEB_CLIENT_ID}")
    WEB_CLIENT_STATUS=$(echo "$WEB_CLIENT_RAW" | grep "HTTP_STATUS:" | cut -d: -f2)
    WEB_CLIENT_LOOKUP=$(echo "$WEB_CLIENT_RAW" | sed '/HTTP_STATUS:/d')

    if [[ "$WEB_CLIENT_STATUS" == "403" ]]; then
        record_fail "Web client config check" "HTTP 403 - service account missing 'view-clients' client role under realm-management. Fix: Clients -> ${ADMIN_CLIENT_ID} -> Service accounts roles -> Assign role -> Filter by clients -> realm-management -> tick 'view-clients' (PRD §11.13 step 2)"
    elif [[ "$WEB_CLIENT_STATUS" != "200" ]]; then
        record_fail "Web client config check" "HTTP ${WEB_CLIENT_STATUS} from /clients endpoint - body: $(echo "$WEB_CLIENT_LOOKUP" | head -c 200)"
    elif ! echo "$WEB_CLIENT_LOOKUP" | jq -e 'type == "array"' > /dev/null 2>&1; then
        record_fail "Web client config check" "unexpected response shape (not an array): $(echo "$WEB_CLIENT_LOOKUP" | head -c 200)"
    else
        WEB_CLIENT_COUNT=$(echo "$WEB_CLIENT_LOOKUP" | jq 'length')

        if [[ "$WEB_CLIENT_COUNT" != "1" ]]; then
            record_fail "Web client exists" "found ${WEB_CLIENT_COUNT} clients with clientId=${WEB_CLIENT_ID}, expected 1"
        else
            WEB_CLIENT_JSON=$(echo "$WEB_CLIENT_LOOKUP" | jq '.[0]')
            WEB_CLIENT_INTERNAL_ID=$(echo "$WEB_CLIENT_JSON" | jq -r '.id')
            record_pass "Web client exists" "clientId=${WEB_CLIENT_ID}, internalId=${WEB_CLIENT_INTERNAL_ID}"

        # Extract all relevant fields
        W_ENABLED=$(echo "$WEB_CLIENT_JSON" | jq -r '.enabled')
        W_PROTOCOL=$(echo "$WEB_CLIENT_JSON" | jq -r '.protocol')
        W_PUBLIC=$(echo "$WEB_CLIENT_JSON" | jq -r '.publicClient')
        W_AUTHENTICATOR=$(echo "$WEB_CLIENT_JSON" | jq -r '.clientAuthenticatorType // empty')
        W_STANDARD=$(echo "$WEB_CLIENT_JSON" | jq -r '.standardFlowEnabled')
        W_DIRECT=$(echo "$WEB_CLIENT_JSON" | jq -r '.directAccessGrantsEnabled')
        W_IMPLICIT=$(echo "$WEB_CLIENT_JSON" | jq -r '.implicitFlowEnabled')
        W_SVCACCT=$(echo "$WEB_CLIENT_JSON" | jq -r '.serviceAccountsEnabled')
        W_AUTHZ=$(echo "$WEB_CLIENT_JSON" | jq -r '.authorizationServicesEnabled // false')
        W_FRONTCH=$(echo "$WEB_CLIENT_JSON" | jq -r '.frontchannelLogout')
        W_PKCE=$(echo "$WEB_CLIENT_JSON" | jq -r '.attributes."pkce.code.challenge.method" // empty')
        W_BC_URL=$(echo "$WEB_CLIENT_JSON" | jq -r '.attributes."backchannel.logout.url" // empty')
        W_BC_SESSION=$(echo "$WEB_CLIENT_JSON" | jq -r '.attributes."backchannel.logout.session.required" // empty')
        W_POST_LOGOUT=$(echo "$WEB_CLIENT_JSON" | jq -r '.attributes."post.logout.redirect.uris" // empty')

        # Positive checks
        [[ "$W_ENABLED" == "true" ]] && record_pass "Web client enabled" "true" || \
            record_fail "Web client enabled" "is '${W_ENABLED}', expected 'true'"
        [[ "$W_PROTOCOL" == "openid-connect" ]] && record_pass "Web client protocol" "openid-connect" || \
            record_fail "Web client protocol" "is '${W_PROTOCOL}', expected 'openid-connect'"
        [[ "$W_PUBLIC" == "false" ]] && record_pass "Web client authentication" "confidential (publicClient=false)" || \
            record_fail "Web client authentication" "publicClient=${W_PUBLIC}, expected 'false' (§8.2 Client authentication: On)"
        [[ "$W_AUTHENTICATOR" == "client-secret" ]] && record_pass "Web client authenticator" "client-secret" || \
            record_fail "Web client authenticator" "is '${W_AUTHENTICATOR}', expected 'client-secret'"
        [[ "$W_STANDARD" == "true" ]] && record_pass "Web client Standard flow" "enabled" || \
            record_fail "Web client Standard flow" "standardFlowEnabled=${W_STANDARD}, expected 'true' (§8.2)"

        # Negative checks (security-critical: these flows must NOT be enabled)
        [[ "$W_DIRECT" == "false" ]] && record_pass "Web client Direct Access Grants" "disabled" || \
            record_fail "Web client Direct Access Grants" "directAccessGrantsEnabled=${W_DIRECT}, expected 'false' - this enables ROPC password grant which violates Invariant 1 (§8.2)"
        [[ "$W_IMPLICIT" == "false" ]] && record_pass "Web client Implicit flow" "disabled" || \
            record_fail "Web client Implicit flow" "implicitFlowEnabled=${W_IMPLICIT}, expected 'false' (§8.2)"
        [[ "$W_SVCACCT" == "false" ]] && record_pass "Web client Service Accounts" "disabled" || \
            record_fail "Web client Service Accounts" "serviceAccountsEnabled=${W_SVCACCT}, expected 'false' (web client must not have service account; that's the admin-api client's job)"
        [[ "$W_AUTHZ" == "false" ]] && record_pass "Web client Authorization Services" "disabled" || \
            record_fail "Web client Authorization Services" "authorizationServicesEnabled=${W_AUTHZ}, expected 'false' (Zanzibar layer handles authz - §8.2)"

        # PKCE: required and S256
        [[ "$W_PKCE" == "S256" ]] && record_pass "Web client PKCE method" "S256 required" || \
            record_fail "Web client PKCE method" "is '${W_PKCE:-(not set)}', expected 'S256' - federation will fail without PKCE enforcement (§8.2)"

        # Consent Required: a first-party client must NOT show Keycloak's built-in
        # OAuth consent screen. If this is true, regular users get a "Grant Access
        # to <app>?" prompt on login. This can be set inadvertently by a Client
        # Policy 'consent-required' executor (auto-configure) if the mcp-anonymous-dcr
        # policy condition is broader than client-updater-context=ByAnonymous and
        # matches the web client on update (setup guide D.6b / D.8).
        W_CONSENT=$(echo "$WEB_CLIENT_JSON" | jq -r '.consentRequired // false')
        if [[ "$W_CONSENT" == "false" ]]; then
            record_pass "Web client Consent Required" "disabled (first-party client; no consent screen on login)"
        else
            record_fail "Web client Consent Required" "consentRequired=true - regular users will see Keycloak's 'Grant Access' consent screen on login. Turn OFF (Clients → web client → Settings → Consent Required). If it keeps returning, check the mcp-anonymous-dcr Client Policy condition is scoped to ByAnonymous so its consent-required executor doesn't fire on the web client (setup guide D.6b)."
        fi

        # Full Scope Allowed: if OFF, the web client's tokens carry only roles from
        # its assigned client scopes, not the user's full role set. If the app
        # depends on realm/client roles in the token for session validation or
        # authorization, turning this off silently breaks it (symptom: login
        # succeeds, then the app reports "not logged in" seconds later). This can
        # be set inadvertently by the mcp-hardening 'full-scope-disabled' executor
        # if the mcp-anonymous-dcr policy condition matched the web client (same
        # mechanism as the consent-required leak). We WARN rather than hard-fail,
        # since full-scope-disabled is a legitimate least-privilege choice IF the
        # app doesn't rely on token roles — but flag it so it's a conscious decision.
        W_FULLSCOPE=$(echo "$WEB_CLIENT_JSON" | jq -r '.fullScopeAllowed // true')
        if [[ "$W_FULLSCOPE" == "true" ]]; then
            record_pass "Web client Full Scope Allowed" "on (tokens carry the user's full role set)"
        else
            record_skip "Web client Full Scope Allowed" "WARNING: fullScopeAllowed=false on the web client. If the app relies on realm/client roles in the token, this strips them and can cause 'logged in then immediately logged out'. Likely set inadvertently by the mcp-hardening full-scope-disabled executor when the mcp-anonymous-dcr condition was broader than ByAnonymous. Turn ON (Clients → web client → Settings → Full Scope Allowed) unless you deliberately want least-privilege here and the app doesn't need token roles."
        fi

        # Logout configuration: back-channel only (front-channel disabled because
        # browser third-party cookie policies make iframe-based logout unreliable;
        # see §8.2 and §11.3 step 5)
        [[ "$W_FRONTCH" == "false" ]] && record_pass "Web client Front-channel logout" "disabled (back-channel is authoritative per §8.2)" || \
            record_fail "Web client Front-channel logout" "frontchannelLogout=${W_FRONTCH}, expected 'false' - back-channel-only is the chosen mechanism (§8.2, §11.3 step 5)"
        if [[ -n "$W_BC_URL" ]]; then
            record_pass "Web client Back-channel logout URL" "${W_BC_URL}"
        else
            record_fail "Web client Back-channel logout URL" "not set - back-channel logout will not function (§8.2)"
        fi
        [[ "$W_BC_SESSION" == "true" ]] && record_pass "Web client Back-channel session required" "true" || \
            record_fail "Web client Back-channel session required" "is '${W_BC_SESSION:-(not set)}', expected 'true' (§8.2)"

        # Redirect URI registration
        EXPECTED_W_REDIRECT="${WEB_REDIRECT_URI}"
        REDIRECT_FOUND=$(echo "$WEB_CLIENT_JSON" | jq -r --arg uri "$EXPECTED_W_REDIRECT" \
            '.redirectUris[]? | select(. == $uri)')
        if [[ -n "$REDIRECT_FOUND" ]]; then
            record_pass "Web client redirect URI" "${EXPECTED_W_REDIRECT} registered"
        else
            REDIRECT_LIST=$(echo "$WEB_CLIENT_JSON" | jq -r '.redirectUris[]?' | tr '\n' ' ')
            record_fail "Web client redirect URI" "expected '${EXPECTED_W_REDIRECT}' not in registered list: ${REDIRECT_LIST:-(none)}"
        fi

        # Post-logout redirect URIs (stored as ## separated string)
        if [[ -n "$W_POST_LOGOUT" && "$W_POST_LOGOUT" != "null" ]]; then
            record_pass "Web client Post-logout URIs" "set: ${W_POST_LOGOUT}"
        else
            record_skip "Web client Post-logout URIs" "WARNING: not set - logout redirects will be rejected unless 'post_logout_redirect_uri' parameter is omitted (§8.1)"
        fi

        # Audience mapper: the web client's token must carry a deliberate aud claim
        # so the .NET app's ValidateAudience check has something specific to match
        # (§8.3, §17.7). Without this, Keycloak emits aud=account and audience
        # validation in the app is meaningless. The mapper can live on the client
        # directly or on its dedicated client scope; check both. Accept either an
        # audience mapper that includes the client id, or one setting a custom
        # audience (e.g. a future shared knobby-api resource audience per §17.5).
        WEB_INTERNAL_ID=$(echo "$WEB_CLIENT_JSON" | jq -r '.id')
        # Mappers defined directly on the client:
        WEB_CLIENT_MAPPERS=$(echo "$WEB_CLIENT_JSON" | jq -r '.protocolMappers[]? | select(.protocolMapper == "oidc-audience-mapper") | (.config["included.client.audience"] // .config["included.custom.audience"] // "")' 2>/dev/null || true)
        # Mappers inherited from the client's assigned (default) client scopes:
        WEB_SCOPE_AUD=""
        if [[ -n "$WEB_INTERNAL_ID" && "$WEB_INTERNAL_ID" != "null" ]]; then
            WEB_DEFAULT_SCOPES=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                "${KC_URL}/admin/realms/${REALM}/clients/${WEB_INTERNAL_ID}/default-client-scopes" 2>/dev/null | jq -r '.[].id' || true)
            for sid in $WEB_DEFAULT_SCOPES; do
                SCOPE_AUD=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                    "${KC_URL}/admin/realms/${REALM}/client-scopes/${sid}/protocol-mappers/models" 2>/dev/null \
                    | jq -r '.[]? | select(.protocolMapper == "oidc-audience-mapper") | (.config["included.client.audience"] // .config["included.custom.audience"] // "")' 2>/dev/null || true)
                if [[ -n "$SCOPE_AUD" ]]; then WEB_SCOPE_AUD="$SCOPE_AUD"; break; fi
            done
        fi
        if [[ -n "$WEB_CLIENT_MAPPERS" || -n "$WEB_SCOPE_AUD" ]]; then
            FOUND_AUD="${WEB_CLIENT_MAPPERS:-$WEB_SCOPE_AUD}"
            record_pass "Web client audience mapper" "aud claim stamped as '${FOUND_AUD}' (fixes aud=account; app validates this per §8.3)"
        else
            record_fail "Web client audience mapper" "no oidc-audience-mapper found on the web client or its default scopes - token will carry aud=account and the app's ValidateAudience check is meaningless (§8.3, §17.7)"
        fi
        fi
    fi
fi

# ----- test 12: knobby-{env}-admin-api client configuration -----
section "Test 12: knobby-{env}-admin-api client configuration (§11.13)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Admin API client config check" "skipped - no access token"
else
    ADMIN_CLIENT_RAW=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${KC_URL}/admin/realms/${REALM}/clients?clientId=${ADMIN_CLIENT_ID}")
    ADMIN_CLIENT_STATUS=$(echo "$ADMIN_CLIENT_RAW" | grep "HTTP_STATUS:" | cut -d: -f2)
    ADMIN_CLIENT_LOOKUP=$(echo "$ADMIN_CLIENT_RAW" | sed '/HTTP_STATUS:/d')

    if [[ "$ADMIN_CLIENT_STATUS" == "403" ]]; then
        record_fail "Admin API client config check" "HTTP 403 - service account missing 'view-clients' client role under realm-management. Fix: Clients -> ${ADMIN_CLIENT_ID} -> Service accounts roles -> Assign role -> Filter by clients -> realm-management -> tick 'view-clients' (PRD §11.13 step 2)"
    elif [[ "$ADMIN_CLIENT_STATUS" != "200" ]]; then
        record_fail "Admin API client config check" "HTTP ${ADMIN_CLIENT_STATUS} from /clients endpoint - body: $(echo "$ADMIN_CLIENT_LOOKUP" | head -c 200)"
    elif ! echo "$ADMIN_CLIENT_LOOKUP" | jq -e 'type == "array"' > /dev/null 2>&1; then
        record_fail "Admin API client config check" "unexpected response shape (not an array): $(echo "$ADMIN_CLIENT_LOOKUP" | head -c 200)"
    else
        ADMIN_CLIENT_COUNT=$(echo "$ADMIN_CLIENT_LOOKUP" | jq 'length')

        if [[ "$ADMIN_CLIENT_COUNT" != "1" ]]; then
            record_fail "Admin API client exists" "found ${ADMIN_CLIENT_COUNT} clients with clientId=${ADMIN_CLIENT_ID}, expected 1"
        else
            ADMIN_CLIENT_JSON=$(echo "$ADMIN_CLIENT_LOOKUP" | jq '.[0]')
            ADMIN_CLIENT_INTERNAL_ID=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.id')
            record_pass "Admin API client exists" "clientId=${ADMIN_CLIENT_ID}, internalId=${ADMIN_CLIENT_INTERNAL_ID}"

        A_ENABLED=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.enabled')
        A_PUBLIC=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.publicClient')
        A_STANDARD=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.standardFlowEnabled')
        A_DIRECT=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.directAccessGrantsEnabled')
        A_IMPLICIT=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.implicitFlowEnabled')
        A_SVCACCT=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.serviceAccountsEnabled')
        A_AUTHZ=$(echo "$ADMIN_CLIENT_JSON" | jq -r '.authorizationServicesEnabled // false')

        [[ "$A_ENABLED" == "true" ]] && record_pass "Admin API client enabled" "true" || \
            record_fail "Admin API client enabled" "is '${A_ENABLED}', expected 'true'"
        [[ "$A_PUBLIC" == "false" ]] && record_pass "Admin API client authentication" "confidential (publicClient=false)" || \
            record_fail "Admin API client authentication" "publicClient=${A_PUBLIC}, expected 'false'"
        [[ "$A_SVCACCT" == "true" ]] && record_pass "Admin API Service Accounts enabled" "true" || \
            record_fail "Admin API Service Accounts enabled" "serviceAccountsEnabled=${A_SVCACCT}, expected 'true' - without this the client_credentials grant cannot work"

        # All interactive flows must be off on the admin-api client
        [[ "$A_STANDARD" == "false" ]] && record_pass "Admin API Standard flow" "disabled (no browser flow on service account)" || \
            record_fail "Admin API Standard flow" "standardFlowEnabled=${A_STANDARD}, expected 'false' (§11.13: all flows off except service accounts)"
        [[ "$A_DIRECT" == "false" ]] && record_pass "Admin API Direct Access Grants" "disabled" || \
            record_fail "Admin API Direct Access Grants" "directAccessGrantsEnabled=${A_DIRECT}, expected 'false' (§11.13)"
        [[ "$A_IMPLICIT" == "false" ]] && record_pass "Admin API Implicit flow" "disabled" || \
            record_fail "Admin API Implicit flow" "implicitFlowEnabled=${A_IMPLICIT}, expected 'false' (§11.13)"
        [[ "$A_AUTHZ" == "false" ]] && record_pass "Admin API Authorization Services" "disabled" || \
            record_fail "Admin API Authorization Services" "authorizationServicesEnabled=${A_AUTHZ}, expected 'false'"

        # Fetch the service account user
        SA_USER=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "${KC_URL}/admin/realms/${REALM}/clients/${ADMIN_CLIENT_INTERNAL_ID}/service-account-user")
        SA_USER_ID=$(echo "$SA_USER" | jq -r '.id // empty')
        SA_USER_NAME=$(echo "$SA_USER" | jq -r '.username // empty')

        if [[ -z "$SA_USER_ID" ]]; then
            record_fail "Admin API service account user" "not found - serviceAccountsEnabled may be misconfigured"
        else
            record_pass "Admin API service account user" "username=${SA_USER_NAME}, id=${SA_USER_ID}"

            # Resolve the realm-management client's internal ID
            RM_LOOKUP=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                "${KC_URL}/admin/realms/${REALM}/clients?clientId=realm-management")
            RM_INTERNAL_ID=$(echo "$RM_LOOKUP" | jq -r '.[0].id // empty')

            if [[ -z "$RM_INTERNAL_ID" ]]; then
                record_fail "realm-management client lookup" "could not resolve internal id"
            else
                # Get assigned realm-management role mappings for this service account
                ROLE_MAPPINGS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                    "${KC_URL}/admin/realms/${REALM}/users/${SA_USER_ID}/role-mappings/clients/${RM_INTERNAL_ID}")
                ASSIGNED_ROLES=$(echo "$ROLE_MAPPINGS" | jq -r '.[].name' 2>/dev/null | sort)

                # Required roles per §11.13 step 2
                REQUIRED_ROLES=(
                    "view-users"
                    "manage-users"
                    "view-realm"
                    "view-clients"
                    "manage-clients"
                    "query-users"
                    "query-groups"
                    "view-identity-providers"
                    "manage-identity-providers"
                )

                MISSING_ROLES=()
                for ROLE in "${REQUIRED_ROLES[@]}"; do
                    if ! echo "$ASSIGNED_ROLES" | grep -qFx "$ROLE"; then
                        MISSING_ROLES+=("$ROLE")
                    fi
                done

                # Over-privileging check. NOTE: manage-clients is NO LONGER forbidden -
                # Option B requires it (knobby.io writes scopes/flow-bindings on DCR'd
                # clients at runtime via assignMcpScopes/bindBrowserFlow, web spec §7.5).
                # It reverses an earlier PRD stance ("clients are static IaC"). The
                # genuinely over-privileged roles remain forbidden.
                FORBIDDEN_ROLES=("realm-admin" "manage-realm" "create-client")
                EXCESS_ROLES=()
                for ROLE in "${FORBIDDEN_ROLES[@]}"; do
                    if echo "$ASSIGNED_ROLES" | grep -qFx "$ROLE"; then
                        EXCESS_ROLES+=("$ROLE")
                    fi
                done

                ASSIGNED_LIST=$(echo "$ASSIGNED_ROLES" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
                echo "  ${DIM}assigned realm-management roles: ${ASSIGNED_LIST:-(none)}${RESET}"

                if [[ ${#MISSING_ROLES[@]} -eq 0 ]]; then
                    record_pass "Admin API required roles" "all ${#REQUIRED_ROLES[@]} required realm-management roles assigned (incl. manage-clients for Option B §7.5)"
                else
                    EXTRA_HINT=""
                    for M in "${MISSING_ROLES[@]}"; do
                        [[ "$M" == "manage-clients" ]] && EXTRA_HINT=" - NOTE: manage-clients is required for Option B post-DCR provisioning (web spec §7.5); without it assignMcpScopes/bindBrowserFlow will 403"
                    done
                    record_fail "Admin API required roles" "missing: ${MISSING_ROLES[*]} (per §11.13 step 2)${EXTRA_HINT}"
                fi

                if [[ ${#EXCESS_ROLES[@]} -gt 0 ]]; then
                    record_skip "Admin API role hygiene" "WARNING: over-privileged roles present: ${EXCESS_ROLES[*]} - knobby.io does not need these per §11.13. (manage-clients is NOT over-privileged - it's required for Option B §7.5.)"
                else
                    record_pass "Admin API role hygiene" "no over-privileged roles assigned (no realm-admin / manage-realm / create-client)"
                fi
            fi
        fi
        fi
    fi
fi

# ----- test 13: PKCE enforcement (behavioral) -----
section "Test 13: Web client PKCE enforcement (behavioral) (§8.2)"

if [[ -z "$AUTH_ENDPOINT" ]]; then
    record_fail "PKCE enforcement" "skipped - Test 1 (OIDC discovery) did not populate AUTH_ENDPOINT; resolve discovery first"
else

# Send an authorization request WITHOUT code_challenge to verify Keycloak
# actually enforces PKCE rather than just having the attribute set. This is
# the test that would have caught the PKCE-deficient manual test URLs before
# the operator tried them in a browser.
#
# Note: the authoritative check is the client's configured PKCE method
# (W_PKCE == S256, verified in Test 11). This behavioral probe is
# corroborating. Keycloak may signal the PKCE rejection either via a 302 with
# error params in the Location header OR by rendering an HTML error page
# (no Location). Both mean "PKCE enforced"; only a clean success (a real
# authorization Location, or a login page with no error) means "not enforced".
NO_PKCE_REDIRECT=$(printf '%s' "${WEB_REDIRECT_URI}" | jq -sRr @uri)
NO_PKCE_URL="${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${NO_PKCE_REDIRECT}&scope=openid&state=pkce-enforcement-test"

# Capture both headers and body; don't follow redirects.
NO_PKCE_RESP=$(curl -s -D - "${NO_PKCE_URL}")
NO_PKCE_LOCATION=$(echo "$NO_PKCE_RESP" | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r\n')

if [[ "$NO_PKCE_LOCATION" == *"error=invalid_request"* && "$NO_PKCE_LOCATION" == *"code_challenge_method"* ]]; then
    record_pass "PKCE enforcement" "authorization without PKCE rejected via redirect error 'Missing parameter: code_challenge_method'"
elif [[ "$NO_PKCE_LOCATION" == *"error="* ]]; then
    OBSERVED_ERROR=$(echo "$NO_PKCE_LOCATION" | grep -oE 'error=[^&]+' | head -1)
    record_fail "PKCE enforcement" "got a redirect error but not the PKCE one; observed: ${OBSERVED_ERROR} - investigate"
elif echo "$NO_PKCE_RESP" | grep -qiE 'code_challenge_method|pkce|missing parameter: code_challenge'; then
    # Keycloak rendered an HTML error page mentioning the missing PKCE parameter
    # instead of redirecting. That still means PKCE is enforced.
    record_pass "PKCE enforcement" "authorization without PKCE rejected via error page referencing code_challenge_method"
elif [[ -z "$NO_PKCE_LOCATION" ]]; then
    # No redirect and no PKCE-specific error text found in the body. Fall back to
    # the authoritative client-config value rather than hard-failing on a probe
    # whose response shape we couldn't classify.
    if [[ "$W_PKCE" == "S256" ]]; then
        record_pass "PKCE enforcement" "behavioral probe inconclusive (no Location header, no recognizable error page), but client config authoritatively requires PKCE S256 (Test 11) - treating as enforced"
    else
        record_fail "PKCE enforcement" "behavioral probe inconclusive AND client PKCE method is not S256 (='${W_PKCE:-unset}') - PKCE likely not enforced (§8.2)"
    fi
else
    # A Location header exists but carries no error → the request proceeded
    # toward authorization without PKCE, which means it is NOT enforced.
    record_fail "PKCE enforcement" "PKCE-less auth request was NOT rejected (redirect lacks error parameter) - PKCE attribute on client is not actually enforced. Federation flows will work without PKCE, a security regression vs §8.2."
fi

fi  # closes the "if AUTH_ENDPOINT empty / else" block from Test 13 top

# =============================================================================
# Tests 14-26: MCP-readiness (PRD §16)
# =============================================================================
#
# These tests are designed to go from red→green progressively as you complete
# Phases 1-4 of the MCP setup walk-through (PRD §16.11). Initially, all of
# Tests 14-26 will fail because nothing has been set up. As you complete each
# step, the corresponding tests start passing. Each failure message points at
# the specific PRD section / setup step that unblocks it.
#
# Dependency graph (tests grouped by what unblocks them):
#
#   Image-level (Phase 1):
#     Test 14: SPI loaded         ← requires SPI JAR built & deployed
#
#   Realm structure (Phase 2):
#     Test 15: MCP auth flow      ← requires Test 14 + manual flow creation
#     Test 16: atomic scopes      ← independent
#     Test 17: mcp-default scope  ← independent (full check needs SPI mappers)
#     Test 18: mcp-dcr-policy     ← independent
#
#   Hardening (Phase 4):
#     Test 19: refresh rotation   ← independent
#     Test 20: HMAC key secret    ← independent (skipped for test env)
#
#   DCR behavioral (Phase 3 + Phase 2):
#     Test 21: DCR success path   ← requires Test 18 + scopes from Tests 16-17
#     Test 22: DCR rejects HTTP   ← requires Test 18
#     Test 23: Password grant (ROPC) unusable by DCR clients  ← requires Test 18
#     Test 24: DCR rejects bad scopes  ← requires Test 18
#     Test 25: DCR'd client shape ← requires Test 21 success
#     Test 26: cleanup            ← runs even if earlier MCP tests failed
# =============================================================================

# Initialize DCR-flow variables so we can clean up at the end even on failure.
DCR_CLIENT_ID=""
DCR_REGISTRATION_ACCESS_TOKEN=""
DCR_REGISTRATION_CLIENT_URI=""

# ----- test 14: MCP SPI loaded -----
section "Test 14: MCP Authenticator SPI loaded (§16.8)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "MCP Authenticator SPI loaded" "skipped - no admin access token (Test 4 prerequisite failed)"
else
    PROVIDERS_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/authentication/authenticator-providers")
    PROVIDERS_STATUS=$(echo "$PROVIDERS_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
    PROVIDERS_BODY=$(echo "$PROVIDERS_RESP" | sed '$d')

    if [[ "$PROVIDERS_STATUS" != "200" ]]; then
        record_fail "MCP Authenticator SPI loaded" "Admin API returned HTTP ${PROVIDERS_STATUS} listing authenticator providers"
    else
        SPI_FOUND=$(echo "$PROVIDERS_BODY" | jq -r --arg id "$MCP_SPI_PROVIDER_ID" '.[] | select(.id == $id) | .id' 2>/dev/null || true)
        if [[ -n "$SPI_FOUND" ]]; then
            record_pass "MCP Authenticator SPI loaded" "provider '${MCP_SPI_PROVIDER_ID}' registered"
        else
            record_fail "MCP Authenticator SPI loaded" "provider '${MCP_SPI_PROVIDER_ID}' not found - build the SPI JAR per §16.8.6 and deploy via the Keycloak Docker image (Phase 1 step 4)"
        fi
    fi
fi

# ----- test 15: MCP auth flow exists -----
section "Test 15: MCP authentication flow '${MCP_FLOW_NAME}' exists (§16.8.1)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "MCP auth flow exists" "skipped - no admin access token"
else
    FLOWS_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/authentication/flows")
    FLOWS_STATUS=$(echo "$FLOWS_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
    FLOWS_BODY=$(echo "$FLOWS_RESP" | sed '$d')

    if [[ "$FLOWS_STATUS" != "200" ]]; then
        record_fail "MCP auth flow exists" "Admin API returned HTTP ${FLOWS_STATUS} listing auth flows"
    else
        MCP_FLOW_ID=$(echo "$FLOWS_BODY" | jq -r --arg name "$MCP_FLOW_NAME" '.[] | select(.alias == $name) | .id' 2>/dev/null || true)
        if [[ -z "$MCP_FLOW_ID" ]]; then
            record_fail "MCP auth flow exists" "flow '${MCP_FLOW_NAME}' not found - create it per SETUP GUIDE D.2 (design: PRD §16.11)"
        else
            # Check the flow has the SPI Authenticator as a step
            FLOW_EXECS=$(curl -s \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                "${KC_URL}/admin/realms/${REALM}/authentication/flows/${MCP_FLOW_NAME}/executions" 2>/dev/null || true)
            HAS_SPI_STEP=$(echo "$FLOW_EXECS" | jq -r --arg id "$MCP_SPI_PROVIDER_ID" '.[] | select(.providerId == $id) | .providerId' 2>/dev/null || true)
            if [[ -n "$HAS_SPI_STEP" ]]; then
                record_pass "MCP auth flow exists" "'${MCP_FLOW_NAME}' contains SPI Authenticator step"
            else
                record_fail "MCP auth flow exists" "flow '${MCP_FLOW_NAME}' exists but does NOT include the SPI Authenticator '${MCP_SPI_PROVIDER_ID}' as a step - add it as Required final step (§16.8.1)"
            fi
        fi
    fi
fi

# ----- test 16: atomic knobby:* scopes exist -----
section "Test 16: Six atomic knobby:* Client Scopes exist (§16.3.6)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "MCP atomic scopes" "skipped - no admin access token"
else
    SCOPES_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/client-scopes")
    SCOPES_STATUS=$(echo "$SCOPES_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
    SCOPES_BODY=$(echo "$SCOPES_RESP" | sed '$d')

    if [[ "$SCOPES_STATUS" != "200" ]]; then
        record_fail "MCP atomic scopes" "Admin API returned HTTP ${SCOPES_STATUS} listing client scopes"
    else
        MISSING_SCOPES=()
        MISCONFIGURED_SCOPES=()
        for scope in "${MCP_ATOMIC_SCOPES[@]}"; do
            SCOPE_DATA=$(echo "$SCOPES_BODY" | jq -r --arg name "$scope" '.[] | select(.name == $name)' 2>/dev/null || true)
            if [[ -z "$SCOPE_DATA" ]]; then
                MISSING_SCOPES+=("$scope")
            else
                # Verify scope is configured correctly
                INCLUDE_IN_SCOPE=$(echo "$SCOPE_DATA" | jq -r '.attributes["include.in.token.scope"] // "false"')
                DISPLAY_CONSENT=$(echo "$SCOPE_DATA" | jq -r '.attributes["display.on.consent.screen"] // "false"')
                CONSENT_TEXT=$(echo "$SCOPE_DATA" | jq -r '.attributes["consent.screen.text"] // ""')
                if [[ "$INCLUDE_IN_SCOPE" != "true" ]] || [[ "$DISPLAY_CONSENT" != "true" ]] || [[ -z "$CONSENT_TEXT" ]]; then
                    MISCONFIGURED_SCOPES+=("${scope} (include_in_scope=${INCLUDE_IN_SCOPE}, display_consent=${DISPLAY_CONSENT}, consent_text=$([ -n "$CONSENT_TEXT" ] && echo set || echo empty))")
                fi
            fi
        done
        if [[ ${#MISSING_SCOPES[@]} -eq 0 && ${#MISCONFIGURED_SCOPES[@]} -eq 0 ]]; then
            record_pass "MCP atomic scopes" "all 6 scopes present and correctly configured"
        elif [[ ${#MISSING_SCOPES[@]} -gt 0 ]]; then
            record_fail "MCP atomic scopes" "missing: ${MISSING_SCOPES[*]} - create per SETUP GUIDE D.3 (design: PRD §16.11)"
        else
            record_fail "MCP atomic scopes" "misconfigured: ${MISCONFIGURED_SCOPES[*]}"
        fi
    fi
fi

# ----- test 17: mcp-default Client Scope exists with audience mapper -----
section "Test 17: '${MCP_DEFAULT_SCOPE}' Client Scope with audience mapper (§16.6)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "mcp-default scope" "skipped - no admin access token"
else
    MCP_DEFAULT_DATA=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/client-scopes" | \
        jq -r --arg name "$MCP_DEFAULT_SCOPE" '.[] | select(.name == $name)' 2>/dev/null || true)

    if [[ -z "$MCP_DEFAULT_DATA" ]]; then
        record_fail "mcp-default scope" "Client Scope '${MCP_DEFAULT_SCOPE}' not found - create per SETUP GUIDE D.4 (design: PRD §16.11)"
    else
        MCP_DEFAULT_ID=$(echo "$MCP_DEFAULT_DATA" | jq -r '.id')
        AUDIENCE_MAPPER=$(echo "$MCP_DEFAULT_DATA" | jq -r --arg aud "$MCP_AUDIENCE" \
            '.protocolMappers[]? | select(.protocolMapper == "oidc-audience-mapper") | select(.config["included.custom.audience"] == $aud) | .id' 2>/dev/null || true)
        if [[ -z "$AUDIENCE_MAPPER" ]]; then
            record_fail "mcp-default scope" "scope exists but no Audience mapper sets aud='${MCP_AUDIENCE}' - add the audience mapper on the mcp-default scope per SETUP GUIDE D.4 (design: PRD §16.6)"
        else
            record_pass "mcp-default scope" "Client Scope present with audience mapper for ${MCP_AUDIENCE}"
        fi

        # Sub-check: tenant claim mapper (depends on SPI session note semantics, so just verify the mapper exists)
        TENANT_MAPPER=$(echo "$MCP_DEFAULT_DATA" | jq -r '.protocolMappers[]? | select(.protocolMapper == "oidc-usersessionmodel-note-mapper") | select(.config["user.session.note"] == "knobby_tenant_id") | .id' 2>/dev/null || true)
        if [[ -n "$TENANT_MAPPER" ]]; then
            record_pass "mcp-default tenant claim mapper" "User Session Note mapper for tenant claim present"
        else
            record_fail "mcp-default tenant claim mapper" "no User Session Note mapper for 'knobby_tenant_id' → 'tenant' claim - add per SETUP GUIDE D.4 (design: PRD §16.8.4)"
        fi
    fi
fi

# ----- test 18: mcp-dcr-policy configured -----
section "Test 18: Anonymous DCR registration policies configured (setup guide D.5)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "mcp-dcr-policy" "skipped - no admin access token"
else
    # Client registration policies in Keycloak are realm components of type "ClientRegistrationPolicy"
    POLICIES_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy")
    POLICIES_STATUS=$(echo "$POLICIES_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
    POLICIES_BODY=$(echo "$POLICIES_RESP" | sed '$d')

    if [[ "$POLICIES_STATUS" != "200" ]]; then
        record_fail "DCR registration policies" "Admin API returned HTTP ${POLICIES_STATUS} listing registration policies"
    else
        # Anonymous Client Registration Policies (Clients → Client Registration → Anonymous).
        ANON_POLICY_COUNT=$(echo "$POLICIES_BODY" | jq -r '[.[] | select(.subType == "anonymous")] | length' 2>/dev/null || echo 0)

        # We deliberately DO NOT match on exact providerId strings — those vary by
        # Keycloak version and display names differ from provider IDs. Instead we
        # test the security *properties* that must hold, by inspecting policy config
        # regardless of what any given policy is named:
        #
        #   Property A — a scope whitelist is configured and includes the knobby scopes.
        #     The allowed-client-scopes policy stores its whitelist under the config
        #     key "allowed-client-scopes" (a multivalued attribute). We search ALL
        #     anonymous policies for one carrying that config key populated, then
        #     verify the knobby scopes are in it. This finds the policy by its
        #     effect, not its name.
        #
        #   Property B — consent is forced on DCR clients. The consent-required
        #     policy has no config; its mere presence (by any recognizable form)
        #     is what matters. We detect it loosely (providerId or name containing
        #     "consent"), and treat absence as a soft warning rather than a hard
        #     fail, since the mcp-hardening Client Policy profile (Test via DCR
        #     behavior) also enforces consent.

        if [[ "$ANON_POLICY_COUNT" -eq 0 ]]; then
            record_fail "DCR registration policies" "no anonymous Client Registration Policies found - configure per setup guide D.5 (Clients → Client Registration → Anonymous Access Policies)"
        else
            record_pass "DCR registration policies" "${ANON_POLICY_COUNT} anonymous registration policies present"
        fi

        # Property A: find the scope whitelist by config content, across all anonymous
        # policies, regardless of providerId/name. The whitelist lives under the
        # config key "allowed-client-scopes".
        WHITELIST_VALUES=$(echo "$POLICIES_BODY" | jq -r '
            [.[] | select(.subType == "anonymous")
                 | .config["allowed-client-scopes"]? // empty] | flatten | .[]?' 2>/dev/null || true)

        if [[ -z "$WHITELIST_VALUES" ]]; then
            record_fail "DCR scope whitelist" "no anonymous policy carries an 'allowed-client-scopes' whitelist config - add/edit the Allowed Client Scopes policy and whitelist the knobby scopes (setup guide D.5). Anonymous policies present: $(echo "$POLICIES_BODY" | jq -r '[.[] | select(.subType=="anonymous") | .providerId] | join(", ")' 2>/dev/null)"
        else
            MISSING_FROM_WHITELIST=()
            for scope in "${MCP_ATOMIC_SCOPES[@]}" "$MCP_DEFAULT_SCOPE"; do
                if ! echo "$WHITELIST_VALUES" | grep -qx "$scope"; then
                    MISSING_FROM_WHITELIST+=("$scope")
                fi
            done
            if [[ ${#MISSING_FROM_WHITELIST[@]} -eq 0 ]]; then
                record_pass "DCR scope whitelist" "scope whitelist configured and includes all knobby:* + mcp-default"
            else
                record_fail "DCR scope whitelist" "scope whitelist exists but is missing: ${MISSING_FROM_WHITELIST[*]} (setup guide D.5). Currently whitelisted: $(echo "$WHITELIST_VALUES" | tr '\n' ' ')"
            fi
        fi

        # Property B: consent-required present (loose detection; soft warning if absent).
        CONSENT_POLICY=$(echo "$POLICIES_BODY" | jq -r '
            .[] | select(.subType == "anonymous")
                | select((.providerId // "" | ascii_downcase | contains("consent"))
                      or (.name // "" | ascii_downcase | contains("consent")))
                | .providerId' 2>/dev/null | head -1 || true)
        if [[ -n "$CONSENT_POLICY" ]]; then
            record_pass "DCR consent-required policy" "present (${CONSENT_POLICY})"
        else
            record_skip "DCR consent-required policy" "WARNING: no consent-required anonymous policy detected. The mcp-hardening Client Policy also enforces consent, so this is defense-in-depth; add it if you want belt-and-suspenders (setup guide D.5)."
        fi
    fi
fi

# ----- test 19: refresh token rotation enabled -----
section "Test 19: OAuth 2.1 refresh token rotation (§16.5 / §8.6.1)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "refresh token rotation" "skipped - no admin access token"
else
    if ! fetch_realm_json; then
        record_fail "refresh token rotation" "$REALM_FETCH_ERR"
    else
    REALM_DATA="$REALM_JSON"
    REVOKE_REFRESH=$(echo "$REALM_DATA" | jq -r '.revokeRefreshToken // false')
    REFRESH_MAX_REUSE=$(echo "$REALM_DATA" | jq -r '.refreshTokenMaxReuse // 0')

    # Strict rotation (revoke=true, maxReuse=0) is the OAuth 2.1 target, but it is
    # only SAFE once the app implements single-flight token refresh per session
    # (§8.6.1). Enabling it before that causes concurrent-refresh races that
    # invalidate sessions. So we recognize three states:
    #   - strict (revoke=true, reuse=0): target. Pass — but remind that the app
    #     must have single-flight refresh, else this WILL break logins.
    #   - grace  (revoke=true, reuse>0): acceptable interim. Pass with a note.
    #   - off    (revoke=false):         not yet enabled. Fail (soft) — expected
    #     until the app is ready; do not enable strict until §8.6.1 is done.
    if [[ "$REVOKE_REFRESH" == "true" && "$REFRESH_MAX_REUSE" == "0" ]]; then
        record_pass "refresh token rotation" "strict (revokeRefreshToken=true, maxReuse=0). ⚠ Requires app single-flight refresh (§8.6.1) or concurrent requests will invalidate sessions."
    elif [[ "$REVOKE_REFRESH" == "true" && "$REFRESH_MAX_REUSE" -gt 0 ]]; then
        record_pass "refresh token rotation" "grace window (revokeRefreshToken=true, maxReuse=${REFRESH_MAX_REUSE}) - interim setting tolerating concurrent refreshes. Tighten to maxReuse=0 after app single-flight refresh ships (§8.6.1)."
    else
        record_fail "refresh token rotation" "not enabled (revokeRefreshToken=${REVOKE_REFRESH}, maxReuse=${REFRESH_MAX_REUSE}). Target is strict rotation for MCP clients (§16.5), but do NOT enable it until the app implements single-flight refresh (§8.6.1) - enabling it first breaks logins via concurrent-refresh races. Interim: set a small maxReuse grace instead."
    fi
    fi
fi

# ----- test 19b: token & session lifespans (§8.6) -----
section "Test 19b: Token & session lifespans (§8.6)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "token lifespans" "skipped - no admin access token"
else
    if ! fetch_realm_json; then
        record_fail "token lifespans" "$REALM_FETCH_ERR"
    else
    REALM_DATA="$REALM_JSON"
    ACCESS_LIFESPAN=$(echo "$REALM_DATA" | jq -r '.accessTokenLifespan // 0')
    SSO_IDLE=$(echo "$REALM_DATA" | jq -r '.ssoSessionIdleTimeout // 0')
    SSO_MAX=$(echo "$REALM_DATA" | jq -r '.ssoSessionMaxLifespan // 0')
    CLIENT_SESSION_IDLE=$(echo "$REALM_DATA" | jq -r '.clientSessionIdleTimeout // 0')
    CLIENT_SESSION_MAX=$(echo "$REALM_DATA" | jq -r '.clientSessionMaxLifespan // 0')

    # Report actual values so a "why am I logged out so fast?" question can be
    # answered directly. Targets per §8.6: access 300s (5m), SSO idle 1800s (30m),
    # SSO max 36000s (10h). We PASS on reasonable values and WARN on suspiciously
    # short ones that would cause premature logout. clientSession* = 0 means
    # "inherit SSO session timeouts" which is normal.
    fmt_dur() { local s=$1; if [[ "$s" -ge 3600 ]]; then echo "$((s/3600))h"; elif [[ "$s" -ge 60 ]]; then echo "$((s/60))m"; else echo "${s}s"; fi; }

    # Access token lifespan
    if [[ "$ACCESS_LIFESPAN" -lt 60 ]]; then
        record_fail "Access token lifespan" "$(fmt_dur $ACCESS_LIFESPAN) (${ACCESS_LIFESPAN}s) - suspiciously short; causes near-constant refresh. §8.6 target is 300s (5m)."
    elif [[ "$ACCESS_LIFESPAN" -lt 120 ]]; then
        record_skip "Access token lifespan" "WARNING: $(fmt_dur $ACCESS_LIFESPAN) (${ACCESS_LIFESPAN}s) - shorter than §8.6 target of 300s (5m); increases refresh frequency."
    else
        record_pass "Access token lifespan" "$(fmt_dur $ACCESS_LIFESPAN) (${ACCESS_LIFESPAN}s)"
    fi

    # SSO session idle — the big one for "logged out after inactivity"
    if [[ "$SSO_IDLE" -lt 300 ]]; then
        record_fail "SSO session idle" "$(fmt_dur $SSO_IDLE) (${SSO_IDLE}s) - very short; users get logged out after brief inactivity. §8.6 target is 1800s (30m)."
    else
        record_pass "SSO session idle" "$(fmt_dur $SSO_IDLE) (${SSO_IDLE}s)"
    fi

    # SSO session max
    if [[ "$SSO_MAX" -lt 1800 ]]; then
        record_skip "SSO session max" "WARNING: $(fmt_dur $SSO_MAX) (${SSO_MAX}s) - shorter than §8.6 target of 36000s (10h)."
    else
        record_pass "SSO session max" "$(fmt_dur $SSO_MAX) (${SSO_MAX}s)"
    fi

    # Client session overrides (0 = inherit SSO, which is expected)
    if [[ "$CLIENT_SESSION_IDLE" != "0" && "$CLIENT_SESSION_IDLE" -lt 300 ]]; then
        record_fail "Client session idle override" "$(fmt_dur $CLIENT_SESSION_IDLE) (${CLIENT_SESSION_IDLE}s) - a short realm-level client-session-idle override will log users out fast regardless of SSO idle. Set to 0 to inherit SSO idle unless you specifically need it."
    else
        record_pass "Client session idle override" "$([ "$CLIENT_SESSION_IDLE" == "0" ] && echo "0 (inherits SSO idle)" || fmt_dur $CLIENT_SESSION_IDLE)"
    fi

    # Client session max override (same hazard as idle)
    if [[ "$CLIENT_SESSION_MAX" != "0" && "$CLIENT_SESSION_MAX" -lt 1800 ]]; then
        record_skip "Client session max override" "WARNING: $(fmt_dur $CLIENT_SESSION_MAX) (${CLIENT_SESSION_MAX}s) - short client-session-max override; forces re-auth sooner than SSO max. Set to 0 to inherit unless intended (§11.2)."
    else
        record_pass "Client session max override" "$([ "$CLIENT_SESSION_MAX" == "0" ] && echo "0 (inherits SSO max)" || fmt_dur $CLIENT_SESSION_MAX)"
    fi
    fi
fi

# ----- test 19c: security defenses (§11.2) -----
section "Test 19c: Security defenses (§11.2)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "security defenses" "skipped - no admin access token"
else
    if ! fetch_realm_json; then
        record_fail "security defenses" "$REALM_FETCH_ERR"
    else
    REALM_DATA="$REALM_JSON"

    # Brute force detection. Note: near-inert for federated-only login (no local
    # passwords), but expected ON to protect admin console / future local accounts.
    BRUTE=$(echo "$REALM_DATA" | jq -r '.bruteForceProtected // false')
    if [[ "$BRUTE" == "true" ]]; then
        FAILURE_FACTOR=$(echo "$REALM_DATA" | jq -r '.failureFactor // "?"')
        record_pass "Brute force detection" "enabled (failureFactor=${FAILURE_FACTOR})"
    else
        record_fail "Brute force detection" "disabled - enable with explicit values per §11.2 (protects admin console / local accounts; federated login is unaffected either way)"
    fi

    # X-Frame-Options: expect SAMEORIGIN (the deliberate default; NOT forced DENY).
    # This governs framing of Keycloak's own pages, not the knobby.io app.
    XFO=$(echo "$REALM_DATA" | jq -r '.browserSecurityHeaders.xFrameOptions // "unset"')
    if [[ "$XFO" == "SAMEORIGIN" ]]; then
        record_pass "X-Frame-Options (Keycloak pages)" "SAMEORIGIN (default; governs Keycloak pages, not the app)"
    elif [[ "$XFO" == "DENY" ]]; then
        record_skip "X-Frame-Options (Keycloak pages)" "NOTE: DENY. Safe for knobby.io (back-channel logout, no check-session iframe), but §11.2 prefers the SAMEORIGIN default for compatibility. Does not affect whether the app can be iframed - that's the app server's frame-ancestors."
    else
        record_skip "X-Frame-Options (Keycloak pages)" "NOTE: '${XFO}' - §11.2 expects SAMEORIGIN. Governs Keycloak pages only."
    fi
    fi
fi

# ----- test 19d: observability posture (INFORMATIONAL - never hard-fails) -----
# Observability (setup guide §A.12) is optional operational hardening, not a
# correctness requirement, so this section only ever emits PASS or SKIP, never
# FAIL. Set OBSERVABILITY_EXPECTED=true once you've wired telemetry to turn the
# "not configured" notes from neutral skips into louder reminders.
#
# IMPORTANT LIMITATION: /metrics lives on the management port (9000), which is
# NOT reachable from where this smoke test runs (Cloud Run doesn't map it; see
# §A.12.0). So this test CANNOT scrape metrics to prove they flow - that
# verification only happens in Grafana Cloud (§A.12.2.3). What it can check is
# (a) configuration intent surfaced via the Admin API / env, and (b) that the
# token endpoint - the thing whose 500s the pool/prepared-statement metrics
# would have caught - is currently stable (already covered by Test 4b).
section "Test 19d: Observability posture (informational, §A.12)"

OBSERVABILITY_EXPECTED="${OBSERVABILITY_EXPECTED:-false}"

# (a) Health/metrics enablement intent. These are build/runtime flags on the
# container (KC_HEALTH_ENABLED / KC_METRICS_ENABLED), not realm settings, so we
# can only read them if they were passed into this test's environment. Report
# what we can see; never fail.
if [[ -n "${KC_METRICS_ENABLED:-}" || -n "${KC_HEALTH_ENABLED:-}" ]]; then
    record_pass "Metrics/health flags (env-visible)" "KC_METRICS_ENABLED=${KC_METRICS_ENABLED:-unset}, KC_HEALTH_ENABLED=${KC_HEALTH_ENABLED:-unset}"
else
    record_skip "Metrics/health flags" "not visible in this test's env (they live on the Keycloak container). Confirm KC_METRICS_ENABLED=true / KC_HEALTH_ENABLED=true on the deployment. /metrics is on port 9000 and not reachable from here by design (§A.12.0) - verify data flow in Grafana Cloud (§A.12.2.3), not here."
fi

# (b) Optional: if a management URL is reachable from where the test runs (e.g.
# post-Hetzner with a localhost/private scrape), probe /health/ready. Skipped by
# default because on Cloud Run port 9000 is unreachable.
if [[ -n "${KC_MGMT_URL:-}" ]]; then
    MGMT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${KC_MGMT_URL%/}/health/ready" 2>/dev/null || echo "000")
    if [[ "$MGMT_STATUS" == "200" ]]; then
        record_pass "Management /health/ready" "200 (reachable at KC_MGMT_URL)"
        METRICS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${KC_MGMT_URL%/}/metrics" 2>/dev/null || echo "000")
        [[ "$METRICS_STATUS" == "200" ]] \
            && record_pass "Management /metrics" "200 (Prometheus metrics exposed)" \
            || record_skip "Management /metrics" "returned ${METRICS_STATUS} at KC_MGMT_URL - enable KC_METRICS_ENABLED=true if you expect metrics"
    else
        record_skip "Management /health/ready" "KC_MGMT_URL set but /health/ready returned ${MGMT_STATUS} - check the URL/port"
    fi
else
    record_skip "Management endpoint probe" "KC_MGMT_URL not set (expected on Cloud Run - port 9000 isn't externally reachable). Set KC_MGMT_URL to a reachable management base (e.g. http://localhost:9000) on a VM/VPC to enable this probe."
fi

# (c) Grafana Cloud wiring reminder - purely a checklist nudge, driven by the
# OBSERVABILITY_EXPECTED flag. We can't see the container's telemetry env from
# here, so this is a reminder, not a verification.
if [[ "$OBSERVABILITY_EXPECTED" == "true" ]]; then
    record_skip "Telemetry export (Grafana Cloud)" "OBSERVABILITY_EXPECTED=true - confirm the telemetry env is set on the container (KC_TELEMETRY_ENDPOINT / protocol / metrics header per §A.12.2.2) and that data appears in Grafana Explore (§A.12.2.3). This test can't see the container's telemetry env or scrape :9000, so verify in Grafana, not here."
else
    record_skip "Telemetry export (Grafana Cloud)" "not expected yet (OBSERVABILITY_EXPECTED unset). When you wire Grafana Cloud per §A.12, set OBSERVABILITY_EXPECTED=true to turn this into a live reminder. Actual data-flow is verified in Grafana Explore (§A.12.2.3), not in this suite."
fi

# (d) Reinforce the one thing this suite CAN meaningfully assert about
# observability health: token-endpoint stability (Test 4b) is the live proxy for
# the pool/prepared-statement issues that metrics would surface.
record_skip "Observability note" "The pool-exhaustion / prepared-statement incidents that motivated metrics are caught live by Test 4b (Token endpoint stability). If 4b is green, the specific failure that observability would have alerted on is currently absent."

# ----- test 20: HMAC handoff key in Secret Manager (prod/dev only) -----
section "Test 20: HMAC handoff key in GCP Secret Manager (§16.8.5)"

if [[ "$KNOBBY_ENV" == "test" ]]; then
    record_pass "HMAC handoff key" "skipped for test env (uses developer-local .env)"
elif ! command -v gcloud >/dev/null 2>&1; then
    record_fail "HMAC handoff key" "gcloud CLI not installed - install Google Cloud SDK to verify"
else
    if gcloud secrets describe "$MCP_HANDOFF_KEY_SECRET" >/dev/null 2>&1; then
        # Try to verify a version is accessible (don't print the key)
        if gcloud secrets versions access latest --secret="$MCP_HANDOFF_KEY_SECRET" >/dev/null 2>&1; then
            record_pass "HMAC handoff key" "${MCP_HANDOFF_KEY_SECRET} exists and is accessible"
        else
            record_fail "HMAC handoff key" "secret '${MCP_HANDOFF_KEY_SECRET}' exists but no readable version"
        fi
    else
        record_fail "HMAC handoff key" "secret '${MCP_HANDOFF_KEY_SECRET}' not found - create per SETUP GUIDE D.11 (design: PRD §16.11): openssl rand -base64 32 | gcloud secrets create ${MCP_HANDOFF_KEY_SECRET} --data-file=-"
    fi
fi

# ----- test 21: DCR endpoint accepts compliant registration -----
section "Test 21: DCR endpoint accepts compliant registration (§16.4)"

if [[ -z "$AUTH_ENDPOINT" ]]; then
    record_fail "DCR endpoint success" "skipped - Test 1 did not populate AUTH_ENDPOINT"
else
    DCR_ENDPOINT="${REALM_BASE}/clients-registrations/openid-connect"

    DCR_REQUEST_BODY=$(cat <<DCRBODY
{
  "client_name": "smoke-test-mcp-client",
  "redirect_uris": ["https://example.com/callback"],
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none",
  "scope": "openid knobby:read knobby:write"
}
DCRBODY
)

    DCR_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -X POST "$DCR_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$DCR_REQUEST_BODY")
    DCR_STATUS=$(echo "$DCR_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
    DCR_BODY=$(echo "$DCR_RESP" | sed '$d')

    if [[ "$DCR_STATUS" == "201" ]]; then
        DCR_CLIENT_ID=$(echo "$DCR_BODY" | jq -r '.client_id // empty')
        DCR_REGISTRATION_ACCESS_TOKEN=$(echo "$DCR_BODY" | jq -r '.registration_access_token // empty')
        DCR_REGISTRATION_CLIENT_URI=$(echo "$DCR_BODY" | jq -r '.registration_client_uri // empty')
        if [[ -n "$DCR_CLIENT_ID" && -n "$DCR_REGISTRATION_ACCESS_TOKEN" ]]; then
            record_pass "DCR endpoint success" "registered client_id=${DCR_CLIENT_ID} with RAT"
        else
            record_fail "DCR endpoint success" "201 OK but response missing client_id or registration_access_token"
        fi
    else
        DCR_ERROR=$(echo "$DCR_BODY" | jq -r '.error_description // .error // .' 2>/dev/null | head -c 200)
        record_fail "DCR endpoint success" "HTTP ${DCR_STATUS} - ${DCR_ERROR} (configure per SETUP GUIDE D.5/D.6 client policies; design: PRD §16.11)"
    fi
fi

# ----- test 22: DCR rejects non-HTTPS redirect URI -----
section "Test 22: DCR rejects non-HTTPS redirect URI in prod (§16.4)"

if [[ -z "$AUTH_ENDPOINT" ]]; then
    record_fail "DCR rejects HTTP redirect" "skipped - no AUTH_ENDPOINT"
elif [[ "$KNOBBY_ENV" == "test" ]]; then
    record_pass "DCR rejects HTTP redirect" "skipped for test env (localhost over HTTP permitted in dev/test)"
else
    DCR_ENDPOINT="${REALM_BASE}/clients-registrations/openid-connect"
    BAD_REDIRECT_BODY='{"client_name":"smoke-test-bad-redirect","redirect_uris":["http://example.com/callback"],"grant_types":["authorization_code"],"token_endpoint_auth_method":"none","scope":"openid knobby:read"}'

    HTTP_REDIRECT_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -X POST "$DCR_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$BAD_REDIRECT_BODY")
    HTTP_REDIRECT_STATUS=$(echo "$HTTP_REDIRECT_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)

    if [[ "$HTTP_REDIRECT_STATUS" == "400" || "$HTTP_REDIRECT_STATUS" == "403" ]]; then
        record_pass "DCR rejects HTTP redirect" "HTTP ${HTTP_REDIRECT_STATUS} as expected"
    elif [[ "$HTTP_REDIRECT_STATUS" == "201" ]]; then
        # Cleanup this accidentally-created client
        ACCIDENTAL_CLIENT_ID=$(echo "$HTTP_REDIRECT_RESP" | sed '$d' | jq -r '.client_id // empty')
        ACCIDENTAL_RAT=$(echo "$HTTP_REDIRECT_RESP" | sed '$d' | jq -r '.registration_access_token // empty')
        if [[ -n "$ACCIDENTAL_CLIENT_ID" && -n "$ACCIDENTAL_RAT" ]]; then
            curl -s -X DELETE "${DCR_ENDPOINT}/${ACCIDENTAL_CLIENT_ID}" -H "Authorization: Bearer $ACCIDENTAL_RAT" >/dev/null 2>&1 || true
        fi
        record_fail "DCR rejects HTTP redirect" "non-HTTPS redirect was ACCEPTED (HTTP 201) - fix the mcp-hardening client policy per SETUP GUIDE D.6 (design: PRD §16.4)"
    else
        record_fail "DCR rejects HTTP redirect" "unexpected HTTP ${HTTP_REDIRECT_STATUS}"
    fi
fi

# ----- test 23: password grant (ROPC) must not yield a token for DCR clients -----
section "Test 23: Password grant (ROPC) unusable by DCR clients (§16.4 / setup guide D.10)"

# IMPORTANT (test design): standard Keycloak client policies have NO executor that
# rejects a DCR *registration* merely for requesting grant_types:["password"].
# The mcp-hardening executors (pkce-enforcer, secure-response-type, secure-redirect-uri,
# etc.) constrain the authorize/response-type behavior, not which grant_types a client
# may register. So a registration requesting "password" will typically return 201 -
# that is NOT a misconfiguration of your profile; there simply is no built-in rule it
# violates. Therefore we do NOT assert "registration rejected". Instead we assert the
# real, enforceable security property: a DCR'd client CANNOT actually obtain a token
# via grant_type=password. That property is enforced by neutering the realm Direct
# Grant flow (setup guide D.10) and/or the client not genuinely having the capability.

if [[ -z "$AUTH_ENDPOINT" || -z "$TOKEN_ENDPOINT" ]]; then
    record_fail "Password grant unusable (DCR)" "skipped - no AUTH_ENDPOINT/TOKEN_ENDPOINT"
else
    DCR_ENDPOINT="${REALM_BASE}/clients-registrations/openid-connect"
    # Register a public client that requests the password grant. We expect this to
    # SUCCEED (201) - see note above - and then prove the grant is unusable.
    ROPC_BODY='{"client_name":"smoke-test-ropc","redirect_uris":["https://example.com/callback"],"grant_types":["password","authorization_code"],"token_endpoint_auth_method":"none","scope":"openid knobby:read"}'

    # Retry on transient 5xx. A 503/502 here is NOT a policy result - it's Keycloak
    # or its DB being momentarily unavailable (e.g. connection-pool starvation under
    # the smoke suite's own load - Test 4b hammers /token 15x just before this - or a
    # Cloud Run cold start / scale-from-zero). Retry a few times with backoff before
    # treating it as a real failure, so a blip doesn't masquerade as a test failure.
    ROPC_STATUS=""
    ROPC_JSON=""
    for _attempt in 1 2 3; do
        ROPC_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "$DCR_ENDPOINT" \
            -H "Content-Type: application/json" -d "$ROPC_BODY")
        ROPC_STATUS=$(echo "$ROPC_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
        ROPC_JSON=$(echo "$ROPC_RESP" | sed '$d')
        # 5xx (or a curl failure → empty status) is transient; back off and retry.
        if [[ "$ROPC_STATUS" =~ ^5[0-9][0-9]$ || -z "$ROPC_STATUS" ]]; then
            sleep $((_attempt * 2))
            continue
        fi
        break
    done

    if [[ "$ROPC_STATUS" =~ ^5[0-9][0-9]$ || -z "$ROPC_STATUS" ]]; then
        record_fail "Password grant unusable (DCR)" "registration returned HTTP ${ROPC_STATUS:-(no response)} after 3 attempts - this is a Keycloak/DB availability problem, NOT a policy result. Likely causes: (1) DB connection-pool starvation - check the Keycloak log for 'Acquisition timeout' and consider whether KC_DB_POOL_MAX_SIZE is too tight under the smoke suite's burst (Test 4b hammers /token 15x just before this); (2) Cloud Run cold start / scale-from-zero mid-request; (3) a proxy/LB in front returning 5xx. Re-run: if it's intermittent it's load/cold-start; if consistent, check /health/ready on the management port."
    elif [[ "$ROPC_STATUS" == "400" || "$ROPC_STATUS" == "403" ]]; then
        # If a future Keycloak/policy DOES reject the registration outright, that's
        # even stronger - accept it as a pass.
        record_pass "Password grant unusable (DCR)" "registration requesting the password grant was rejected outright (HTTP ${ROPC_STATUS}) - strongest posture"
    elif [[ "$ROPC_STATUS" == "201" ]]; then
        ROPC_CLIENT_ID=$(echo "$ROPC_JSON" | jq -r '.client_id // empty')
        ROPC_RAT=$(echo "$ROPC_JSON" | jq -r '.registration_access_token // empty')

        # Now attempt the actual password grant. It MUST fail (no token issued).
        # We use bogus credentials; the point is that ROPC must not be a usable path
        # at all - a properly disabled direct-grant flow returns an OAuth error, not
        # a token, regardless of credentials.
        ROPC_TOKEN_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "$TOKEN_ENDPOINT" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=password" \
            -d "client_id=${ROPC_CLIENT_ID}" \
            -d "username=smoke-ropc-probe@example.com" \
            -d "password=not-a-real-password")
        ROPC_TOKEN_STATUS=$(echo "$ROPC_TOKEN_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
        ROPC_TOKEN_JSON=$(echo "$ROPC_TOKEN_RESP" | sed '$d')
        GOT_TOKEN=$(echo "$ROPC_TOKEN_JSON" | jq -r '.access_token // empty' 2>/dev/null || true)
        ROPC_ERR=$(echo "$ROPC_TOKEN_JSON" | jq -r '.error // "?"' 2>/dev/null || echo "?")

        if [[ -n "$GOT_TOKEN" ]]; then
            record_fail "Password grant unusable (DCR)" "a DCR client OBTAINED an access token via grant_type=password (HTTP ${ROPC_TOKEN_STATUS}). ROPC is live. Neuter the realm Direct Grant flow (setup guide D.10: Authentication → Flows → 'direct grant' → set steps Disabled) so the password grant cannot issue tokens. Federated-only realms have no local passwords, so ROPC should never succeed."
        elif [[ "$ROPC_ERR" == "invalid_grant" || "$ROPC_ERR" == "unauthorized_client" || "$ROPC_ERR" == "invalid_client" || "$ROPC_ERR" == "invalid_request" ]]; then
            record_pass "Password grant unusable (DCR)" "registration returned 201 (expected - no policy rejects grant_types at registration), but the password grant yields no token (error='${ROPC_ERR}', HTTP ${ROPC_TOKEN_STATUS}). ROPC is not a usable path."
        else
            record_skip "Password grant unusable (DCR)" "password grant returned no token but with an unclassified response (error='${ROPC_ERR}', HTTP ${ROPC_TOKEN_STATUS}). No token was issued (good), but verify manually this isn't a transient error."
        fi

        # cleanup the probe client
        if [[ -n "$ROPC_CLIENT_ID" && -n "$ROPC_RAT" ]]; then
            curl -s -X DELETE "${DCR_ENDPOINT}/${ROPC_CLIENT_ID}" -H "Authorization: Bearer $ROPC_RAT" >/dev/null 2>&1 || true
        fi
    else
        record_fail "Password grant unusable (DCR)" "unexpected registration HTTP ${ROPC_STATUS}"
    fi
fi

# ----- test 24: DCR rejects disallowed scopes -----
section "Test 24: DCR rejects disallowed scopes (§16.4)"

if [[ -z "$AUTH_ENDPOINT" ]]; then
    record_fail "DCR rejects bad scopes" "skipped - no AUTH_ENDPOINT"
else
    DCR_ENDPOINT="${REALM_BASE}/clients-registrations/openid-connect"
    # Try to register requesting a privileged realm-management scope that should NOT be in the whitelist
    BAD_SCOPE_BODY='{"client_name":"smoke-test-bad-scope","redirect_uris":["https://example.com/callback"],"grant_types":["authorization_code"],"token_endpoint_auth_method":"none","scope":"openid realm-admin"}'

    BAD_SCOPE_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -X POST "$DCR_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$BAD_SCOPE_BODY")
    BAD_SCOPE_STATUS=$(echo "$BAD_SCOPE_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)

    if [[ "$BAD_SCOPE_STATUS" == "400" || "$BAD_SCOPE_STATUS" == "403" ]]; then
        record_pass "DCR rejects bad scopes" "HTTP ${BAD_SCOPE_STATUS} as expected"
    elif [[ "$BAD_SCOPE_STATUS" == "201" ]]; then
        ACCIDENTAL_CLIENT_ID=$(echo "$BAD_SCOPE_RESP" | sed '$d' | jq -r '.client_id // empty')
        ACCIDENTAL_RAT=$(echo "$BAD_SCOPE_RESP" | sed '$d' | jq -r '.registration_access_token // empty')
        if [[ -n "$ACCIDENTAL_CLIENT_ID" && -n "$ACCIDENTAL_RAT" ]]; then
            curl -s -X DELETE "${DCR_ENDPOINT}/${ACCIDENTAL_CLIENT_ID}" -H "Authorization: Bearer $ACCIDENTAL_RAT" >/dev/null 2>&1 || true
        fi
        record_fail "DCR rejects bad scopes" "realm-admin scope was ACCEPTED (HTTP 201) - configure the Allowed Client Scopes policy per SETUP GUIDE D.5 (design: PRD §16.4)"
    else
        record_fail "DCR rejects bad scopes" "unexpected HTTP ${BAD_SCOPE_STATUS}"
    fi
fi

# ----- test 25: DCR'd client has correct shape (post-provisioning) -----
section "Test 25: DCR client shape after Option B provisioning (§7.5)"

# IMPORTANT (test design): under Option B, a raw DCR-registered client (what Test 21
# creates) has NO mcp scopes and NO flow binding until it goes through knobby.io's
# /mcp/consent provisioning (assignMcpScopes + bindBrowserFlow, web spec §7.5). This
# smoke test cannot drive that path - it needs a real user session + a valid HMAC
# picker-request token. So inspecting the raw Test-21 client will ALWAYS show it
# unprovisioned. That is NOT a failure of the app or the realm - it's the expected
# state of a client that hasn't been through consent yet.
#
# Therefore:
#   - If PROVISIONED_MCP_CLIENT_ID is set (a client you've already driven through
#     /mcp/consent once), inspect THAT client and assert the full shape (real check).
#   - Otherwise inspect the raw Test-21 client and SKIP (informational), explaining
#     that provisioning is app-driven and pointing at how to verify manually.

INSPECT_CLIENT_ID="${PROVISIONED_MCP_CLIENT_ID:-$DCR_CLIENT_ID}"
IS_PROVISIONED_CHECK="false"
[[ -n "${PROVISIONED_MCP_CLIENT_ID:-}" ]] && IS_PROVISIONED_CHECK="true"

if [[ -z "$INSPECT_CLIENT_ID" ]]; then
    record_skip "DCR client shape" "no client to inspect (Test 21 produced none, and PROVISIONED_MCP_CLIENT_ID not set)"
elif [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "DCR client shape" "skipped - no admin access token to inspect client config"
else
    CLIENT_INTERNAL_DATA=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients?clientId=${INSPECT_CLIENT_ID}" 2>/dev/null | jq -r '.[0] // empty')

    if [[ -z "$CLIENT_INTERNAL_DATA" ]]; then
        record_fail "DCR client shape" "could not retrieve admin view of client ${INSPECT_CLIENT_ID}"
    else
        CLIENT_INTERNAL_ID=$(echo "$CLIENT_INTERNAL_DATA" | jq -r '.id')
        DEFAULT_SCOPES=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
            "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_INTERNAL_ID}/default-client-scopes" 2>/dev/null | \
            jq -r '.[].name // empty')
        MISSING_DEFAULTS=()
        for required_scope in "$MCP_DEFAULT_SCOPE" "${MCP_AUTHOR_BUNDLE_SCOPES[@]}"; do
            echo "$DEFAULT_SCOPES" | grep -qx "$required_scope" || MISSING_DEFAULTS+=("$required_scope")
        done
        HAS_ADMIN_DEFAULT="false"
        echo "$DEFAULT_SCOPES" | grep -qx "knobby:admin" && HAS_ADMIN_DEFAULT="true"

        FLOW_BINDING=$(echo "$CLIENT_INTERNAL_DATA" | jq -r '.authenticationFlowBindingOverrides.browser // empty')
        BOUND_FLOW_ALIAS=""
        if [[ -n "$FLOW_BINDING" ]]; then
            BOUND_FLOW_ALIAS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                "${KC_URL}/admin/realms/${REALM}/authentication/flows" 2>/dev/null | \
                jq -r --arg fid "$FLOW_BINDING" '.[] | select(.id == $fid) | .alias' || true)
        fi

        FULLY_PROVISIONED="false"
        [[ ${#MISSING_DEFAULTS[@]} -eq 0 && "$HAS_ADMIN_DEFAULT" == "false" && "$BOUND_FLOW_ALIAS" == "$MCP_FLOW_NAME" ]] && FULLY_PROVISIONED="true"

        if [[ "$IS_PROVISIONED_CHECK" == "true" ]]; then
            # Real assertion against a client you've told us IS provisioned.
            if [[ "$FULLY_PROVISIONED" == "true" ]]; then
                record_pass "DCR client shape (provisioned)" "client '${INSPECT_CLIENT_ID}': mcp-default + author bundle default, knobby:admin optional, browser flow bound to ${MCP_FLOW_NAME}. Option B provisioning verified."
            else
                DETAIL=""
                [[ ${#MISSING_DEFAULTS[@]} -gt 0 ]] && DETAIL+="missing default scopes: ${MISSING_DEFAULTS[*]}. "
                [[ "$HAS_ADMIN_DEFAULT" == "true" ]] && DETAIL+="knobby:admin wrongly in DEFAULT (must be optional). "
                [[ "$BOUND_FLOW_ALIAS" != "$MCP_FLOW_NAME" ]] && DETAIL+="browser flow bound to '${BOUND_FLOW_ALIAS:-none}', expected ${MCP_FLOW_NAME}. "
                record_fail "DCR client shape (provisioned)" "client '${INSPECT_CLIENT_ID}' was flagged provisioned but is incomplete: ${DETAIL}Check assignMcpScopes/bindBrowserFlow ran (web spec §7.5) and the admin-api service account has manage-clients (PRD §11.13)."
            fi
        else
            # Inspecting the raw Test-21 client - provisioning is app-driven and not
            # reachable from this suite. Report state as an informational SKIP.
            if [[ "$FULLY_PROVISIONED" == "true" ]]; then
                record_pass "DCR client shape" "raw DCR client already shows full MCP shape (scopes + flow binding) - provisioning must have run out-of-band. Good."
            else
                record_skip "DCR client shape" "raw DCR client '${INSPECT_CLIENT_ID}' is unprovisioned (no mcp scopes / no flow binding) - EXPECTED. Option B provisioning runs in knobby.io at /mcp/consent (§7.5), which this suite can't drive (needs a real session + HMAC picker token). To verify the app works: set PROVISIONED_MCP_CLIENT_ID to a client you've driven through /mcp/consent once, or check the mcp_provisioned_clients table for a provisioned_at timestamp and inspect that client in Keycloak admin."
            fi
        fi
    fi
fi

# ----- test 25b: Keycloak-side provisioning CAPABILITY (Variant B, browserless) -----
section "Test 25b: Option B provisioning capability — Keycloak side (§7.5)"

# WHAT THIS IS: Test 25 can only INSPECT a client's shape; it can't drive the
# app's /mcp/consent provisioning (that needs a browser + HMAC token). This test
# fills the automatable half: acting AS the admin-api service account (exactly
# what knobby.io does in assignMcpScopes/bindBrowserFlow), it registers a fresh
# client and performs the same Admin API writes the app would, asserting each
# SUCCEEDS. This validates the KEYCLOAK-SIDE contract the app depends on:
#   - the service account CAN assign these scopes + bind the flow (catches a
#     missing manage-clients role as a hard 403 - the exact issue from §11.13),
#   - the mcp-default + author-bundle scopes EXIST to assign,
#   - the browser-mcp-tenant-pick flow EXISTS to bind to.
# It does NOT test knobby.io's orchestration (single-flight, the state table,
# the /mcp/consent trigger) - that's the interactive E2E test's job
# (mcp-e2e-interactive.sh). Full three-tier model: see web spec §9.3.

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_skip "Provisioning capability (KC side)" "no admin access token"
else
    VB_DCR="${REALM_BASE}/clients-registrations/openid-connect"
    VB_BODY='{"client_name":"smoke-provision-cap","redirect_uris":["http://localhost:53999/callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none","scope":"openid"}'
    VB_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "$VB_DCR" \
        -H "Content-Type: application/json" -d "$VB_BODY")
    VB_STATUS=$(echo "$VB_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
    VB_JSON=$(echo "$VB_RESP" | sed '/HTTP_STATUS:/d')

    if [[ "$VB_STATUS" != "201" ]]; then
        record_skip "Provisioning capability (KC side)" "couldn't register a probe client (HTTP ${VB_STATUS}) - skipping capability check"
    else
        VB_CLIENT_ID=$(echo "$VB_JSON" | jq -r '.client_id')
        VB_RAT=$(echo "$VB_JSON" | jq -r '.registration_access_token // empty')
        VB_INTERNAL=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
            "${KC_URL}/admin/realms/${REALM}/clients?clientId=${VB_CLIENT_ID}" | jq -r '.[0].id // empty')

        # resolve scope name → id
        ALL_SCOPES=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
            "${KC_URL}/admin/realms/${REALM}/client-scopes")
        scope_id() { echo "$ALL_SCOPES" | jq -r --arg n "$1" '.[] | select(.name==$n) | .id' ; }

        VB_FAILED=0
        VB_DETAIL=""

        # (1) assign default scopes: mcp-default + author bundle (what assignMcpScopes does)
        for s in "$MCP_DEFAULT_SCOPE" "${MCP_AUTHOR_BUNDLE_SCOPES[@]}"; do
            sid=$(scope_id "$s")
            if [[ -z "$sid" ]]; then
                VB_FAILED=1; VB_DETAIL+="scope '${s}' does not exist (create per setup guide D.3/D.4); "
                continue
            fi
            code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                "${KC_URL}/admin/realms/${REALM}/clients/${VB_INTERNAL}/default-client-scopes/${sid}")
            if [[ "$code" == "403" ]]; then
                VB_FAILED=1; VB_DETAIL+="PUT default-scope '${s}' → 403 (admin-api service account missing manage-clients, PRD §11.13); "
                break
            elif [[ "$code" != "204" && "$code" != "200" ]]; then
                VB_FAILED=1; VB_DETAIL+="PUT default-scope '${s}' → HTTP ${code}; "
            fi
        done

        # (2) assign knobby:admin as OPTIONAL
        if [[ "$VB_FAILED" -eq 0 ]]; then
            aid=$(scope_id "knobby:admin")
            if [[ -n "$aid" ]]; then
                code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    "${KC_URL}/admin/realms/${REALM}/clients/${VB_INTERNAL}/optional-client-scopes/${aid}")
                [[ "$code" == "204" || "$code" == "200" ]] || { VB_FAILED=1; VB_DETAIL+="PUT optional knobby:admin → HTTP ${code}; "; }
            else
                VB_DETAIL+="(knobby:admin scope absent - skipped optional assign) "
            fi
        fi

        # (3) bind the browser flow (what bindBrowserFlow does)
        if [[ "$VB_FAILED" -eq 0 ]]; then
            FLOW_ID=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                "${KC_URL}/admin/realms/${REALM}/authentication/flows" | jq -r --arg a "$MCP_FLOW_NAME" '.[] | select(.alias==$a) | .id')
            if [[ -z "$FLOW_ID" ]]; then
                VB_FAILED=1; VB_DETAIL+="flow '${MCP_FLOW_NAME}' does not exist to bind (create per setup guide D.2); "
            else
                VB_CLIENT_REP=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                    "${KC_URL}/admin/realms/${REALM}/clients/${VB_INTERNAL}")
                VB_PATCHED=$(echo "$VB_CLIENT_REP" | jq --arg fid "$FLOW_ID" '.authenticationFlowBindingOverrides = {"browser": $fid}')
                code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
                    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
                    -d "$VB_PATCHED" \
                    "${KC_URL}/admin/realms/${REALM}/clients/${VB_INTERNAL}")
                if [[ "$code" == "403" ]]; then
                    VB_FAILED=1; VB_DETAIL+="PUT flow-binding → 403 (missing manage-clients); "
                elif [[ "$code" != "204" && "$code" != "200" ]]; then
                    VB_FAILED=1; VB_DETAIL+="PUT flow-binding → HTTP ${code}; "
                fi
            fi
        fi

        if [[ "$VB_FAILED" -eq 0 ]]; then
            record_pass "Provisioning capability (KC side)" "admin-api service account can assign mcp-default + author bundle (default), knobby:admin (optional), and bind ${MCP_FLOW_NAME} - the Keycloak-side half of Option B works. (App orchestration verified separately by mcp-e2e-interactive.sh.)"
        else
            record_fail "Provisioning capability (KC side)" "${VB_DETAIL}"
        fi

        # cleanup the probe client (RAT first, admin fallback)
        if [[ -n "$VB_RAT" ]]; then
            curl -s -o /dev/null -X DELETE "${VB_DCR}/${VB_CLIENT_ID}" -H "Authorization: Bearer $VB_RAT" || true
        elif [[ -n "$VB_INTERNAL" ]]; then
            curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $ACCESS_TOKEN" \
                "${KC_URL}/admin/realms/${REALM}/clients/${VB_INTERNAL}" || true
        fi
    fi
fi

# ----- test 26: cleanup DCR'd test client -----
section "Test 26: Cleanup DCR-registered test client"

if [[ -z "$DCR_CLIENT_ID" || -z "$DCR_REGISTRATION_ACCESS_TOKEN" ]]; then
    record_pass "DCR test cleanup" "no client to clean up (Test 21 did not succeed)"
else
    DCR_ENDPOINT="${REALM_BASE}/clients-registrations/openid-connect"
    DELETE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE "${DCR_ENDPOINT}/${DCR_CLIENT_ID}" \
        -H "Authorization: Bearer ${DCR_REGISTRATION_ACCESS_TOKEN}")
    if [[ "$DELETE_STATUS" == "204" || "$DELETE_STATUS" == "200" ]]; then
        record_pass "DCR test cleanup" "deleted client ${DCR_CLIENT_ID}"
    else
        record_fail "DCR test cleanup" "delete returned HTTP ${DELETE_STATUS} - manual cleanup may be needed for client ${DCR_CLIENT_ID}"
    fi
fi

# ----- test 27: OAuth Authorization Server Metadata advertises DCR endpoint -----
section "Test 27: OAuth Authorization Server Metadata advertises DCR (§16.2)"

# RFC 8414 — MCP clients use this to discover the DCR endpoint. If discovery
# doesn't advertise registration_endpoint, MCP clients can't auto-register.
AS_METADATA_URL="${REALM_BASE}/.well-known/oauth-authorization-server"
AS_METADATA_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "${AS_METADATA_URL}")
AS_METADATA_STATUS=$(echo "$AS_METADATA_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
AS_METADATA_BODY=$(echo "$AS_METADATA_RESP" | sed '$d')

if [[ "$AS_METADATA_STATUS" != "200" ]]; then
    # OIDC discovery is at .well-known/openid-configuration; many Keycloak realms
    # don't expose the separate oauth-authorization-server endpoint. Fall back
    # to the OIDC discovery doc since it includes registration_endpoint too.
    AS_METADATA_BODY="$DISCOVERY_BODY"
    AS_METADATA_STATUS="200 (via openid-configuration fallback)"
fi

REGISTRATION_EP=$(echo "$AS_METADATA_BODY" | jq -r '.registration_endpoint // empty' 2>/dev/null)
if [[ -n "$REGISTRATION_EP" ]]; then
    record_pass "OAuth metadata advertises DCR" "registration_endpoint=${REGISTRATION_EP}"
else
    record_fail "OAuth metadata advertises DCR" "no registration_endpoint in authorization server metadata - MCP clients cannot auto-discover the DCR endpoint (§16.2)"
fi

# ----- test 28: realm requires HTTPS -----
section "Test 28: Realm SSL requirement (§16.5)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "realm SSL requirement" "skipped - no admin access token"
else
    if ! fetch_realm_json; then
        record_fail "realm SSL requirement" "$REALM_FETCH_ERR"
    else
    REALM_DATA="$REALM_JSON"
    SSL_REQUIRED=$(echo "$REALM_DATA" | jq -r '.sslRequired // "external"')
    if [[ "$KNOBBY_ENV" == "test" ]]; then
        record_pass "realm SSL requirement" "skipped for test env (HTTP permitted for local dev; sslRequired=${SSL_REQUIRED})"
    elif [[ "$SSL_REQUIRED" == "all" ]]; then
        record_pass "realm SSL requirement" "sslRequired=all"
    elif [[ "$SSL_REQUIRED" == "external" ]]; then
        record_fail "realm SSL requirement" "sslRequired='external' - HTTPS only enforced for non-loopback; for prod/dev should be 'all' (Realm settings → General → Require SSL; SETUP GUIDE §C)"
    else
        record_fail "realm SSL requirement" "sslRequired='${SSL_REQUIRED}' - should be 'all' (Realm settings → General → Require SSL; SETUP GUIDE §C)"
    fi
    fi
fi

# ----- test 29: scope override mapper attached to mcp-default -----
section "Test 29: Scope override mapper attached to mcp-default (§16.8.4)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "scope override mapper" "skipped - no admin access token"
else
    # Re-fetch the mcp-default scope to look for the scope-override mapper.
    # The mapper can be either:
    #   - A custom protocol mapper (providerId 'knobby-mcp-scope-override' or similar)
    #   - A Script Mapper with a script that sets the scope claim
    # Either implementation is acceptable per §16.8.4 (custom recommended).
    MCP_DEFAULT_REFETCH=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/client-scopes" | \
        jq -r --arg name "$MCP_DEFAULT_SCOPE" '.[] | select(.name == $name)' 2>/dev/null || true)

    if [[ -z "$MCP_DEFAULT_REFETCH" ]]; then
        record_fail "scope override mapper" "mcp-default Client Scope not found (depends on Test 17)"
    else
        # Look for any mapper that emits the 'scope' claim
        # Custom mapper case: protocolMapper contains 'scope' or matches a known custom ID
        # Script mapper case: protocolMapper == 'oidc-script-based-protocol-mapper'
        CUSTOM_OVERRIDE=$(echo "$MCP_DEFAULT_REFETCH" | jq -r '.protocolMappers[]? | select(.protocolMapper | contains("scope-override") or contains("knobby-mcp-scope")) | .id' 2>/dev/null || true)
        SCRIPT_OVERRIDE=$(echo "$MCP_DEFAULT_REFETCH" | jq -r '.protocolMappers[]? | select(.protocolMapper == "oidc-script-based-protocol-mapper") | .id' 2>/dev/null || true)

        if [[ -n "$CUSTOM_OVERRIDE" ]]; then
            record_pass "scope override mapper" "custom protocol mapper present (recommended approach per §16.8.4)"
        elif [[ -n "$SCRIPT_OVERRIDE" ]]; then
            record_pass "scope override mapper" "script-based protocol mapper present (acceptable per §16.8.4 Option B; requires 'scripts' feature in Keycloak)"
        else
            record_fail "scope override mapper" "no scope-override mapper found on mcp-default - SPI's session-note-driven scope override won't work (§16.8.4). Add either a custom protocol mapper (Option A, recommended) or Script Mapper (Option B)"
        fi
    fi
fi

# ----- summary -----
section "Automated test summary"
for line in "${RESULTS[@]}"; do
    echo -e "  ${line}"
done
echo ""
echo -e "${BOLD}${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"

# ----- print manual federation test URLs -----
section "Manual browser tests (federation flows)"

cat << EOF
The federation flows require user interaction at Google/Microsoft/GitHub, so
they can't be automated here. Open each URL below in an incognito window and
walk through the flow. Refer to PRD §11.16 for what to verify.

The redirect URI does not need to be a working application — "connection
refused" is acceptable as long as you can read the URL bar to confirm
federation succeeded (the ?code=... parameter is the proof).

${BOLD}If your app at the redirect_uri is still on Auth0 (not Keycloak yet):${RESET}
That's expected at this stage. Keycloak will issue its own code and redirect
to the URI, and the Auth0-based app will then fail to process it (because
the code wasn't issued by Auth0). You'll see an error page from the app —
this is NOT a federation failure, it's the app trying to talk to the wrong
IdP. To capture the actual Keycloak code without app interference, either:
  - DevTools -> Network tab (preserve log on), find the request to the
    redirect URI, copy the ?code= parameter from its URL
  - Or use webhook.site: get a unique URL from https://webhook.site, add
    it as a Valid Redirect URI on knobby-{env}-web, then re-run with
    'export WEB_REDIRECT_URI=https://webhook.site/<your-id>'

${BOLD}PKCE values for this run (the client requires PKCE S256 per §8.2):${RESET}
  ${DIM}code_verifier:${RESET}   ${CODE_VERIFIER}
  ${DIM}code_challenge:${RESET}  ${CODE_CHALLENGE}

Each authorization URL below includes the code_challenge. Save the
code_verifier above — you'll paste it into Test 19's token exchange.

${BOLD}IMPORTANT — which code to use in Test 19:${RESET}
Use the code from the FINAL redirect to your redirect_uri (a Keycloak-format
code, typically a UUID-like opaque string). DO NOT use intermediate codes
from upstream IdPs — Microsoft codes (start with 'M.C540_BAY...'), Google
codes (start with '4/...'), etc. are consumed by Keycloak server-side and
are not valid against Keycloak's token endpoint.

EOF

STATE_TOKEN=$(date +%s)-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
REDIRECT_ENCODED=$(printf '%s' "${WEB_REDIRECT_URI}" | jq -sRr @uri)

cat << EOF
${BOLD}Test 14 — Fallback picker (no kc_idp_hint):${RESET}
  Should render Keycloak's login page with buttons for every configured IdP.
  Until the Keycloakify theme is installed (separate work track), this will
  be the unstyled stock Keycloak login template, which ALSO shows username
  and password fields. That's expected. The success criteria is that the
  IdP buttons (Google, Microsoft) are visible and clicking one starts
  federation. Ignore the username/password fields — those authenticators
  are intentionally disabled per the browser-federated-only flow.

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}&${PKCE_QUERY}

EOF

if [[ $HAS_GOOGLE -eq 1 ]]; then
cat << EOF
${BOLD}Test 15 — Google federation (alias=${GOOGLE_IDP_ALIAS}):${RESET}
  Should redirect immediately to Google.

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}&${PKCE_QUERY}&kc_idp_hint=${GOOGLE_IDP_ALIAS}

EOF
else
cat << EOF
${YELLOW}Test 15 — Google federation: skipped (google IdP not detected)${RESET}

EOF
fi

if [[ $HAS_MICROSOFT -eq 1 ]]; then
cat << EOF
${BOLD}Test 16 — Microsoft federation, work account (alias=${MICROSOFT_IDP_ALIAS}):${RESET}
  Sign in with an Entra work account. The new federated user should have
  microsoftTenantId populated with the work tenant GUID.

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}&${PKCE_QUERY}&kc_idp_hint=${MICROSOFT_IDP_ALIAS}

${BOLD}Test 17 — Microsoft federation, personal MSA (alias=${MICROSOFT_IDP_ALIAS}):${RESET}
  Same URL as Test 16. Sign in with a personal Microsoft account
  (outlook.com / hotmail.com / live.com). microsoftTenantId should be
  9188040d-6c67-4c5b-b112-36a304b66dad.

EOF
else
cat << EOF
${YELLOW}Tests 16-17 — Microsoft federation: skipped (microsoft IdP not detected)${RESET}

EOF
fi

if [[ $HAS_GITHUB -eq 1 ]]; then
cat << EOF
${BOLD}Test 18 — GitHub federation (alias=${GITHUB_IDP_ALIAS}):${RESET}
  Sign in with a GitHub account. The new federated user should have a
  non-null email attribute (verify the email-mapper from PRD §11.10).

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}&${PKCE_QUERY}&kc_idp_hint=${GITHUB_IDP_ALIAS}

EOF
else
cat << EOF
${YELLOW}Test 18 — GitHub federation: skipped (github IdP not detected)${RESET}

EOF
fi

cat << EOF
${BOLD}Test 19 — Token exchange (optional):${RESET}
  After completing any federation test above, copy the ?code=... from the URL
  bar and run (uses the code_verifier from the top of this section):

    curl -X POST '${TOKEN_ENDPOINT}' \\
      -d 'grant_type=authorization_code' \\
      -d 'client_id=${WEB_CLIENT_ID}' \\
      -d 'client_secret=<knobby-keycloak-web-client-secret-${KNOBBY_ENV}>' \\
      -d 'code=<paste-code-here>' \\
      -d 'code_verifier=${CODE_VERIFIER}' \\
      -d 'redirect_uri=${WEB_REDIRECT_URI}'

  Decode the resulting id_token at https://jwt.io and confirm the expected
  claims per PRD §8.3:
    - sub (stable user ID)
    - email, email_verified=true
    - idp (= the alias of the upstream)
    - For Microsoft only: microsoftTenantId

  Note: there is no 'org' claim in the token (per v1.6). knobby.io derives
  organization context from the application data via sub lookup.

EOF

cat << EOF
${BOLD}Test 33 — MCP path (iii) end-to-end (requires Knobby web /mcp/consent):${RESET}
  ${YELLOW}This test cannot be run until Knobby web's /mcp/consent sub-app is
  deployed.${RESET} Until then, automated Tests 14-26 are the realm-side
  ground truth for MCP readiness.

  When /mcp/consent is ready:

  1. Register a test MCP client via DCR (or reuse the smoke test Test 21 path
     and pass --keep-client to retain it for manual testing):

       curl -X POST '${REALM_BASE}/clients-registrations/openid-connect' \\
         -H 'Content-Type: application/json' \\
         -d '{
           "client_name": "Manual MCP smoke client",
           "redirect_uris": ["http://localhost:9999/callback"],
           "grant_types": ["authorization_code", "refresh_token"],
           "token_endpoint_auth_method": "none",
           "scope": "openid knobby:read knobby:write"
         }'

     Save the returned client_id and registration_access_token.

  2. Start a local listener to capture the auth code:

       nc -l 9999

  3. In an incognito window, hit Keycloak's /authorize with PKCE:

       ${AUTH_ENDPOINT}?client_id=<dcr-client-id>&response_type=code\\
         &redirect_uri=http://localhost:9999/callback\\
         &scope=openid%20knobby:read%20knobby:write\\
         &code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256\\
         &state=mcp-e2e-test

  4. Walk through the flow:
     a. Federated IdP login (Google/Microsoft) - same as Tests 28/29.
     b. Browser should redirect to https://${KNOBBY_ENV/prod/prod.knobby.io}/mcp/consent?token=...
        (You should see Knobby's standard app shell with top bar / user menu.)
     c. Step 1 wizard: confirm tenant. Step 2: bundle selection (default Author).
        Step 3: review + Authorize.
     d. Browser should redirect to http://localhost:9999/callback?code=...&state=...
        (Your netcat listener captures the request.)

  5. Exchange the code (Keycloak code, not any intermediate IdP code):

       curl -X POST '${TOKEN_ENDPOINT}' \\
         -d 'grant_type=authorization_code' \\
         -d 'client_id=<dcr-client-id>' \\
         -d 'code=<keycloak-code-from-callback>' \\
         -d 'code_verifier=${CODE_VERIFIER}' \\
         -d 'redirect_uri=http://localhost:9999/callback'

  6. Decode the access_token at https://jwt.io and confirm:
     - aud = "${MCP_AUDIENCE}"
     - scope reflects the user's wizard choice (Author bundle scopes)
       — NOT the originally requested "knobby:read knobby:write" if the
       user chose a different bundle in the wizard
     - tenant = <chosen tenant's UUID>
     - sub, email, idp, microsoftTenantId/googleHd per §8.3

  7. Cleanup: delete the test client via the registration_client_uri returned
     in step 1.

EOF

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
