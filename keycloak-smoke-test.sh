#!/usr/bin/env bash
#
# keycloak-smoke-test.sh (v1.5)
#
# Verifies a fresh Keycloak realm setup against the PRD (§11.18 verification
# checklist), without requiring any yourapp.com application integration.
#
# Convention-based: setting YOURAPP_ENV={prod|dev|test} derives all realm,
# client, and hostname defaults per PRD §10.8. Override any individual value
# by exporting the explicit variable.
#
# Performs server-side automated checks (tests 1-8) and prints URLs for
# manual browser-driven federation tests (tests 9-14: fallback picker, Google,
# Microsoft work, Microsoft personal MSA, GitHub, token exchange).
#
# Requirements: curl, jq.
#
# Usage examples:
#
#   # Prod (secret from GCP Secrets Manager):
#   export YOURAPP_ENV=prod
#   export ADMIN_CLIENT_SECRET=$(gcloud secrets versions access latest \
#       --secret=yourapp-keycloak-admin-api-client-secret-prod)
#   ./keycloak-smoke-test.sh
#
#   # Test (local Docker Compose Keycloak):
#   export YOURAPP_ENV=test
#   export ADMIN_CLIENT_SECRET="$YOURAPP_KEYCLOAK_ADMIN_API_CLIENT_SECRET_TEST"
#   ./keycloak-smoke-test.sh
#
# Exit codes:
#   0 = all automated checks passed
#   1 = at least one check failed
#   2 = required environment variable missing or invalid

set -u

# ----- color output -----
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

# ----- validate YOURAPP_ENV -----
if [[ -z "${YOURAPP_ENV:-}" ]]; then
    echo -e "${RED}ERROR: YOURAPP_ENV is not set${RESET}" >&2
    echo "Set YOURAPP_ENV to one of: prod, dev, test" >&2
    exit 2
fi

case "$YOURAPP_ENV" in
    prod|dev|test)
        ;;
    *)
        echo -e "${RED}ERROR: YOURAPP_ENV must be one of: prod, dev, test (got '${YOURAPP_ENV}')${RESET}" >&2
        exit 2
        ;;
esac

# ----- derive convention-based defaults (per PRD §10.8) -----
if [[ "$YOURAPP_ENV" == "test" ]]; then
    DEFAULT_KC_URL="http://localhost:8080"
    DEFAULT_WEB_REDIRECT_URI="http://localhost:3000/auth/callback"
else
    DEFAULT_KC_URL="https://auth.yourapp.com"
    DEFAULT_WEB_REDIRECT_URI="https://yourapp.com/auth/callback"
fi

KC_URL="${KC_URL:-$DEFAULT_KC_URL}"
REALM="${REALM:-yourapp-${YOURAPP_ENV}}"
ADMIN_CLIENT_ID="${ADMIN_CLIENT_ID:-yourapp-${YOURAPP_ENV}-admin-api}"
WEB_CLIENT_ID="${WEB_CLIENT_ID:-yourapp-${YOURAPP_ENV}-web}"
WEB_REDIRECT_URI="${WEB_REDIRECT_URI:-$DEFAULT_WEB_REDIRECT_URI}"

KC_URL="${KC_URL%/}"

# ----- validate ADMIN_CLIENT_SECRET -----
if [[ -z "${ADMIN_CLIENT_SECRET:-}" ]]; then
    echo -e "${RED}ERROR: ADMIN_CLIENT_SECRET is not set${RESET}" >&2
    echo "" >&2
    echo "Expected secret name in GCP Secrets Manager (per PRD §10.8):" >&2
    echo "  yourapp-keycloak-admin-api-client-secret-${YOURAPP_ENV}" >&2
    echo "" >&2
    echo "For prod/dev, fetch with:" >&2
    echo "  export ADMIN_CLIENT_SECRET=\$(gcloud secrets versions access latest \\" >&2
    echo "      --secret=yourapp-keycloak-admin-api-client-secret-${YOURAPP_ENV})" >&2
    echo "" >&2
    echo "For test, source from your developer-local .env file." >&2
    exit 2
