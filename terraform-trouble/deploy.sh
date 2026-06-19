#!/usr/bin/env bash
# =============================================================================
# CloudKitchen — ONE-COMMAND FULL DEPLOY  (infra + EKS app via ArgoCD)
#
#   ./deploy.sh
#
# Brings up everything from scratch:
#   1. Terraform: VPC, RDS, ALB, ASGs (EC2 app), CloudFront, SQS, Lambda, ECR,
#      EKS cluster, AI image build, RDS->EKS SG rule, frontend deploy
#   2. Builds + pushes the 3 Java service images to ECR
#   3. Installs the EKS platform: Gateway API CRDs + kgateway + ArgoCD
#   4. Loads per-deploy runtime config (DB/Cognito/SQS/HF) into the cluster
#   5. Hands the app to ArgoCD (GitOps sync)
#
# PREREQUISITES on this machine: terraform, aws CLI (configured), docker
# (running), kubectl, git. helm is auto-installed locally if missing.
# =============================================================================
set -euo pipefail

REGION="ap-south-1"
CLUSTER="cloudkitchen-eks"
ACCOUNT="256603361470"
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
ROOT="$(cd "$(dirname "$0")" && pwd)"
INFRA="$ROOT/infra"
GITOPS="$ROOT/gitops"

# ── Preflight: fail fast with clear messages instead of hanging mid-deploy ──
echo "Preflight checks..."
command -v terraform >/dev/null || { echo "ERROR: terraform not installed."; exit 1; }
command -v aws       >/dev/null || { echo "ERROR: aws CLI not installed."; exit 1; }
command -v kubectl   >/dev/null || { echo "ERROR: kubectl not installed."; exit 1; }
docker info >/dev/null 2>&1     || { echo "ERROR: Docker is not running (needed to build the service images)."; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: AWS credentials not configured (run 'aws configure')."; exit 1; }
[ -f "$INFRA/terraform.tfvars" ] || { echo "ERROR: $INFRA/terraform.tfvars is missing. It is gitignored (holds hf_api_token, key_name, AMI ids). Copy it onto this machine before deploying."; exit 1; }
echo "Preflight OK."

echo "######################################################################"
echo "# 1/5  Terraform apply (infra + EKS cluster + AI image)"
echo "######################################################################"
cd "$INFRA"
terraform init -input=false
terraform apply -auto-approve

echo "######################################################################"
echo "# 2/5  Build + push the 3 Java service images (AI built by Terraform)"
echo "######################################################################"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"
for s in menu order auth; do
  echo "--- $s ---"
  docker build -t "$ECR/cloudkitchen-$s-repo:latest" "$ROOT/services/$s-service"
  docker push "$ECR/cloudkitchen-$s-repo:latest"
done

echo "######################################################################"
echo "# 3/5  Connect kubectl + install EKS platform (kgateway + ArgoCD)"
echo "######################################################################"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

# ensure helm exists (install locally if missing)
if ! command -v helm >/dev/null 2>&1 && [ ! -x "$HOME/bin/helm.exe" ]; then
  echo "Installing helm locally..."
  curl -fsSL https://get.helm.sh/helm-v3.16.3-windows-amd64.zip -o /tmp/helm.zip
  unzip -oq /tmp/helm.zip -d /tmp && mkdir -p "$HOME/bin" && cp /tmp/windows-amd64/helm.exe "$HOME/bin/helm.exe"
fi
export PATH="$HOME/bin:$PATH"

bash "$GITOPS/bootstrap/install.sh"

echo "######################################################################"
echo "# 4/5  Load per-deploy runtime config (DB/Cognito/SQS/HF) from live AWS"
echo "######################################################################"
bash "$GITOPS/bootstrap/load-runtime-config.sh"

echo "######################################################################"
echo "# 5/5  Hand the app to ArgoCD (GitOps)"
echo "######################################################################"
kubectl apply -f "$GITOPS/argocd/project.yaml"
kubectl apply -f "$GITOPS/argocd/application.yaml"

echo ""
echo "======================================================================"
echo "DONE. ArgoCD will sync the app from GitHub in ~1-2 min."
echo ""
echo "  App health:   kubectl get application cloudkitchen -n argocd"
echo "  Pods:         kubectl get pods -n cloudkitchen"
echo "  EKS NLB:      kubectl get gateway cloudkitchen-gateway -n cloudkitchen -o jsonpath='{.status.addresses[0].value}'"
echo "  EC2 site:     terraform -chdir=$INFRA output cloudfront_url"
echo "  ArgoCD UI:    kubectl port-forward svc/argocd-server -n argocd 8080:443  (https://localhost:8080)"
echo "======================================================================"
