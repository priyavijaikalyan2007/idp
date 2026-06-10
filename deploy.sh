#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: deploy.sh
# 📜 PURPOSE: Builds, pushes, and deploys a fresh Keycloak image to Cloud Run.
#             Reads remote_tag + region from build.json. Updates the image of
#             the existing service WITHOUT replacing cloudrun.yaml (so manual
#             env/secret bindings remain). Tails logs after deploy.
#
#             For a full config replace (env vars + secret bindings from
#             cloudrun.yaml), run instead:
#               gcloud run services replace cloudrun.yaml \
#                 --region=your-region --project=your-gcp-project-id
# 🔗 RELATES: [[build.sh]], [[push.sh]], [[cloudrun.yaml]], [[smoke.sh]]
# ----------------------------------------------------------------------------

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BUILD_INFO="${SCRIPT_DIR}/build.json"

SERVICE_NAME="yourappauth"

# ----------------------------------------------------- build + push (chain)

echo "=== 1/3 Building ==="
"${SCRIPT_DIR}/build.sh"

echo ""
echo "=== 2/3 Pushing ==="
"${SCRIPT_DIR}/push.sh"

# ----------------------------------------------------- read build metadata

if [[ ! -f "${BUILD_INFO}" ]]; then
    echo "Error: ${BUILD_INFO} not found after build.sh." >&2
    exit 1
fi

read_field() {
    python3 -c "import json,sys; print(json.load(open('${BUILD_INFO}'))['$1'])"
}

REMOTE_TAG=$(read_field remote_tag)
REGION=$(read_field region)
PROJECT_ID=$(read_field project_id)
SPI_VERSION=$(read_field spi_version)
GIT_COMMIT=$(read_field git_commit)

# ----------------------------------------------------- deploy

echo ""
echo "=== 3/3 Deploying ==="
echo "Service:     ${SERVICE_NAME}"
echo "Region:      ${REGION}"
echo "Project:     ${PROJECT_ID}"
echo "Image:       ${REMOTE_TAG}"
echo "SPI version: ${SPI_VERSION}"
echo "Git commit:  ${GIT_COMMIT}"

gcloud run deploy "${SERVICE_NAME}" \
    --image "${REMOTE_TAG}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}" \
    --platform managed

echo ""
echo "=== Deploy Complete ==="
echo "Verify with:   ./smoke.sh"
echo "Stream logs:   ./monitor.sh"
echo "Recent logs:   ./logs.sh"
echo ""
echo "Sleeping 60s before tailing logs ..."
sleep 60

echo ""
echo "=== Tailing logs (Ctrl-C to stop) ==="
gcloud alpha run services logs tail "${SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