fi

# ----- check required tools -----
for tool in curl jq; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: required tool '$tool' is not installed${RESET}" >&2
        exit 2
    fi
done

REALM_BASE="${KC_URL}/realms/${REALM}"

# ----- print resolved configuration -----
echo -e "${BOLD}${BLUE}Keycloak smoke test — resolved configuration${RESET}"
echo -e "  ${DIM}YOURAPP_ENV:${RESET}          ${YOURAPP_ENV}"
echo -e "  ${DIM}KC_URL:${RESET}              ${KC_URL}"
echo -e "  ${DIM}REALM:${RESET}               ${REALM}"
echo -e "  ${DIM}ADMIN_CLIENT_ID:${RESET}     ${ADMIN_CLIENT_ID}"
echo -e "  ${DIM}WEB_CLIENT_ID:${RESET}       ${WEB_CLIENT_ID}"
echo -e "  ${DIM}WEB_REDIRECT_URI:${RESET}    ${WEB_REDIRECT_URI}"
echo -e "  ${DIM}ADMIN_CLIENT_SECRET:${RESET} ${ADMIN_CLIENT_SECRET:0:6}... (truncated)"

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

section()
{
    echo ""
    echo -e "${BOLD}${BLUE}=== $1 ===${RESET}"
}

# ----- test 1: OIDC discovery endpoint -----
section "Test 1: OIDC discovery endpoint (realm liveness)"

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
    200)
        record_fail "Account console disabled" "HTTP 200 - account console is still accessible (see PRD §11.14)"
        ;;
    404|403|400)
        record_pass "Account console disabled" "HTTP ${ACCOUNT_STATUS}"
        ;;
    302)
        record_pass "Account console disabled" "HTTP 302 (redirect; likely error page - verify manually)"
        ;;
    *)
        record_fail "Account console disabled" "HTTP ${ACCOUNT_STATUS} - unexpected status, investigate"
        ;;
esac

# ----- test 3: Account console v2 endpoint disabled -----
section "Test 3: Account console v2 endpoint disabled"

ACCOUNT_V2_URL="${REALM_BASE}/account/"
echo "GET ${ACCOUNT_V2_URL}"

ACCOUNT_V2_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${ACCOUNT_V2_URL}")
case "$ACCOUNT_V2_STATUS" in
    200)
        record_fail "Account console v2 disabled" "HTTP 200 - check that both 'account' and 'account-console' clients are disabled"
        ;;
    *)
        record_pass "Account console v2 disabled" "HTTP ${ACCOUNT_V2_STATUS}"
        ;;
esac

# ----- test 4: Admin API token acquisition -----
section "Test 4: Admin API client credentials grant"

echo "POST ${TOKEN_ENDPOINT}"
echo "  grant_type=client_credentials"
echo "  client_id=${ADMIN_CLIENT_ID}"

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
    record_fail "Admin API token grant" "HTTP ${TOKEN_STATUS}: ${ERROR} - ${ERROR_DESC}"
else
    ACCESS_TOKEN=$(echo "$TOKEN_BODY" | jq -r '.access_token')
    if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
        record_fail "Admin API token grant" "200 OK but no access_token in response"
    else
        JWT_PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
        PADDED=$(printf '%s' "$JWT_PAYLOAD" | awk '{n=length($0)%4; if (n) printf "%s%s", $0, substr("===",1,4-n); else print $0}')
        BASE64=$(printf '%s' "$PADDED" | tr '_-' '/+')
        DECODED=$(echo "$BASE64" | base64 -d 2>/dev/null || true)
        EXP=$(echo "$DECODED" | jq -r '.exp // empty' 2>/dev/null)
        AUD=$(echo "$DECODED" | jq -r '.aud // empty' 2>/dev/null)
        record_pass "Admin API token grant" "access_token acquired (aud=${AUD}, exp=${EXP})"
    fi
fi

