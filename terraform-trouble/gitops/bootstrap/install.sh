#!/usr/bin/env bash
# =============================================================================
# CloudKitchen EKS platform bootstrap (run ONCE per cluster)
#
# Installs, in order:
#   1. Gateway API CRDs        (the Gateway/HTTPRoute resource types)
#   2. kgateway                (Envoy-based Gateway API implementation)
#   3. ArgoCD                  (GitOps controller)
#
# The AWS NLB is created automatically by the in-tree cloud provider when
# kgateway's Gateway asks for a LoadBalancer Service — no extra controller
# needed (see the optional AWS Load Balancer Controller section at the bottom).
#
# Prereqs: kubectl, helm, aws — and kubeconfig pointed at the cluster:
#   aws eks update-kubeconfig --name cloudkitchen-eks --region ap-south-1
# =============================================================================
set -euo pipefail

GATEWAY_API_VERSION="v1.2.0"
KGATEWAY_VERSION="v2.0.0"

echo "==> 1/3  Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> 2/3  Installing kgateway (${KGATEWAY_VERSION})..."
helm upgrade -i kgateway-crds \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version "${KGATEWAY_VERSION}" \
  --namespace kgateway-system --create-namespace
helm upgrade -i kgateway \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version "${KGATEWAY_VERSION}" \
  --namespace kgateway-system
echo "    waiting for kgateway control plane..."
kubectl -n kgateway-system rollout status deploy/kgateway --timeout=180s || true

echo "==> 3/3  Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "    waiting for ArgoCD server..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s || true

cat <<'EOF'

============================================================================
Platform ready. Next steps:

1. Create the runtime secret (NOT in git — see README §4):
     kubectl create secret generic cloudkitchen-secrets \
       --namespace cloudkitchen \
       --from-literal=SPRING_DATASOURCE_URL="jdbc:postgresql://<rds>:5432/cloudkitchen" \
       --from-literal=SPRING_DATASOURCE_USERNAME="postgres" \
       --from-literal=SPRING_DATASOURCE_PASSWORD="<password>" \
       --from-literal=HUGGINGFACEHUB_API_TOKEN="<hf-token>"
   (create the namespace first: kubectl create namespace cloudkitchen)

2. Hand the app to ArgoCD:
     kubectl apply -f ../argocd/project.yaml
     kubectl apply -f ../argocd/application.yaml

3. Get the NLB DNS for the CloudFront /api/* and /auth/* origins:
     kubectl get gateway cloudkitchen-gateway -n cloudkitchen \
       -o jsonpath='{.status.addresses[0].value}{"\n"}'

4. ArgoCD admin password:
     kubectl -n argocd get secret argocd-initial-admin-secret \
       -o jsonpath='{.data.password}' | base64 -d; echo
============================================================================
EOF

# -----------------------------------------------------------------------------
# OPTIONAL: AWS Load Balancer Controller (production-grade NLB via IRSA)
# Only needed if you switch gateway.lbAnnotations to the "external"/"ip" mode.
# Requires an OIDC provider on the cluster + an IRSA role. Easiest via eksctl:
#
#   eksctl utils associate-iam-oidc-provider --cluster cloudkitchen-eks \
#     --region ap-south-1 --approve
#   # create IAM policy + IRSA service account, then:
#   helm repo add eks https://aws.github.io/eks-charts
#   helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
#     -n kube-system --set clusterName=cloudkitchen-eks \
#     --set serviceAccount.create=false \
#     --set serviceAccount.name=aws-load-balancer-controller
# -----------------------------------------------------------------------------
