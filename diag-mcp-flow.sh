#!/usr/bin/env bash
#
# diag-mcp-flow.sh — Diagnose why the MCP tenant-picker step isn't firing.
#
# Symptom being diagnosed: a DCR'd MCP client logs in via the IdP (Google),
# Keycloak shows its BUILT-IN OAUTH_GRANT consent, issues a token — and the SPI
# never redirects to the app's /mcp/consent. Server log shows the CRP marked the
# client (attribute + scopes + browser flow) but NO "Emitting MCP picker request"
# line, i.e. McpTenantPickerAuthenticator.authenticate() never executed.
#
# This script reads (never mutates) the realm's authentication config and prints
# the two facts that pinpoint the cause:
#   1. The realm's DEFAULT browser flow  (what a broker round-trip resumes on if
#      a per-client override is dropped).
#   2. The browser-mcp-tenant-pick flow's execution tree with requirements
#      (is "Knobby MCP Tenant Picker" REQUIRED and at the top level, after the
#      Authentication sub-flow — per setup guide D.2?).
#
# Usage:
#   KNOBBY_ENV=prod ADMIN_CLIENT_SECRET=xxxxx ./diag-mcp-flow.sh
#
set -uo pipefail

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
    YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi
die() { echo -e "${RED}FATAL:${RESET} $1" >&2; exit 1; }

KNOBBY_ENV="${KNOBBY_ENV:-}"
[[ -z "$KNOBBY_ENV" ]] && die "Set KNOBBY_ENV (prod|dev|test)."
case "$KNOBBY_ENV" in
    prod|dev) DEFAULT_KC_URL="https://auth.knobby.io" ;;
    test)     DEFAULT_KC_URL="http://localhost:8080" ;;
    *)        die "Unknown KNOBBY_ENV '$KNOBBY_ENV'." ;;
esac
KC_URL="${KC_URL:-$DEFAULT_KC_URL}"; KC_URL="${KC_URL%/}"
REALM="${REALM:-knobby-${KNOBBY_ENV}}"
ADMIN_CLIENT_ID="${ADMIN_CLIENT_ID:-knobby-${KNOBBY_ENV}-admin-api}"
ADMIN_CLIENT_SECRET="${ADMIN_CLIENT_SECRET:-}"
MCP_FLOW="${MCP_FLOW_NAME:-browser-mcp-tenant-pick}"
[[ -z "$ADMIN_CLIENT_SECRET" ]] && die "Set ADMIN_CLIENT_SECRET."
for bin in curl jq; do command -v "$bin" >/dev/null 2>&1 || die "'$bin' required."; done

TOKEN_ENDPOINT="${KC_URL}/realms/${REALM}/protocol/openid-connect/token"
ADMIN_TOKEN=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${ADMIN_CLIENT_ID}" \
    -d "client_secret=${ADMIN_CLIENT_SECRET}" | jq -r '.access_token // empty')
[[ -z "$ADMIN_TOKEN" ]] && die "Could not obtain admin token — check ADMIN_CLIENT_SECRET."
api() { curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "${KC_URL}/admin/realms/${REALM}$1"; }

echo -e "${BOLD}MCP flow diagnostic — realm ${REALM} @ ${KC_URL}${RESET}"

# 1. Realm-level default flow bindings.
echo -e "\n${BOLD}${BLUE}▶ 1. Realm default flow bindings${RESET}"
REALM_JSON=$(api "")
BROWSER_FLOW=$(echo "$REALM_JSON" | jq -r '.browserFlow // "?"')
FBL_FLOW=$(echo "$REALM_JSON" | jq -r '.firstBrokerLoginFlow // "?"')
POST_BL=$(echo "$REALM_JSON" | jq -r '.postBrokerLoginFlow // "(none)"')
echo -e "  realm default browserFlow      : ${BOLD}${BROWSER_FLOW}${RESET}"
echo -e "  firstBrokerLoginFlow           : ${FBL_FLOW}"
echo -e "  postBrokerLoginFlow            : ${POST_BL}"
if [[ "$BROWSER_FLOW" == "$MCP_FLOW" ]]; then
    echo -e "  ${GREEN}→ realm default IS ${MCP_FLOW} (Option A / realm-wide).${RESET}"
    echo -e "    ${DIM}The picker should run for every login; short-circuit passes non-MCP clients.${RESET}"
else
    echo -e "  ${YELLOW}→ realm default is '${BROWSER_FLOW}', NOT ${MCP_FLOW} (Option B / per-client override).${RESET}"
    echo -e "    ${DIM}If a per-client override is dropped after the IdP/broker round-trip, the${RESET}"
    echo -e "    ${DIM}resume runs THIS flow ('${BROWSER_FLOW}') — which has no picker. Prime suspect.${RESET}"
fi

# 2. The MCP flow's execution tree.
echo -e "\n${BOLD}${BLUE}▶ 2. '${MCP_FLOW}' execution tree${RESET}"
EXEC=$(api "/authentication/flows/${MCP_FLOW}/executions")
if echo "$EXEC" | jq -e 'type=="object" and .error' >/dev/null 2>&1; then
    echo -e "  ${RED}Flow '${MCP_FLOW}' not found: $(echo "$EXEC" | jq -r '.error')${RESET}"
else
    echo "$EXEC" | jq -r '.[] | "  \(("    " * (.level // 0)))\(.displayName)  [\(.requirement)]\(if .authenticationFlow then "  (sub-flow)" else "" end)"'
    PICKER_REQ=$(echo "$EXEC" | jq -r '.[] | select(.displayName | test("Tenant Picker"; "i")) | .requirement // empty' | head -1)
    PICKER_LEVEL=$(echo "$EXEC" | jq -r '.[] | select(.displayName | test("Tenant Picker"; "i")) | .level // empty' | head -1)
    echo ""
    if [[ -z "$PICKER_REQ" ]]; then
        echo -e "  ${RED}✗ No 'Knobby MCP Tenant Picker' execution in this flow — that's the bug.${RESET}"
    elif [[ "$PICKER_REQ" == "REQUIRED" && "${PICKER_LEVEL:-0}" == "0" ]]; then
        echo -e "  ${GREEN}✓ Picker is REQUIRED at top level (level 0) — structurally correct per D.2.${RESET}"
        echo -e "    ${DIM}If it still isn't firing, the flow isn't the one resuming after the broker${RESET}"
        echo -e "    ${DIM}round-trip → see finding #1 (per-client override vs realm default).${RESET}"
    else
        echo -e "  ${RED}✗ Picker requirement='${PICKER_REQ}' level=${PICKER_LEVEL} — expected REQUIRED at level 0.${RESET}"
        echo -e "    ${DIM}An ALTERNATIVE picker is skipped once an earlier auth alternative succeeds.${RESET}"
    fi
fi

echo -e "\n${DIM}Read-only: this script mutates nothing. Share the output to pinpoint the fix.${RESET}"
