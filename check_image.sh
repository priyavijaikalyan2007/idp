#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: check_image.sh
# 📜 PURPOSE: Forensic inspection of a built Keycloak image. Prints the OCI
#             traceability labels, the contents of /opt/keycloak/providers/,
#             and the Quarkus build artifacts + conf directory listing so two
#             images can be diffed quickly during an incident.
#             Usage: ./check_image.sh <image-ref-or-id>
# 🔗 RELATES: [[build.sh]], [[Dockerfile]], [[prune.sh]]
# ⚡ FLOW: [./check_image.sh IMAGE] -> [docker inspect labels] -> [ls providers] -> [ls quarkus/conf]
# ----------------------------------------------------------------------------

# Born during the 2026-06-10 production incident: comparing a suspect image
# against a known-good one (labels, baked-in providers, augmentation output)
# answers "what is actually different between these two images?" in seconds.
# Pipe two invocations into files and diff them.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <image-ref-or-id>" >&2
    exit 1
fi

IMAGE="$1"

echo "=== ${IMAGE} labels ==="
docker inspect "${IMAGE}" \
    --format='base:        {{ index .Config.Labels "io.yourapp.keycloak.base" }}
spi version: {{ index .Config.Labels "io.yourapp.keycloak.spi.version" }}
img version: {{ index .Config.Labels "org.opencontainers.image.version" }}
revision:    {{ index .Config.Labels "org.opencontainers.image.revision" }}
created:     {{ index .Config.Labels "org.opencontainers.image.created" }}'

echo "=== ${IMAGE} /opt/keycloak/providers/ ==="
docker run --rm --entrypoint ls "${IMAGE}" -la /opt/keycloak/providers/

echo "=== ${IMAGE} /opt/keycloak/lib/quarkus + conf ==="
docker run --rm --entrypoint sh "${IMAGE}" \
    -c 'ls -la /opt/keycloak/lib/quarkus/ 2>&1 | head && ls -la /opt/keycloak/conf/ 2>&1'
