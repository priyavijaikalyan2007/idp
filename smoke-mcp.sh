#!/usr/bin/env bash
#
# mcp-e2e-interactive.sh — Human-in-the-loop end-to-end validation of the full
# MCP consent + provisioning + token-issuance flow for yourapp.com.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THIS IS (and why it's separate from smoke.sh)
# ─────────────────────────────────────────────────────────────────────────────
# The automated smoke suite (keycloak-smoke-test.sh) is browserless and cannot
# drive the real consent flow — by design. The /mcp/consent provisioning fires
# only after (a) a real federated browser login and (b) a valid HMAC-signed
# picker-request token from the SPI. A script can't (and MUST NOT be able to)
# forge either — that barrier IS the handoff security property.
#
# This test resolves that by putting a HUMAN in the loop for exactly the one
# step that must be manual (the browser login + consent), and automating
# everything around it: setup, the loopback redirect capture, the token
# exchange, and all assertions. It uses a loopback listener as the redirect_uri
# (http://127.0.0.1:PORT/callback) — the SAME pattern Claude Code and desktop
# MCP clients use — so it also validates loopback redirect-URI handling.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHEN TO RUN THIS  (it is rare + manual by design — not a CI check)
# ─────────────────────────────────────────────────────────────────────────────
#   • Before cutting a release that touches auth / MCP.
#   • After changing the SPI, the browser-mcp-tenant-pick flow, the consent
#     wizard, or the /mcp/consent provisioning code.
#   • When standing up a new environment (dev/staging/prod) for the first time.
#   • As a named pre-GA acceptance gate (see DEFERRED_ITEMS.md).
# It is NOT run on every commit. It needs a human with a browser and valid
# federated credentials for the realm.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT IT VALIDATES (the whole real chain, end to end)
# ─────────────────────────────────────────────────────────────────────────────
#   1. DCR registration produces a usable public client.
#   2. A real authorize request routes through the MCP flow → /mcp/consent.
#   3. The human completes real federated login + the consent wizard.
#   4. Option B provisioning ran: the client now has mcp-default + author-bundle
#      default scopes, yourapp:admin optional, browser flow bound to the MCP flow.
#   5. The mcp_provisioned_clients row shows provisioned_at (if DB access given).
#   6. The issued token has aud=yourapp-mcp-api, the granted scopes, and a tenant.
#   7. Cleanup removes the throwaway client.
#
# ─────────────────────────────────────────────────────────────────────────────
# REQUIREMENTS
# ─────────────────────────────────────────────────────────────────────────────
#   • bash, curl, jq, openssl, python3 (for the loopback listener + PKCE)
#   • A reachable Keycloak with the MCP realm configured (flow, scopes, SPI, DCR)
#   • ADMIN_CLIENT_SECRET for the admin-api service account (to inspect client)
#   • A human able to complete federated login for the realm
#   • The loopback redirect (http://127.0.0.1:PORT/callback) must be permitted by
#     the secure-redirect-uris-enforcer in the mcp-hardening profile: it needs
#     allow-ipv4-loopback-address + allow-http-scheme = true (setup guide D.6a).
#     Use the IP literal 127.0.0.1, NOT localhost (RFC 8252 §7.3).
#
# Usage:
#   YOURAPP_ENV=prod ADMIN_CLIENT_SECRET=xxxxx ./mcp-e2e-interactive.sh
#   Optional: CALLBACK_PORT=53789  DB_CHECK_CMD='psql ... -c "..."'
#
set -uo pipefail

# ── colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
    YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

PASS=0; FAIL=0; WARN=0
pass() { echo -e "  ${GREEN}PASS${RESET}  $1${2:+  —  $2}"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${RESET}  $1${2:+  —  $2}"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}WARN${RESET}  $1${2:+  —  $2}"; WARN=$((WARN+1)); }
step() { echo ""; echo -e "${BOLD}${BLUE}▶ $1${RESET}"; }

die() { echo -e "${RED}FATAL:${RESET} $1" >&2; exit 1; }

# ── config (mirrors keycloak-smoke-test.sh conventions) ─────────────────────
YOURAPP_ENV="${YOURAPP_ENV:-}"
[[ -z "$YOURAPP_ENV" ]] && die "Set YOURAPP_ENV (prod|dev|test)."

