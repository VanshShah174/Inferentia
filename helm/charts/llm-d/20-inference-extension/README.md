# 20 — Gateway API Inference Extension (upstream)

Two upstream dependencies, applied before our routing CRs (`30-routing/`):

## 1. Inference Extension CRDs (pinned, vendored)

`crds.yaml` is the pinned v1.6.0 release manifest
(`kubernetes-sigs/gateway-api-inference-extension`), containing:
- `InferencePool` (`inference.networking.k8s.io/v1`) — stable
- `InferencePoolImport` (`inference.networking.x-k8s.io/v1alpha1`)

```bash
kubectl apply -f 20-inference-extension/crds.yaml
```

## 2. Gateway API + a controller that supports the Inference Extension

The Inference Extension needs (a) the base Gateway API CRDs and (b) a Gateway
controller that understands `InferencePool` backends. We use **kgateway**
(purpose-built for this, lighter than full Istio).

```bash
# Base Gateway API CRDs (standard channel, pinned)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# kgateway (Helm) with the inference-extension feature enabled
helm upgrade --install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version v2.0.3 --namespace kgateway-system --create-namespace
helm upgrade --install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version v2.0.3 --namespace kgateway-system \
  --set inferenceExtension.enabled=true
```

This creates the `kgateway` GatewayClass that `30-routing/gateway.yaml`
references. (Alternative: Istio — then set `gatewayClassName: istio`.)

## Notes / friction (per the runbook, this is the hardest step)

- Versions must line up: Inference Extension v1.6.0 ↔ kgateway build that
  supports `inference.networking.k8s.io/v1`. If the pool stays `NotAccepted`,
  check the controller version supports the v1 (not v1alpha2) pool API.
- The Gateway gets an external LB address on EKS; for the demo we can
  `kubectl port-forward` the gateway Service instead of waiting for the LB.
