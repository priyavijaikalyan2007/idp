#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: build.sh
# 📜 PURPOSE: Compiles the Keycloak MCP SPI and builds the customised Keycloak
#             Docker image with three tags (local, versioned, latest).
# 🔗 RELATES: [[test.sh]], [[push.sh]], [[deploy.sh]], [[Dockerfile]]
# ⚡ FLOW: [./build.sh] -> [mvn package] -> [stage /target/providers] -> [docker build]
# ----------------------------------------------------------------------------

# Builds the Knobby Keycloak Docker image end-to-end:
#   1. Compiles the MCP SPI (mvn package in src/providers/).
#   2. Stages the SPI JAR to /target/providers/ where the Dockerfile reads it.
#   3. Builds the Docker image with all OCI labels (Keycloak base, SPI, commit, date).
#   4. Tags :local + the registry tag.
#
# Use ./test.sh to run the full mvn verify (unit + Testcontainers integration).
# This script skips the integration-test phase for build-loop speed; ship-time CI
# should run ./test.sh as a gate before ./push.sh.

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

PROJECT_ID="stellar-zoo-478023-v4"
REGION="asia-southeast1"
REPO_NAME="idp"
IMAGE_NAME="keycloak"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}"

KEYCLOAK_VERSION=$(grep -oP '^FROM quay.io/keycloak/keycloak:\K[^ ]+' "${SCRIPT_DIR}/Dockerfile" | head -n 1)
GIT_COMMIT=$(git -C "${SCRIPT_DIR}" rev-parse --short=7 HEAD)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Sortable, unique-per-build version tag: UTC timestamp + short commit.
# Example: 20260615231124-8b63f47. Each build produces a distinct tag even
# when the commit is unchanged (re-builds remain disambiguable in registry).
BUILD_TIMESTAMP=$(date -u +%Y%m%d%H%M%S)
VERSION_TAG="${BUILD_TIMESTAMP}-${GIT_COMMIT}"

LOCAL_TAG="${IMAGE_NAME}:local"
REMOTE_TAG="${REGISTRY}:${VERSION_TAG}"
LATEST_TAG="${REGISTRY}:latest"
BUILD_INFO="${SCRIPT_DIR}/build.json"

echo "=== Building Keycloak MCP SPI ==="
SPI_VERSION=$(cd "${SCRIPT_DIR}/src/providers" && \
    mvn -B -ntp -q -DforceStdout help:evaluate -Dexpression=project.version)
echo "SPI version: ${SPI_VERSION}"

# Compile + unit-test only (skip Failsafe ITs for build-loop speed). Use
# ./test.sh to run unit + integration tests; ship-time CI should gate on that.
(cd "${SCRIPT_DIR}/src/providers" && mvn -B -ntp clean package -DskipITs)

echo ""
echo "=== Staging deliverable artifacts to /target/ ==="
# /target/ at repo-root is the unified Docker build input. It contains ONLY
# deployable JARs (no Maven intermediates), so the Dockerfile can COPY the
# whole directory without dragging classes/, test-classes/ etc into the image.
rm -rf "${SCRIPT_DIR}/target/providers" "${SCRIPT_DIR}/target/themes"
mkdir -p "${SCRIPT_DIR}/target/providers" "${SCRIPT_DIR}/target/themes"
cp "${SCRIPT_DIR}/src/providers/target/knobby-keycloak-mcp-spi-${SPI_VERSION}.jar" \
   "${SCRIPT_DIR}/target/providers/"
echo "Staged: target/providers/knobby-keycloak-mcp-spi-${SPI_VERSION}.jar"
echo "(target/themes/ left empty until Keycloakify theme builds activate.)"

echo ""
echo "=== Building Docker Image ==="
echo "Keycloak version: ${KEYCLOAK_VERSION}"
echo "SPI version:      ${SPI_VERSION}"
echo "Git commit:       ${GIT_COMMIT}"
echo "Build date:       ${BUILD_DATE}"
echo "Local tag:        ${LOCAL_TAG}"
echo "Remote tag:       ${REMOTE_TAG}"
echo "Latest tag:       ${LATEST_TAG}"

# Tag the same image three ways in a single build:
#   - LOCAL_TAG    (keycloak:local)   for ./run.sh and local docker inspect
#   - REMOTE_TAG   (registry:VERSION) the sortable unique tag pushed to Artifact
#                                     Registry; this is what Cloud Run revisions
#                                     pin to for traceable rollback.
#   - LATEST_TAG   (registry:latest)  moving tag; convenient for `docker pull`
#                                     but NEVER used for production deploys.
docker build --no-cache \
    --build-arg IMAGE_VERSION="${VERSION_TAG}" \
    --build-arg VCS_REF="${GIT_COMMIT}" \
    --build-arg BUILD_DATE="${BUILD_DATE}" \
    --build-arg SPI_VERSION="${SPI_VERSION}" \
    -t "${LOCAL_TAG}" \
    -t "${REMOTE_TAG}" \
    -t "${LATEST_TAG}" \
    "${SCRIPT_DIR}"

cat > "${BUILD_INFO}" <<EOF
{
  "keycloak_version": "${KEYCLOAK_VERSION}",
  "spi_version": "${SPI_VERSION}",
  "git_commit": "${GIT_COMMIT}",
  "build_timestamp": "${BUILD_TIMESTAMP}",
  "version_tag": "${VERSION_TAG}",
  "local_tag": "${LOCAL_TAG}",
  "remote_tag": "${REMOTE_TAG}",
  "latest_tag": "${LATEST_TAG}",
  "registry": "${REGISTRY}",
  "region": "${REGION}",
  "project_id": "${PROJECT_ID}",
  "built_at": "${BUILD_DATE}"
}
EOF

echo ""
echo "=== Build Complete ==="
echo "Build info written to: ${BUILD_INFO}"
echo "Run ./push.sh to push both tags to Artifact Registry:"
echo "  ${REMOTE_TAG}"
echo "  ${LATEST_TAG}"