# ----- test 5: Admin API user list -----
section "Test 5: Admin API - list users (validates realm-management roles)"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Admin API users list" "skipped - no access token from test 4"
else
    USERS_URL="${KC_URL}/admin/realms/${REALM}/users?max=5"
    echo "GET ${USERS_URL}"

    USERS_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${USERS_URL}")

    USERS_STATUS=$(echo "$USERS_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    USERS_BODY=$(echo "$USERS_RESPONSE" | sed '/HTTP_STATUS:/d')

    if [[ "$USERS_STATUS" == "200" ]]; then
        USER_COUNT=$(echo "$USERS_BODY" | jq -r 'length' 2>/dev/null)
        record_pass "Admin API users list" "HTTP 200, ${USER_COUNT} user(s) returned"
    elif [[ "$USERS_STATUS" == "403" ]]; then
        record_fail "Admin API users list" "HTTP 403 - service account missing realm-management client roles (see PRD §11.15 step 2: 'Filter by clients')"
    else
        record_fail "Admin API users list" "HTTP ${USERS_STATUS}"
    fi
fi

# ----- test 6: Admin API identity providers list -----
section "Test 6: Admin API - list configured Identity Providers"

# Track which IdPs are configured (for the manual-test URL output later).
HAS_GOOGLE=0
HAS_MICROSOFT=0
HAS_GITHUB=0

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Admin API IdPs list" "skipped - no access token"
else
    IDP_URL="${KC_URL}/admin/realms/${REALM}/identity-provider/instances"
    echo "GET ${IDP_URL}"

    IDP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${IDP_URL}")

    IDP_STATUS=$(echo "$IDP_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    IDP_BODY=$(echo "$IDP_RESPONSE" | sed '/HTTP_STATUS:/d')

    if [[ "$IDP_STATUS" == "200" ]]; then
        IDP_ALIASES=$(echo "$IDP_BODY" | jq -r '.[].alias' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        record_pass "Admin API IdPs list" "configured IdPs: ${IDP_ALIASES:-(none)}"

        for ALIAS in $(echo "$IDP_BODY" | jq -r '.[].alias' 2>/dev/null); do
            case "$ALIAS" in
                google) HAS_GOOGLE=1 ;;
                microsoft) HAS_MICROSOFT=1 ;;
                github) HAS_GITHUB=1 ;;
            esac

            FLOW=$(echo "$IDP_BODY" | jq -r ".[] | select(.alias == \"${ALIAS}\") | .firstBrokerLoginFlowAlias")
            if [[ "$FLOW" == "first-broker-login-no-prompt" ]]; then
                record_pass "IdP '${ALIAS}' First Login Flow" "${FLOW}"
            else
                record_fail "IdP '${ALIAS}' First Login Flow" "is '${FLOW}', expected 'first-broker-login-no-prompt' (see PRD §6.1)"
            fi
        done
    else
        record_fail "Admin API IdPs list" "HTTP ${IDP_STATUS}"
    fi
fi

# ----- test 7: Browser flow binding -----
section "Test 7: Browser flow binding"

if [[ -z "$ACCESS_TOKEN" ]]; then
    record_fail "Browser flow binding" "skipped - no access token"
else
    REALM_INFO_URL="${KC_URL}/admin/realms/${REALM}"
    REALM_INFO=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" "${REALM_INFO_URL}")
    BROWSER_FLOW=$(echo "$REALM_INFO" | jq -r '.browserFlow // empty')

    if [[ "$BROWSER_FLOW" == "browser-federated-only" ]]; then
        record_pass "Browser flow binding" "browserFlow=${BROWSER_FLOW}"
    elif [[ -z "$BROWSER_FLOW" ]]; then
        record_fail "Browser flow binding" "could not read realm browserFlow attribute"
    else
        record_fail "Browser flow binding" "browserFlow=${BROWSER_FLOW}, expected 'browser-federated-only' (see PRD §11.8)"
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
        record_pass "Required Actions" "no actions set as Default (correct per PRD §11.9)"
    else
        record_fail "Required Actions" "these are set as Default: ${DEFAULTED} - should be Off per PRD §11.9"
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
The federation flows require user interaction at Google/Microsoft/GitHub,
so they can't be automated here. Open each URL below in an incognito window
and walk through the flow. Refer to PRD §11.18 for what to verify.