case "$YOURAPP_ENV" in
    prod) DEFAULT_KC_URL="https://auth.yourapp.com" ;;
    dev)  DEFAULT_KC_URL="https://auth.yourapp.com" ;;
    test) DEFAULT_KC_URL="http://localhost:8080" ;;
    *)    die "Unknown YOURAPP_ENV '$YOURAPP_ENV'." ;;
esac

KC_URL="${KC_URL:-$DEFAULT_KC_URL}"; KC_URL="${KC_URL%/}"
REALM="${REALM:-yourapp-${YOURAPP_ENV}}"
REALM_BASE="${KC_URL}/realms/${REALM}"
ADMIN_CLIENT_ID="${ADMIN_CLIENT_ID:-yourapp-${YOURAPP_ENV}-admin-api}"
ADMIN_CLIENT_SECRET="${ADMIN_CLIENT_SECRET:-}"

MCP_FLOW_NAME="${MCP_FLOW_NAME:-browser-mcp-tenant-pick}"
MCP_DEFAULT_SCOPE="${MCP_DEFAULT_SCOPE:-mcp-default}"
MCP_AUDIENCE="${MCP_AUDIENCE:-yourapp-mcp-api}"
MCP_AUTHOR_BUNDLE_SCOPES=("yourapp:read" "yourapp:comment" "yourapp:curate" "yourapp:write" "yourapp:share")

# Loopback callback port. Default: DYNAMIC — the OS hands us a free, bindable
# port (resolved after the dependency check, since it needs python3). Override
# with CALLBACK_PORT only if you need a fixed one. CALLBACK_URI is built there too.
CALLBACK_PORT="${CALLBACK_PORT:-}"

# Optional: a shell command that, given $CLIENT_ID in the environment, prints the
# mcp_provisioned_clients row (or its provisioned_at). If unset, that check skips.
DB_CHECK_CMD="${DB_CHECK_CMD:-}"

DISCOVERY_URL="${REALM_BASE}/.well-known/openid-configuration"
DCR_ENDPOINT="${REALM_BASE}/clients-registrations/openid-connect"

for bin in curl jq openssl python3; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not found."
done
[[ -z "$ADMIN_CLIENT_SECRET" ]] && die "Set ADMIN_CLIENT_SECRET (admin-api service account secret)."

# Resolve the loopback callback port. Hardcoding one (e.g. 53789) is fragile on
# WSL2: Windows/Hyper-V reserves large "excluded" TCP port ranges (see
# `netsh int ipv4 show excludedportrange tcp`) that NO WSL process can bind — so
# bind() fails with "Address already in use" even though nothing is listening.
# Asking the OS for port 0 always returns a port outside every excluded/in-use
# range, which is why this defaults to a dynamic port instead of a fixed one.
if [[ -z "${CALLBACK_PORT}" ]]; then
    CALLBACK_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()') \
        || die "could not allocate a free loopback port"
fi
CALLBACK_URI="http://127.0.0.1:${CALLBACK_PORT}/callback"

echo -e "${BOLD}MCP interactive end-to-end test${RESET}"
echo -e "  ${DIM}env:${RESET}          ${YOURAPP_ENV}"
echo -e "  ${DIM}realm:${RESET}        ${REALM}"
echo -e "  ${DIM}kc_url:${RESET}       ${KC_URL}"
echo -e "  ${DIM}redirect:${RESET}     ${CALLBACK_URI}  ${DIM}(loopback — same pattern as Claude Code / desktop MCP clients)${RESET}"
echo -e "  ${DIM}mcp flow:${RESET}     ${MCP_FLOW_NAME}"
echo ""
echo -e "${YELLOW}This test needs YOU to complete a real login in a browser. It is meant to be"
echo -e "run rarely (before releases / after SPI/consent changes / new env).${RESET}"

# ── discovery ───────────────────────────────────────────────────────────────
step "1. OIDC discovery"
DISCO=$(curl -s "$DISCOVERY_URL")
AUTH_ENDPOINT=$(echo "$DISCO" | jq -r '.authorization_endpoint // empty')
TOKEN_ENDPOINT=$(echo "$DISCO" | jq -r '.token_endpoint // empty')
REG_ENDPOINT=$(echo "$DISCO" | jq -r '.registration_endpoint // empty')
[[ -z "$AUTH_ENDPOINT" || -z "$TOKEN_ENDPOINT" ]] && die "Discovery failed at $DISCOVERY_URL"
pass "discovery" "authorize + token endpoints resolved"
[[ -n "$REG_ENDPOINT" ]] && DCR_ENDPOINT="$REG_ENDPOINT"

