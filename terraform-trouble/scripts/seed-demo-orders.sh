#!/usr/bin/env bash
# =============================================================================
# Seed realistic demo orders through the REAL pipeline:
#     POST /api/orders  →  order-service  →  SQS  →  AI demand tracker
#
# Result: the AI Demand Forecaster shows "📊 real orders" numbers, and the
# "My Orders" view is populated too. The data is genuine (real orders processed
# by the platform), not faked into the AI.
#
# WHEN TO RUN: a few minutes BEFORE the review, AFTER the stack is healthy
# (menu + order services up). The AI demand tracker is in-memory, so if the AI
# instance restarts the counts reset — just re-run this script (~1 min).
#
# USAGE:
#   ./seed-demo-orders.sh [NUM_ORDERS] [BASE_URL]
#   ./seed-demo-orders.sh 40
#   ./seed-demo-orders.sh 40 https://xxxx.cloudfront.net   # override URL if needed
#
# The CloudFront URL is read automatically from `terraform output cloudfront_url`
# so it works after every destroy/recreate without editing this file.
# =============================================================================
set -euo pipefail

ORDERS="${1:-40}"

if [ -n "${2:-}" ]; then
  BASE="$2"
else
  INFRA_DIR="${INFRA_DIR:-$(cd "$(dirname "$0")/../infra" && pwd)}"
  DOMAIN="$(terraform -chdir="$INFRA_DIR" output -raw cloudfront_url 2>/dev/null || true)"
  [ -z "$DOMAIN" ] && { echo "ERROR: could not read cloudfront_url from terraform output." >&2; echo "Pass the URL explicitly: ./seed-demo-orders.sh $ORDERS https://<cloudfront-domain>" >&2; exit 1; }
  BASE="https://$DOMAIN"
fi

# menu_item IDs 1..22 come from V1__init_schema.sql. Popular items are repeated
# so the resulting demand curve looks realistic (some understock, some optimal).
ITEM_IDS=(1 1 5 5 5 6 7 8 13 13 13 14 17 20 20 2 9 10 11 16 18 21 22 4 12 15 19 3)
NAMES=("Aarav Sharma" "Diya Patel" "Vivaan Reddy" "Ananya Iyer" "Aditya Nair" "Ishaan Gupta" "Saanvi Rao" "Kabir Singh")

rand() { echo $(( RANDOM % $1 )); }

echo "Seeding $ORDERS orders → $BASE/api/orders"
ok=0; fail=0
for i in $(seq 1 "$ORDERS"); do
  nitems=$(( RANDOM % 4 + 1 ))           # 1-4 line items per order
  items_json=""
  for _ in $(seq 1 "$nitems"); do
    id=${ITEM_IDS[$(rand ${#ITEM_IDS[@]})]}
    qty=$(( RANDOM % 3 + 1 ))            # quantity 1-3
    [ -n "$items_json" ] && items_json+=","
    items_json+="{\"menuItemId\": $id, \"quantity\": $qty}"
  done
  name=${NAMES[$(rand ${#NAMES[@]})]}
  body="{\"customerName\":\"$name\",\"customerEmail\":\"demo${i}@example.com\",\"customerPhone\":\"90000${i}000\",\"deliveryAddress\":\"${i} MG Road, Bengaluru\",\"paymentMethod\":\"CASH_ON_DELIVERY\",\"items\":[$items_json]}"

  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/api/orders" \
           -H "Content-Type: application/json" -d "$body" || echo 000)
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then ok=$((ok+1)); else fail=$((fail+1)); echo "  order $i → HTTP $code"; fi
done

echo "----------------------------------------------------------------"
echo "Placed: $ok ok, $fail failed."
echo "Wait ~30s for the AI consumer to drain SQS, then open the AI Demand"
echo "Forecaster — rows for ordered items will flip to '📊 real orders'."
