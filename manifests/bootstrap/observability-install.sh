#!/usr/bin/env bash
# =============================================================================
# Observability install — bootstrap runbook (executable)
# =============================================================================
# Tier 1: Metrics + dashboards + alerting + KV-cache autoscaling.
#   - kube-prometheus-stack (Prometheus + Alertmanager + Grafana)  [upstream]
#   - KEDA (event-driven autoscaling on Prometheus metrics)        [upstream]
#   - OUR: vLLM Grafana dashboard, PrometheusRule alerts, KEDA ScaledObject
#
# Logs are handled by CloudWatch (see note at the bottom) — no Loki (deferred).
# Tracing (OTel + Jaeger/Tempo) is deferred until llm-d creates a multi-hop path.
#
# Prereqs: EKS up, kubectl context set, gp3 StorageClass present (EBS CSI addon).
# Usage:   ./manifests/bootstrap/observability-install.sh
# =============================================================================
set -euo pipefail

# Pin chart versions (reproducibility). Verify latest on ArtifactHub.
KPS_CHART_VERSION="${KPS_CHART_VERSION:-65.5.1}"   # kube-prometheus-stack
KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.15.1}" # keda

OBS_DIR="helm/charts/observability"

echo ">> Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

echo ">> Installing kube-prometheus-stack ${KPS_CHART_VERSION} (namespace monitoring)..."
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version "${KPS_CHART_VERSION}" \
  -f "${OBS_DIR}/kube-prometheus-stack-values.yaml" \
  --wait

echo ">> Installing KEDA ${KEDA_CHART_VERSION} (namespace keda)..."
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version "${KEDA_CHART_VERSION}" \
  --wait

echo ">> Loading the vLLM Grafana dashboard (ConfigMap, picked up by sidecar)..."
kubectl create configmap vllm-dashboard \
  --namespace monitoring \
  --from-file="${OBS_DIR}/dashboards/vllm-dashboard.json" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -

echo ">> Applying vLLM alert rules..."
kubectl apply -f "${OBS_DIR}/prometheus-rules.yaml"

echo ">> Applying KEDA ScaledObject (prod)..."
# NOTE: set autoscaling.enabled=false in values-prod.yaml so the chart HPA does
# NOT fight KEDA over the same Deployment.
kubectl apply -f "${OBS_DIR}/keda-scaledobject.yaml"

echo ">> Done."
cat <<'EOF'

Access Grafana:
  kubectl port-forward svc/kube-prom-stack-grafana -n monitoring 3000:80
  # user: admin  (password from values / secret)
  # open http://localhost:3000 -> dashboard "vLLM Inference — TTFT / TPOT / KV Cache"

CloudWatch (logs — no extra stack):
  On EKS, enable Container Insights / the CloudWatch agent so pod stdout + node
  metrics flow to CloudWatch. This covers the LOGS pillar without running Loki.
  (Loki and OTel+Jaeger tracing are deliberately deferred — see the design doc.)
EOF
