#!/bin/bash

# Konfiguracja
API_URL="http://localhost:8000"
SERVICE_NAME="example-service"
SUBDOMAIN="api"  # Zostanie połączone z DOMAIN_SUFFIX z .env
GIT_REPO="https://github.com/dynapsys/install"

# 1. Deploy nowej usługi
echo "Deploying new gRPC service..."
curl -X POST "${API_URL}/deploy" \
    -H "Content-Type: application/json" \
    -d "{
        \"git_repo\": \"${GIT_REPO}\",
        \"domain\": \"${SUBDOMAIN}\",
        \"service_name\": \"${SERVICE_NAME}\"
    }"

# 2. Sprawdzenie statusu
echo -e "\nChecking service status..."
curl -s "${API_URL}/services/${SERVICE_NAME}/status" | python3 -m json.tool
