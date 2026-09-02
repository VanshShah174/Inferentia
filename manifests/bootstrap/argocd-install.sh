#!/usr/bin/env bash
# =============================================================================
# ArgoCD install — bootstrap runbook (executable)
# =============================================================================
# Per ADR-010: ArgoCD is an upstream system we CONSUME, not author. We install
# the pinned upstream release manifests, then apply OUR ApplicationSet.
#
# Prerequisites:
#   - EKS up (terraform apply on environments/platform)
#   - kubectl context set:
#       aws eks update-kubeconfig --name inferentia-eks --region ca-central-1
#   - namespaces applied:
#       kubectl apply -f manifests/bootstrap/namespaces.yaml
#
# Usage:
#   ./manifests/bootstrap/argocd-install.sh
# =============================================================================
set -euo pipefail

# Pin the version — do NOT use 'stable' in production (reproducibility).
# Verify current stable tag at https://github.com/argoproj/argo-cd/releases
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.3}"

echo ">> Installing ArgoCD ${ARGOCD_VERSION} into the 'argocd' namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo ">> Waiting for argocd-server to become available..."
kubectl wait --for=condition=available --timeout=300s \
  deploy/argocd-server -n argocd

# The ApplicationSet keeps account-specific values as SHELL placeholders
# (${AWS_ACCOUNT_ID} / ${AWS_REGION}) so no account id is committed to git.
# envsubst injects the real values here, at apply time — they land only in the
# running cluster object. AWS_ACCOUNT_ID is the same var the seed scripts use.
: "${AWS_REGION:=ca-central-1}"
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
  echo ">> AWS_ACCOUNT_ID not set; resolving via STS..."
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi
export AWS_ACCOUNT_ID AWS_REGION
echo ">> Injecting account ${AWS_ACCOUNT_ID} / region ${AWS_REGION} into the ApplicationSet..."

command -v envsubst >/dev/null 2>&1 || {
  echo "ERROR: envsubst not found (install gettext: 'apt-get install gettext-base' / 'brew install gettext')." >&2
  exit 1
}

echo ">> Applying the Inferentia ApplicationSet (generates dev/qa/ppd/prod apps)..."
# Only substitute our two vars; leave any other $... (none today) untouched.
envsubst '${AWS_ACCOUNT_ID} ${AWS_REGION}' < argocd/appsets/vllm-appset.yaml \
  | kubectl apply -f -

echo ">> Done. Applications:"
kubectl get applications -n argocd

cat <<'EOF'

Next:
  - UI:  kubectl port-forward svc/argocd-server -n argocd 8080:443
  - pw:  kubectl -n argocd get secret argocd-initial-admin-secret \
           -o jsonpath="{.data.password}" | base64 -d
         (open https://localhost:8080, user: admin)

Notes:
  - ApplicationSet uses automated sync (prune + selfHeal) -> git is source of truth.
  - CreateNamespace=false: namespaces come from manifests/bootstrap/namespaces.yaml.
  - Teardown: kubectl delete -f argocd/appsets/vllm-appset.yaml
EOF
