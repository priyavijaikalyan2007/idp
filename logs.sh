#!/bin/bash

set -e  # Exit on error

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: monitor.sh
# 📜 PURPOSE: Dumps the most recent loud Run service logs for the YourApp Auth application
# ----------------------------------------------------------------------------

PROJECT_ID="your-gcp-project-id"
REGION="your-region"
SERVICE_NAME="your-keycloak-service"

echo "====================================================================================="
echo "=== Dumping logs ==="

gcloud run services logs read ${SERVICE_NAME} --region=${REGION} --limit=1000