# ── admin token (to inspect the client post-consent) ────────────────────────
step "2. Admin API token (to inspect client shape after consent)"
ADMIN_TOKEN=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${ADMIN_CLIENT_ID}" \
    -d "client_secret=${ADMIN_CLIENT_SECRET}" | jq -r '.access_token // empty')
[[ -z "$ADMIN_TOKEN" ]] && die "Could not obtain admin-api access token — check ADMIN_CLIENT_SECRET."
pass "admin token" "acquired"

# ── DCR registration (public client, loopback redirect, PKCE) ───────────────
step "3. Register a throwaway MCP client via DCR"
# Register BOTH loopback forms: the secure-redirect-uris-enforcer keys on the
# 127.0.0.1 IP literal, but Keycloak's Trusted Hosts loopback check normalizes to
# localhost. Subsystems disagree (setup guide D.6a), so offer both; we use the IP
# literal as the actual redirect_uri at authorize time.
REG_BODY=$(jq -n --arg redir "$CALLBACK_URI" --arg redir2 "http://localhost:${CALLBACK_PORT}/callback" '{
    client_name: "mcp-e2e-interactive",
    redirect_uris: [$redir, $redir2],
    grant_types: ["authorization_code","refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
    scope: "openid mcp-default yourapp:read yourapp:comment yourapp:curate yourapp:write yourapp:share"
}')
REG_RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "$DCR_ENDPOINT" \
    -H "Content-Type: application/json" -d "$REG_BODY")
REG_STATUS=$(echo "$REG_RESP" | grep "HTTP_STATUS:" | cut -d: -f2)
REG_JSON=$(echo "$REG_RESP" | sed '/HTTP_STATUS:/d')
if [[ "$REG_STATUS" != "201" ]]; then
    ERR=$(echo "$REG_JSON" | jq -r '.error_description // .error // "?"' 2>/dev/null)
    die "DCR registration failed (HTTP $REG_STATUS): $ERR
     If this is about the redirect URI (Invalid redirectUris), the secure-redirect-uris-enforcer
     in the mcp-hardening profile is rejecting loopback. Set allow-ipv4-loopback-address +
     allow-http-scheme = true on that executor (setup guide D.6a), and use 127.0.0.1 not localhost."
fi
CLIENT_ID=$(echo "$REG_JSON" | jq -r '.client_id')
REG_ACCESS_TOKEN=$(echo "$REG_JSON" | jq -r '.registration_access_token // empty')
export CLIENT_ID
pass "DCR registration" "client_id=${CLIENT_ID}"

# capture "before" state (should be unprovisioned — no scopes/flow binding yet)
before_shape() {
    local internal_id def_scopes flow_bind
    internal_id=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id // empty')
    [[ -z "$internal_id" ]] && { echo "  ${DIM}(could not read client for before-state)${RESET}"; return; }
    def_scopes=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients/${internal_id}/default-client-scopes" | jq -r '[.[].name] | join(",")')
    flow_bind=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].authenticationFlowBindingOverrides.browser // "none"')
    echo -e "  ${DIM}before consent — default scopes: [${def_scopes}]; browser-flow override: ${flow_bind}${RESET}"
}
before_shape

# ── PKCE + authorize URL ────────────────────────────────────────────────────
step "4. Build the authorize URL (PKCE S256, loopback redirect)"
CODE_VERIFIER=$(openssl rand -base64 60 | tr -d '\n=+/' | cut -c1-64)
CODE_CHALLENGE=$(printf '%s' "$CODE_VERIFIER" | openssl dgst -binary -sha256 | openssl base64 | tr '+/' '-_' | tr -d '=\n')
STATE=$(openssl rand -hex 12)
SCOPE_REQ="openid mcp-default yourapp:read yourapp:comment yourapp:curate yourapp:write yourapp:share"
# url-encode scope spaces
SCOPE_ENC=$(printf '%s' "$SCOPE_REQ" | sed 's/ /%20/g')
AUTH_URL="${AUTH_ENDPOINT}?client_id=${CLIENT_ID}&response_type=code&redirect_uri=$(printf '%s' "$CALLBACK_URI" | sed 's|:|%3A|g; s|/|%2F|g')&scope=${SCOPE_ENC}&state=${STATE}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256"
pass "authorize URL built" "PKCE S256, resource audience via mcp-default scope"

