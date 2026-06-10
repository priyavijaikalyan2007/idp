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

if ! docker image inspect "${REMOTE_TAG}" > /dev/null 2>&1; then
  echo "Error: image ${REMOTE_TAG} not found locally. Run ./build.sh again." >&2
  exit 1
fi

echo "=== Pushing to Artifact Registry ==="
echo "Versioned: ${REMOTE_TAG}"
echo "Latest:    ${LATEST_TAG}"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# Push the versioned tag first; this is the load-bearing artifact that Cloud Run
# revisions pin to. The :latest tag follows — moving tag for convenience pulls.
docker push "${REMOTE_TAG}"
docker push "${LATEST_TAG}"

echo ""
echo "=== Push Complete ==="
echo "Images available at:"
echo "  ${REMOTE_TAG}"
echo "  ${LATEST_TAG}"
