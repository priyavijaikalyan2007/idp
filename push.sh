#!/bin/bash

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BUILD_INFO="${SCRIPT_DIR}/build.json"

if [[ ! -f "${BUILD_INFO}" ]]; then
  echo "Error: ${BUILD_INFO} not found. Run ./build.sh first." >&2
  exit 1
fi

read_field() {
  python3 -c "import json,sys; print(json.load(open('${BUILD_INFO}'))['$1'])"
}

REMOTE_TAG=$(read_field remote_tag)
LATEST_TAG=$(read_field latest_tag)
REGION=$(read_field region)
REGISTRY=$(read_field registry)
KEYCLOAK_VERSION=$(read_field keycloak_version)

if ! docker image inspect "${REMOTE_TAG}" > /dev/null 2>&1; then
  echo "Error: image ${REMOTE_TAG} not found locally. Run ./build.sh again." >&2
  exit 1
fi

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# --- Monotonic revision tag: kc<keycloak-version>-<NNNNN> -------------------
# In addition to the timestamp-commit tag, stamp each pushed image with a
# GLOBALLY monotonic, zero-padded counter prefixed by the Keycloak base version
# (e.g. kc26.6.4-00007). The counter is derived from the registry (its source of
# truth), so it survives across machines and never depends on local state. It is
# global across Keycloak versions — a strict total order over all builds — while
# the kc<ver> prefix records which base each build used. That is exactly what you
# need to recover from a bad base-image bump: if kc26.7.0-00008 breaks, redeploy
# the highest-numbered kc26.6.4-* tag (the last-good build on the prior base).
# Determine the next revision by taking the max existing NNNNN across ALL kc*-*
# tags and adding one. `tail` is last in each pipeline so an empty registry does
# not trip `set -e`. NOTE: single-operator assumption — two concurrent pushes
# could read the same max and collide on the tag; fine for this workflow.
echo "=== Assigning monotonic revision tag ==="
LAST_REV=$(gcloud artifacts docker tags list "${REGISTRY}" --format='value(tag)' 2>/dev/null \
  | sed 's#.*/##' \
  | grep -oE 'kc[0-9.]+-[0-9]{5}$' \
  | grep -oE '[0-9]{5}$' \
  | sort -n | tail -1)
LAST_REV=$((10#${LAST_REV:-0}))
NEXT_REV=$(printf '%05d' "$((LAST_REV + 1))")
KC_REVISION="kc${KEYCLOAK_VERSION}-${NEXT_REV}"
KC_REVISION_TAG="${REGISTRY}:${KC_REVISION}"
docker tag "${REMOTE_TAG}" "${KC_REVISION_TAG}"
echo "Revision:  ${KC_REVISION}   (previous highest: $(printf '%05d' "${LAST_REV}"))"

echo ""
echo "=== Pushing to Artifact Registry ==="
echo "Versioned: ${REMOTE_TAG}"
echo "Revision:  ${KC_REVISION_TAG}"
echo "Latest:    ${LATEST_TAG}"

# Push the versioned tag first; this is the load-bearing artifact that Cloud Run
# revisions pin to. The kc-revision tag is an alias to the same image (your
# human-friendly rollback handle). The :latest tag is a moving convenience tag.
docker push "${REMOTE_TAG}"
docker push "${KC_REVISION_TAG}"
docker push "${LATEST_TAG}"

# Record the assigned revision back into build.json so deploy.sh / audits can read it.
python3 - "${BUILD_INFO}" "${KC_REVISION}" "${KC_REVISION_TAG}" "${NEXT_REV}" <<'PY'
import json, sys
path, rev, tag, num = sys.argv[1:5]
d = json.load(open(path))
d["kc_revision"] = rev
d["kc_revision_tag"] = tag
d["revision_number"] = num
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY

echo ""
echo "=== Push Complete ==="
echo "Images available at:"
echo "  ${REMOTE_TAG}"
echo "  ${KC_REVISION_TAG}   <- monotonic rollback handle"
echo "  ${LATEST_TAG}"
echo ""
echo "List revisions / find a rollback target:  ./revisions.sh"