# ── loopback listener: capture the code ─────────────────────────────────────
step "5. Complete login in your browser"
echo -e "${BOLD}Open this URL in your browser and complete login + the consent wizard:${RESET}"
echo ""
echo -e "${BLUE}${AUTH_URL}${RESET}"
echo ""
echo -e "${DIM}A local listener is waiting on ${CALLBACK_URI} to catch the redirect."
echo -e "After you finish consent, the browser will redirect there and this script continues.${RESET}"
echo ""

# ── reclaim the loopback port from a stale listener ─────────────────────────
# The one-shot listener below blocks up to 10 min (srv.timeout). If a prior run
# was aborted (browser closed / Ctrl-C), its python listener can still hold the
# port and a re-run dies with "Address already in use". This is a dedicated
# loopback test port, so anything on it is a stale listener — reclaim it.
if command -v fuser >/dev/null 2>&1 && fuser "${CALLBACK_PORT}/tcp" >/dev/null 2>&1; then
    HOLDER=$(fuser "${CALLBACK_PORT}/tcp" 2>/dev/null | tr -s ' ')
    warn "port ${CALLBACK_PORT} busy" "reclaiming from a stale listener (${HOLDER# }) — likely a prior aborted run"
    fuser -k "${CALLBACK_PORT}/tcp" >/dev/null 2>&1; sleep 1
elif command -v lsof >/dev/null 2>&1; then
    HOLDER=$(lsof -ti "tcp:${CALLBACK_PORT}" 2>/dev/null)
    if [[ -n "$HOLDER" ]]; then
        warn "port ${CALLBACK_PORT} busy" "reclaiming from a stale listener (pid ${HOLDER})"
        kill $HOLDER 2>/dev/null; sleep 1
    fi
fi

# Minimal one-shot HTTP listener in python3: waits for GET /callback?code=...&state=...
# prints "code state" to stdout, returns a friendly page to the browser, exits.
CAPTURED=$(python3 - "$CALLBACK_PORT" "$STATE" <<'PYEOF'
import sys, http.server, urllib.parse
port = int(sys.argv[1]); expected_state = sys.argv[2]
result = {"code": "", "state": "", "error": ""}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if not u.path.startswith("/callback"):
            self.send_response(404); self.end_headers(); return
        q = urllib.parse.parse_qs(u.query)
        result["code"] = (q.get("code") or [""])[0]
        result["state"] = (q.get("state") or [""])[0]
        result["error"] = (q.get("error") or [""])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html"); self.end_headers()
        ok = result["code"] and result["state"] == expected_state and not result["error"]
        msg = "✅ Captured. You can close this tab and return to the terminal." if ok \
              else "⚠️ Something's off (state mismatch or error). Check the terminal."
        self.wfile.write(("<html><body style='font-family:sans-serif;padding:3rem'>"
                          f"<h2>{msg}</h2></body></html>").encode())
    # stop after one request
import time
class Server(http.server.HTTPServer):
    allow_reuse_address = True   # rebind over a TIME_WAIT socket
# Retry the bind briefly: the port was free when we picked it, but a transient
# socket (e.g. this script's own outbound curls) could momentarily hold it.
srv = None
for _attempt in range(6):
    try:
        srv = Server(("127.0.0.1", port), H); break
    except OSError:
        time.sleep(0.5)
if srv is None:
    print(f'\t\tbind_failed:{port}'); sys.exit(0)
srv.timeout = 600  # 10 min for the human
srv.handle_request()
print(f'{result["code"]}\t{result["state"]}\t{result["error"]}')
PYEOF
)
CODE=$(printf '%s' "$CAPTURED" | cut -f1)
GOT_STATE=$(printf '%s' "$CAPTURED" | cut -f2)
CB_ERROR=$(printf '%s' "$CAPTURED" | cut -f3)

