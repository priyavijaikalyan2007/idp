#!/bin/bash

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

PROJECT_ID="stellar-zoo-478023-v4"
REGION="asia-southeast1"
REPO_NAME="idp"
IMAGE_NAME="keycloak"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}"

KEYCLOAK_VERSION=$(grep -oP '^FROM quay.io/keycloak/keycloak:\K[^ ]+' "${SCRIPT_DIR}/Dockerfile" | head -n 1)
GIT_COMMIT=$(git -C "${SCRIPT_DIR}" rev-parse --short=7 HEAD)
VERSION_TAG="${KEYCLOAK_VERSION}-${GIT_COMMIT}"

LOCAL_TAG="${IMAGE_NAME}:local"
REMOTE_TAG="${REGISTRY}:${VERSION_TAG}"
BUILD_INFO="${SCRIPT_DIR}/build.json"

echo "=== Building Docker Image ==="
echo "Keycloak version: ${KEYCLOAK_VERSION}"
echo "Git commit:       ${GIT_COMMIT}"
echo "Local tag:        ${LOCAL_TAG}"
echo "Remote tag:       ${REMOTE_TAG}"

docker build --no-cache -t "${LOCAL_TAG}" "${SCRIPT_DIR}"
docker tag "${LOCAL_TAG}" "${REMOTE_TAG}"

cat > "${BUILD_INFO}" <<EOF
{
  "keycloak_version": "${KEYCLOAK_VERSION}",
  "git_commit": "${GIT_COMMIT}",
  "version_tag": "${VERSION_TAG}",
  "local_tag": "${LOCAL_TAG}",
  "remote_tag": "${REMOTE_TAG}",
  "registry": "${REGISTRY}",
  "region": "${REGION}",
  "project_id": "${PROJECT_ID}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo ""
echo "=== Build Complete ==="
echo "Build info written to: ${BUILD_INFO}"
echo "Run ./push.sh to push ${REMOTE_TAG} to Artifact Registry."
