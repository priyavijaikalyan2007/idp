#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: test.sh
# 📜 PURPOSE: Runs the full test suite (Surefire unit + Failsafe Testcontainers
#             integration) for the Keycloak MCP SPI. Gate CI on this script.
# 🔗 RELATES: [[build.sh]], [[deploy.sh]]
# ⚡ FLOW: [./test.sh] -> [mvn verify in src/providers] -> [Surefire + Failsafe]
# ----------------------------------------------------------------------------

# Runs the full test suite for the Knobby Keycloak MCP SPI:
#   - Surefire (unit tests):    src/providers/src/test/java/.../*Test.java
#   - Failsafe (integration):   src/providers/src/test/java/.../*IT.java
#
# The Testcontainers integration tests require Docker on the build host (they
# spin up Keycloak 26.6.0 to verify the JAR loads and the SPIs register).
#
# Gate CI on this script before pushing or deploying.

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "=== Running Knobby Keycloak MCP SPI tests ==="
(cd "${SCRIPT_DIR}/src/providers" && mvn -B -ntp clean verify)

echo ""
echo "=== Tests complete ==="