if [[ "$CB_ERROR" == bind_failed:* ]]; then
    fail "authorization" "could not bind the loopback listener on port ${CB_ERROR#bind_failed:} even after retries — set a different CALLBACK_PORT and re-run (on WSL2 check 'netsh int ipv4 show excludedportrange tcp' for reserved ranges)"
elif [[ -n "$CB_ERROR" ]]; then
    fail "authorization" "callback returned error='${CB_ERROR}'"
elif [[ -z "$CODE" ]]; then
    fail "authorization" "no code captured (listener timed out or redirect never arrived)"
elif [[ "$GOT_STATE" != "$STATE" ]]; then
    fail "authorization" "state mismatch — expected ${STATE}, got ${GOT_STATE} (possible CSRF / stale flow)"
else
    pass "authorization code captured" "state matched; loopback redirect worked"
fi

# ── token exchange ──────────────────────────────────────────────────────────
ACCESS_TOKEN=""
if [[ -n "$CODE" && "$GOT_STATE" == "$STATE" ]]; then
    step "6. Exchange the code for tokens (PKCE verifier)"
    TOK=$(curl -s -X POST "$TOKEN_ENDPOINT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code" \
        -d "client_id=${CLIENT_ID}" \
        -d "code=${CODE}" \
        -d "redirect_uri=${CALLBACK_URI}" \
        -d "code_verifier=${CODE_VERIFIER}")
    ACCESS_TOKEN=$(echo "$TOK" | jq -r '.access_token // empty')
    if [[ -z "$ACCESS_TOKEN" ]]; then
        fail "token exchange" "no access_token — $(echo "$TOK" | jq -r '.error_description // .error // "?"')"
    else
        pass "token exchange" "access_token received"
    fi
fi