The redirect URI does not need to be a working application — "connection
refused" is acceptable as long as you can read the URL bar to confirm
federation succeeded (the ?code=... parameter is the proof).

EOF

STATE_TOKEN=$(date +%s)-$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
REDIRECT_ENCODED=$(printf '%s' "${WEB_REDIRECT_URI}" | jq -sRr @uri)

cat << EOF
${BOLD}Test 9 — Fallback picker (no kc_idp_hint):${RESET}
  Should render the themed login page (per KEYCLOAK_THEMING_GUIDE.md) with
  buttons for every configured IdP.

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}

EOF

if [[ $HAS_GOOGLE -eq 1 ]]; then
cat << EOF
${BOLD}Test 10 — Google federation:${RESET}
  Should redirect immediately to Google. After sign-in, lands at redirect URI
  with ?code=... .

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}&kc_idp_hint=google

EOF
else
cat << EOF
${YELLOW}Test 10 — Google federation: skipped (google IdP not configured)${RESET}

EOF
fi

if [[ $HAS_MICROSOFT -eq 1 ]]; then
cat << EOF
${BOLD}Test 11 — Microsoft federation (work account):${RESET}
  Should redirect immediately to Microsoft. Sign in with an Entra work
  account. After sign-in, lands at redirect URI with ?code=... . In Keycloak
  Admin -> Users, the new federated user should have microsoftTenantId
  populated with the work tenant GUID.

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}&kc_idp_hint=microsoft

${BOLD}Test 12 — Microsoft federation (personal MSA):${RESET}
  Same URL as Test 11. Sign in with a personal Microsoft account
  (outlook.com / hotmail.com / live.com). After sign-in, the new federated
  user should have microsoftTenantId = 9188040d-6c67-4c5b-b112-36a304b66dad.

EOF
else
cat << EOF
${YELLOW}Tests 11-12 — Microsoft federation: skipped (microsoft IdP not configured)${RESET}

EOF
fi

if [[ $HAS_GITHUB -eq 1 ]]; then
cat << EOF
${BOLD}Test 13 — GitHub federation:${RESET}
  Should redirect immediately to GitHub. After sign-in, lands at redirect URI
  with ?code=... . In Keycloak Admin -> Users, the new federated user should
  have a non-null email attribute (verify the email-mapper from PRD §11.12).

  ${AUTH_ENDPOINT}?client_id=${WEB_CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_ENCODED}&scope=openid&state=${STATE_TOKEN}&kc_idp_hint=github

EOF
else
cat << EOF
${YELLOW}Test 13 — GitHub federation: skipped (github IdP not configured)${RESET}

EOF
fi

cat << EOF
${BOLD}Test 14 — Token exchange (optional):${RESET}
  After completing any federation test above, copy the ?code=... from the URL
  and run:

    curl -X POST '${TOKEN_ENDPOINT}' \\
      -d 'grant_type=authorization_code' \\
      -d 'client_id=${WEB_CLIENT_ID}' \\
      -d 'client_secret=<yourapp-keycloak-web-client-secret-${YOURAPP_ENV}>' \\
      -d 'code=<paste-code-here>' \\
      -d 'redirect_uri=${WEB_REDIRECT_URI}'

  The web client secret is in GCP Secrets Manager under
  yourapp-keycloak-web-client-secret-${YOURAPP_ENV} (per PRD §10.8), or for
  test, in your developer-local .env file.

  Decode the resulting id_token at https://jwt.io and confirm the expected
  claims per PRD §8.3:
    - sub (stable user ID)
    - email, email_verified=true
    - idp (= google / microsoft / github)
    - org (organization membership)
    - For Microsoft only: microsoftTenantId

EOF

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
