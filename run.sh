#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: run.sh
# 📜 PURPOSE: Runs the locally-built knobby-keycloak image against a postgres
#             sidecar. Exposes Keycloak on http://localhost:10000.
#             Press Ctrl-C to stop Keycloak; the postgres container persists
#             between runs (state survives). Use ./run.sh --clean to also
#             tear down the postgres sidecar and its volume.
# 🔗 RELATES: [[build.sh]], [[Dockerfile]]
# ----------------------------------------------------------------------------

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

NETWORK="knobby-keycloak-local-net"
POSTGRES_CONTAINER="knobby-keycloak-postgres-local"
KEYCLOAK_CONTAINER="knobby-keycloak-local"
KEYCLOAK_IMAGE="keycloak:local"
HOST_PORT=10000

# Local-dev HMAC key: 32 zero bytes base64-encoded. NOT production-safe.
# Wired for the master realm so the SPI's mcp-picker-callback endpoint can
# respond. If the user creates `knobby-dev` or similar realms locally, they
# should also set KNOBBY_MCP_HANDOFF_HMAC_KEY__<R> via -e.
LOCAL_TEST_HMAC_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# --------------------------------------------------------------------- flags

if [[ "${1:-}" == "--clean" ]]; then
    echo "=== Tearing down local-run sidecars ==="
    docker rm -f "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 || true
    docker rm -f "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    echo "  Removed containers + network"
    exit 0
fi

# --------------------------------------------------- preconditions

if ! docker image inspect "${KEYCLOAK_IMAGE}" >/dev/null 2>&1; then
    echo "Error: image ${KEYCLOAK_IMAGE} not found locally. Run ./build.sh first." >&2
    exit 1
fi

# ------------------------------------------------------- docker network

if ! docker network inspect "${NETWORK}" >/dev/null 2>&1; then
    docker network create "${NETWORK}" >/dev/null
    echo "Created network: ${NETWORK}"
fi

# ---------------------------------------------------- postgres sidecar

if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    if docker ps -a --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
        docker start "${POSTGRES_CONTAINER}" >/dev/null
        echo "Started existing postgres container: ${POSTGRES_CONTAINER}"
    else
        docker run -d \
            --name "${POSTGRES_CONTAINER}" \
            --network "${NETWORK}" \
            -e POSTGRES_USER=postgres \
            -e POSTGRES_PASSWORD=postgres \
            -e POSTGRES_DB=postgres \
            postgres:16 >/dev/null
        echo "Started new postgres container: ${POSTGRES_CONTAINER}"
    fi
fi

# Wait for postgres readiness
echo -n "Waiting for postgres to be ready"
for _ in {1..30}; do
    if docker exec "${POSTGRES_CONTAINER}" pg_isready -U postgres >/dev/null 2>&1; then
        echo " — ready."
        break
    fi
    echo -n "."
    sleep 1
done

# ---------------------------------------------------- keycloak (foreground)

# Remove any stale Keycloak container from a previous run.
docker rm -f "${KEYCLOAK_CONTAINER}" >/dev/null 2>&1 || true

echo ""
echo "=== Starting Keycloak ==="
echo "Image:    ${KEYCLOAK_IMAGE}"
echo "URL:      http://localhost:${HOST_PORT}"
echo "Admin:    admin / admin"
echo "DB:       postgres:5432 @ ${POSTGRES_CONTAINER}, user/db: postgres/postgres"
echo "Stop:     Ctrl-C (postgres survives; use ./run.sh --clean for full teardown)"
echo ""

docker run --rm -it \
    --name "${KEYCLOAK_CONTAINER}" \
    --network "${NETWORK}" \
    -p "${HOST_PORT}:8080" \
    -e KC_DB=postgres \
    -e KC_DB_URL="jdbc:postgresql://${POSTGRES_CONTAINER}:5432/postgres" \
    -e KC_DB_USERNAME=postgres \
    -e KC_DB_PASSWORD=postgres \
    -e KC_HOSTNAME=localhost \
    -e KC_HOSTNAME_STRICT=false \
    -e KC_HTTP_ENABLED=true \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
    -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    -e KNOBBY_MCP_HANDOFF_HMAC_KEY__MASTER="${LOCAL_TEST_HMAC_KEY}" \
    --entrypoint /opt/keycloak/bin/kc.sh \
    "${KEYCLOAK_IMAGE}" \
    start-dev