# ── assert token claims ─────────────────────────────────────────────────────
if [[ -n "$ACCESS_TOKEN" ]]; then
    step "7. Assert token claims (aud / scope / tenant)"
    # decode JWT payload (2nd segment), pad base64url
    PAYLOAD=$(printf '%s' "$ACCESS_TOKEN" | cut -d. -f2 | tr '_-' '/+')
    case $(( ${#PAYLOAD} % 4 )) in 2) PAYLOAD+="==";; 3) PAYLOAD+="=";; esac
    CLAIMS=$(printf '%s' "$PAYLOAD" | openssl base64 -d -A 2>/dev/null)

    AUD=$(echo "$CLAIMS" | jq -r '.aud // empty' 2>/dev/null)
    if echo "$CLAIMS" | jq -e --arg a "$MCP_AUDIENCE" '(.aud // empty) | if type=="array" then index($a) != null else . == $a end' >/dev/null 2>&1; then
        pass "token aud" "includes ${MCP_AUDIENCE}"
    else
        fail "token aud" "expected ${MCP_AUDIENCE}, got '${AUD}' — check the mcp-default audience mapper (setup guide D.4)"
    fi

    SCOPE_CLAIM=$(echo "$CLAIMS" | jq -r '.scope // ""' 2>/dev/null)
    if [[ "$SCOPE_CLAIM" == *"$MCP_DEFAULT_SCOPE"* && "$SCOPE_CLAIM" == *"yourapp:read"* ]]; then
        pass "token scope" "granted: ${SCOPE_CLAIM}"
    else
        warn "token scope" "scope='${SCOPE_CLAIM}' — expected mcp-default + author bundle; check what you granted in the consent wizard"
    fi

    TENANT=$(echo "$CLAIMS" | jq -r '.tenant // empty' 2>/dev/null)
    if [[ -n "$TENANT" ]]; then
        pass "token tenant" "tenant='${TENANT}' present (SPI tenant-picker resolved a tenant)"
    else
        fail "token tenant" "no 'tenant' claim — the SPI tenant-picker step didn't stamp a tenant (check the ${MCP_FLOW_NAME} flow + mcp-default tenant mapper, setup guide D.4)"
    fi
fi

# ── assert client shape after provisioning ──────────────────────────────────
step "8. Assert Option B provisioning ran (client shape)"
INTERNAL_ID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
    "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id // empty')
if [[ -z "$INTERNAL_ID" ]]; then
    fail "client shape" "could not re-read client ${CLIENT_ID}"
else
    DEF_SCOPES=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients/${INTERNAL_ID}/default-client-scopes" | jq -r '.[].name')
    OPT_SCOPES=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients/${INTERNAL_ID}/optional-client-scopes" | jq -r '.[].name')

    MISSING=()
    for s in "$MCP_DEFAULT_SCOPE" "${MCP_AUTHOR_BUNDLE_SCOPES[@]}"; do
        echo "$DEF_SCOPES" | grep -qx "$s" || MISSING+=("$s")
    done
    if [[ ${#MISSING[@]} -eq 0 ]]; then
        pass "default scopes" "mcp-default + author bundle assigned by app provisioning"
    else
        fail "default scopes" "missing: ${MISSING[*]} — assignMcpScopes didn't run or lacked manage-clients (web spec §7.5)"
    fi

    if echo "$DEF_SCOPES" | grep -qx "yourapp:admin"; then
        fail "yourapp:admin placement" "yourapp:admin is a DEFAULT scope — must be optional"
    elif echo "$OPT_SCOPES" | grep -qx "yourapp:admin"; then
        pass "yourapp:admin placement" "correctly optional"
    else
        warn "yourapp:admin placement" "yourapp:admin not assigned at all (optional expected) — acceptable if intentionally omitted"
    fi

    FLOW_ID=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].authenticationFlowBindingOverrides.browser // empty')
    if [[ -n "$FLOW_ID" ]]; then
        BOUND_ALIAS=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
            "${KC_URL}/admin/realms/${REALM}/authentication/flows" | jq -r --arg id "$FLOW_ID" '.[] | select(.id==$id) | .alias')
        [[ "$BOUND_ALIAS" == "$MCP_FLOW_NAME" ]] \
            && pass "flow binding" "browser flow bound to ${MCP_FLOW_NAME} (bindBrowserFlow ran)" \
            || fail "flow binding" "bound to '${BOUND_ALIAS}', expected ${MCP_FLOW_NAME}"
    else
        fail "flow binding" "no per-client browser-flow override — bindBrowserFlow didn't run (web spec §7.5)"
    fi
fi

# ── optional: DB provisioned_at check ───────────────────────────────────────
step "9. Provisioning record (mcp_provisioned_clients)"
if [[ -n "$DB_CHECK_CMD" ]]; then
    if OUT=$(eval "$DB_CHECK_CMD" 2>&1); then
        if echo "$OUT" | grep -qiE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
            pass "provisioned_at" "row present with a timestamp"
        else
            warn "provisioned_at" "DB query ran but no timestamp found in output: ${OUT}"
        fi
    else
        warn "provisioned_at" "DB_CHECK_CMD failed: ${OUT}"
    fi
else
    warn "provisioned_at" "skipped — set DB_CHECK_CMD to a query that prints the mcp_provisioned_clients row for \$CLIENT_ID (e.g. a psql -c \"select provisioned_at from mcp_provisioned_clients where mcp_client_id='\$CLIENT_ID'\")"
fi

# ── cleanup ─────────────────────────────────────────────────────────────────
step "10. Cleanup"
DELETED="false"
if [[ -n "$REG_ACCESS_TOKEN" ]]; then
    curl -s -o /dev/null -X DELETE "${DCR_ENDPOINT}/${CLIENT_ID}" \
        -H "Authorization: Bearer $REG_ACCESS_TOKEN" && DELETED="true"
fi
if [[ "$DELETED" != "true" && -n "$INTERNAL_ID" ]]; then
    # fall back to admin delete
    curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" \
        "${KC_URL}/admin/realms/${REALM}/clients/${INTERNAL_ID}" && DELETED="true"
fi
[[ "$DELETED" == "true" ]] \
    && pass "cleanup" "test client ${CLIENT_ID} deleted" \
    || warn "cleanup" "could not delete ${CLIENT_ID} — remove it manually from Keycloak admin"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Summary:${RESET} ${GREEN}${PASS} passed${RESET}, ${RED}${FAIL} failed${RESET}, ${YELLOW}${WARN} warnings${RESET}"
if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${RED}End-to-end validation FAILED — see failures above.${RESET}"
    exit 1
fi
echo -e "${GREEN}End-to-end MCP flow validated: DCR → real login → consent → provisioning → token.${RESET}"
exit 0
