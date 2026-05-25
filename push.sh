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
REGION=$(read_field region)

if ! docker image inspect "${REMOTE_TAG}" > /dev/null 2>&1; then
  echo "Error: image ${REMOTE_TAG} not found locally. Run ./build.sh again." >&2
  exit 1
fi

echo "=== Pushing to Artifact Registry ==="
echo "Image: ${REMOTE_TAG}"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker push "${REMOTE_TAG}"

echo ""
echo "=== Push Complete ==="
echo "Image available at: ${REMOTE_TAG}"
