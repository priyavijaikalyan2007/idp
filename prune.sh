#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: prune.sh
# 📜 PURPOSE: Deletes old container image versions from Artifact Registry,
#             keeping the N most-recent versions of the yourapp-keycloak image
#             (default N=5). Also deletes inactive Cloud Run revisions that
#             no longer serve traffic. Cross-checks both: an image that is
#             still referenced by any serving revision is preserved.
# 🔗 RELATES: [[push.sh]], [[deploy.sh]]
# ----------------------------------------------------------------------------

set -e

PROJECT_ID="your-gcp-project-id"
REGION="your-region"
REPO_NAME="idp"
IMAGE_NAME="keycloak"
SERVICE_NAME="your-keycloak-service"

REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}"
KEEP_LAST_N="${KEEP_LAST_N:-5}"

# ============================================================================
# Phase 1 — Cloud Run revisions
# ============================================================================
echo "=== Phase 1: Pruning inactive Cloud Run revisions for ${SERVICE_NAME} ==="

SERVING_REVISIONS=$(gcloud run services describe "${SERVICE_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --format='value(status.traffic.revisionName)' || true)

if [[ -z "${SERVING_REVISIONS}" ]]; then
    echo "Could not determine serving revisions. Skipping revision prune to avoid"
    echo "deleting an active revision. Verify the service exists."
else
    echo "Serving revisions (preserved):"
    echo "${SERVING_REVISIONS}" | sed 's/^/  /'
    echo "----"

    ALL_REVISIONS=$(gcloud run revisions list \
        --service "${SERVICE_NAME}" \
        --project "${PROJECT_ID}" \
        --region "${REGION}" \
        --format='value(name)')

    for rev in ${ALL_REVISIONS}; do
        if echo "${SERVING_REVISIONS}" | grep -Fq "${rev}"; then
            echo "[KEEP]   ${rev}"
        else
            echo "[DELETE] ${rev}"
            gcloud run revisions delete "${rev}" \
                --project "${PROJECT_ID}" \
                --region "${REGION}" \
                --quiet
        fi
    done
fi

# ============================================================================
# Phase 2 — Artifact Registry image versions
# ============================================================================
echo ""
echo "=== Phase 2: Pruning old Artifact Registry image versions ==="
echo "Registry:     ${REGISTRY}"
echo "Keep last:    ${KEEP_LAST_N} versions"
echo ""

# Find the image digests currently referenced by Cloud Run (any revision, not
# just serving). Even an inactive revision can be rolled back to; deleting its
# image breaks that.
REFERENCED_DIGESTS=$(gcloud run revisions list \
    --service "${SERVICE_NAME}" \
    --project "${PROJECT_ID}" \
    --region "${REGION}" \
    --format='value(image)' 2>/dev/null \
    | grep -oP '@\K[a-z0-9:]+' \
    | sort -u || true)

if [[ -n "${REFERENCED_DIGESTS}" ]]; then
    echo "Digests referenced by any revision (preserved regardless of age):"
    echo "${REFERENCED_DIGESTS}" | sed 's/^/  /'
    echo "----"
fi

# Sort image versions newest-first. Keep the first N; consider the rest for
# deletion (subject to the referenced-digests check).
mapfile -t ALL_VERSIONS < <(gcloud artifacts docker images list "${REGISTRY}" \
    --include-tags \
    --sort-by='~CREATE_TIME' \
    --format='value(IMAGE,DIGEST)' 2>/dev/null \
    | awk '{print $1 "@" $2}')

if [[ ${#ALL_VERSIONS[@]} -le ${KEEP_LAST_N} ]]; then
    echo "Only ${#ALL_VERSIONS[@]} version(s) exist; nothing to prune (threshold ${KEEP_LAST_N})."
    exit 0
fi

KEPT=0
DELETED=0
for i in "${!ALL_VERSIONS[@]}"; do
    full="${ALL_VERSIONS[$i]}"
    digest="${full##*@}"
    if [[ ${i} -lt ${KEEP_LAST_N} ]]; then
        echo "[KEEP    new] ${full}"
        KEPT=$((KEPT + 1))
        continue
    fi
    if echo "${REFERENCED_DIGESTS}" | grep -Fq "${digest}"; then
        echo "[KEEP   ref'd] ${full}"
        KEPT=$((KEPT + 1))
        continue
    fi
    echo "[DELETE]      ${full}"
    gcloud artifacts docker images delete "${full}" --quiet --delete-tags >/dev/null
    DELETED=$((DELETED + 1))
done

echo ""
echo "=== Prune complete ==="
echo "Kept:    ${KEPT} image versions"
echo "Deleted: ${DELETED} image versions"
