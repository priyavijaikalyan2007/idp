#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: rollback.sh
# 📜 PURPOSE: Rolls the Cloud Run service back to an ALREADY-PUSHED image tag
#             (typically a kc<ver>-<NNNNN> revision from ./revisions.sh) WITHOUT
#             rebuilding. The escape hatch when a base-image bump breaks prod.
# 🔗 RELATES: [[revisions.sh]], [[push.sh]], [[deploy.sh]]
# ⚡ FLOW: [./rollback.sh <tag>] -> [verify tag exists] -> [gcloud run deploy --image]
# ----------------------------------------------------------------------------

set -e

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  echo "Usage: ./rollback.sh <tag>" >&2
  echo "  e.g. ./rollback.sh kc26.6.4-00006   (list options with ./revisions.sh)" >&2
  exit 1
fi

# Registry coordinates — kept in sync with build.sh / revisions.sh.
PROJECT_ID="stellar-zoo-478023-v4"
REGION="asia-southeast1"
REPO_NAME="idp"
IMAGE_NAME="keycloak"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}"
SERVICE_NAME="knobbyauth"
IMAGE="${REGISTRY}:${TAG}"

# Fail fast if the tag doesn't exist, rather than letting Cloud Run reject it later.
if ! gcloud artifacts docker tags list "${REGISTRY}" --format='value(tag)' 2>/dev/null \
      | sed 's#.*/##' | grep -qx "${TAG}"; then
  echo "Error: tag '${TAG}' not found in ${REGISTRY}." >&2
  echo "Run ./revisions.sh to list available revisions." >&2
  exit 1
fi

echo "=== Rolling back ${SERVICE_NAME} ==="
echo "Image: ${IMAGE}"
echo "(no rebuild — deploying an existing image)"
echo ""

gcloud run deploy "${SERVICE_NAME}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --platform managed

echo ""
echo "=== Rollback Complete ==="
echo "Verify with:  ./smoke.sh"
echo "Stream logs:  ./monitor.sh"
