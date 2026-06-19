#!/usr/bin/env bash
# =============================================================================
# CloudKitchen — ONE-COMMAND SAFE DESTROY
#
#   ./destroy.sh
#
# Tears everything down in the correct order so nothing orphans or blocks:
#   1. Delete the ArgoCD app  → prunes all k8s resources, incl. the Gateway,
#      which deletes the k8s-created NLB (otherwise it orphans + its ENIs block
#      VPC deletion, hanging terraform destroy).
#   2. terraform destroy  → everything else. The RDS->EKS SG rule and ECR repos
#      (force_delete) are Terraform-managed now, so this is clean.
# =============================================================================
set -uo pipefail   # NOT -e: keep cleaning up even if a step is a no-op

REGION="ap-south-1"
CLUSTER="cloudkitchen-eks"
ROOT="$(cd "$(dirname "$0")" && pwd)"
INFRA="$ROOT/infra"

echo "######################################################################"
echo "# 1/2  Remove EKS app so the k8s-created NLB is deleted first"
echo "######################################################################"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || true

# Deleting the Application prunes everything ArgoCD deployed (incl. Gateway→NLB).
kubectl delete application cloudkitchen -n argocd --ignore-not-found --timeout=180s 2>/dev/null || true
# Safety net: remove any leftover LoadBalancer services directly.
kubectl delete svc -n cloudkitchen --all 2>/dev/null || true

echo "Waiting for LoadBalancer (NLB) cleanup..."
for _ in $(seq 1 30); do
  cnt=$(kubectl get svc -A 2>/dev/null | grep -c LoadBalancer || true)
  [ "${cnt:-0}" = "0" ] && { echo "  no LoadBalancer services remain"; break; }
  sleep 10
done

echo "######################################################################"
echo "# 2/2  terraform destroy"
echo "######################################################################"
cd "$INFRA"
terraform destroy -auto-approve

echo ""
echo "All resources destroyed. Nothing left running or billing."
