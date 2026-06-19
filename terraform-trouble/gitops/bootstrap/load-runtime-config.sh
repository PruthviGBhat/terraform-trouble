#!/usr/bin/env bash
# =============================================================================
# Load per-deploy runtime config into the cluster (run ONCE after every
# `terraform apply`, before/with the ArgoCD sync).
#
# Pulls the values that change on every destroy/recreate straight from live AWS
# and writes them into the out-of-band Secret `cloudkitchen-secrets`. NOTHING
# environment-specific is hardcoded in Git — Cognito pool/client IDs regenerate
# each recreate, the RDS host changes, etc., and this always fetches the fresh
# ones.
#
# USAGE:  ./load-runtime-config.sh
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
NS="cloudkitchen"
INFRA="${INFRA_DIR:-$(cd "$(dirname "$0")/../../infra" && pwd)}"

echo "Reading dynamic values from AWS / terraform outputs..."

# Cognito pool IDs from terraform outputs → client IDs from Cognito (all fresh)
USER_POOL=$(terraform -chdir="$INFRA" output -raw cognito_user_pool_id)
REST_POOL=$(terraform -chdir="$INFRA" output -raw cognito_restaurant_pool_id)
USER_CLIENT=$(aws cognito-idp list-user-pool-clients --user-pool-id "$USER_POOL" --region "$REGION" --query 'UserPoolClients[0].ClientId' --output text)
REST_CLIENT=$(aws cognito-idp list-user-pool-clients --user-pool-id "$REST_POOL" --region "$REGION" --query 'UserPoolClients[0].ClientId' --output text)

SQS_URL=$(terraform -chdir="$INFRA" output -raw sqs_orders_queue_url)

# DB credentials from Secrets Manager (RDS host changes on recreate)
DB_JSON=$(aws secretsmanager get-secret-value --secret-id cloudkitchen/db/credentials-new --region "$REGION" --query SecretString --output text)
DB_HOST=$(echo "$DB_JSON" | python -c "import sys,json;print(json.load(sys.stdin)['host'])")
DB_NAME=$(echo "$DB_JSON" | python -c "import sys,json;print(json.load(sys.stdin)['dbname'])")
DB_USER=$(echo "$DB_JSON" | python -c "import sys,json;print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$DB_JSON" | python -c "import sys,json;print(json.load(sys.stdin)['password'])")

# HF token from tfvars (gitignored; same source the EC2/Lambda use)
HF=$(grep hf_api_token "$INFRA/terraform.tfvars" | sed 's/.*= *"//; s/".*//')

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cloudkitchen-secrets -n "$NS" \
  --from-literal=SPRING_DATASOURCE_URL="jdbc:postgresql://$DB_HOST:5432/$DB_NAME" \
  --from-literal=SPRING_DATASOURCE_USERNAME="$DB_USER" \
  --from-literal=SPRING_DATASOURCE_PASSWORD="$DB_PASS" \
  --from-literal=HUGGINGFACEHUB_API_TOKEN="$HF" \
  --from-literal=SQS_ORDERS_QUEUE_URL="$SQS_URL" \
  --from-literal=USER_POOL_ID="$USER_POOL" \
  --from-literal=USER_CLIENT_ID="$USER_CLIENT" \
  --from-literal=RESTAURANT_POOL_ID="$REST_POOL" \
  --from-literal=RESTAURANT_CLIENT_ID="$REST_CLIENT" \
  --dry-run=client -o yaml | kubectl apply -f -

# Roll pods so they pick up the refreshed secret
kubectl rollout restart deployment -n "$NS" 2>/dev/null || true

echo "Runtime config loaded into cloudkitchen-secrets and pods restarted."
