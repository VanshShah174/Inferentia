#!/usr/bin/env bash
# =============================================================================
# Kyverno install — bootstrap runbook (executable)
# =============================================================================
# Per ADR-010: Kyverno is an upstream system we CONSUME, not author. Install the
# pinned upstream Helm chart, then apply OUR policies.
#
# ORDER MATTERS: Kyverno (the admission controller) must be running BEFORE the
# workloads it should govern. Install it early in cluster bootstrap — before
# (or right alongside) ArgoCD deploys the inference apps — so unsigned/insecure
# pods are rejected from day one, not retroactively.
#
# Prerequisites:
#   - EKS up + kubectl context set
#     aws eks update-kubeconfig --name inferentia-eks --region ca-central-1
#
# Usage:
#   ./manifests/bootstrap/kyverno-install.sh
# =============================================================================
set -euo pipefail

# Pin the chart version (reproducibility). Verify latest at:
# https://artifacthub.io/packages/helm/kyverno/kyverno
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.3.4}"

echo ">> Adding Kyverno Helm repo..."
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

echo ">> Installing Kyverno ${KYVERNO_CHART_VERSION} into namespace 'kyverno'..."
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version "${KYVERNO_CHART_VERSION}" \
  --wait

echo ">> Waiting for the admission controller to be ready..."
kubectl wait --for=condition=available --timeout=300s \
  deploy -l app.kubernetes.io/component=admission-controller -n kyverno

echo ">> Applying Inferentia policies..."
# Supply-chain: reject unsigned inference images
kubectl apply -f policies/kyverno/supply-chain/
# Pod security posture: non-root, no priv-esc, drop caps, no privileged
kubectl apply -f policies/kyverno/security-posture/
# Resource hygiene: requests/limits, probes, standard labels
kubectl apply -f policies/kyverno/resource-hygiene/
# Cost governance: require cost-center label
kubectl apply -f policies/kyverno/cost-isolation/

echo ">> Installed policies:"
kubectl get clusterpolicies

cat <<'EOF'

Notes:
  - Policies use validationFailureAction: Enforce (block on violation).
    To OBSERVE before enforcing, switch to Audit and watch PolicyReports:
      kubectl get policyreport -A
  - verify-image-signatures needs registry (ECR) + Sigstore reachability at
    admission; it only governs *.dkr.ecr.ca-central-1.amazonaws.com/inferentia/*.
  - Test enforcement: try to run an unsigned image in inference-dev; it should
    be rejected at admission.
EOF
