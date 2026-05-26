#!/bin/bash

set -e  # Exit on error

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: monitor.sh
# 📜 PURPOSE: Streams live Cloud Run service logs for the yourapp.com application
# ----------------------------------------------------------------------------

PROJECT_ID="your-gcp-project-id"
REGION="your-region"
SERVICE_NAME="yourappauth"

echo "====================================================================================="
echo "=== Starting log streaming ==="
gcloud alpha run services logs tail ${SERVICE_NAME} \
  --region=${REGION}
