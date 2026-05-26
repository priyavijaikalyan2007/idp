#!/bin/bash

set -e  # Exit on error

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: monitor.sh
# 📜 PURPOSE: Dumps the most recent loud Run service logs for the Knobby Auth application
# ----------------------------------------------------------------------------

PROJECT_ID="stellar-zoo-478023-v4"
REGION="asia-southeast1"
SERVICE_NAME="knobbyauth"

echo "====================================================================================="
echo "=== Dumping logs ==="

gcloud run services logs read ${SERVICE_NAME} --region=${REGION} --limit=1000
