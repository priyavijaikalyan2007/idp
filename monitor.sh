#!/bin/bash

set -e  # Exit on error

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: monitor.sh
# 📜 PURPOSE: Streams live Cloud Run service logs for the Knobby.io application
# ----------------------------------------------------------------------------

PROJECT_ID="stellar-zoo-478023-v4"
REGION="asia-southeast1"
SERVICE_NAME="knobbyauth"

echo "====================================================================================="
echo "=== Starting log streaming ==="
gcloud alpha run services logs tail ${SERVICE_NAME} \
  --region=${REGION}
