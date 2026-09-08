# llm-d — Cache-Aware Inference Routing (Gateway API Inference Extension)

Demonstrates **prefix-cache-aware routing** for vLLM on Kubernetes: instead of
round-robin, an **Endpoint Picker (EPP)** routes each request to the vLLM
replica whose KV cache already holds the request's prefix — 10-20x faster TTFT
on a cache hit (see `docs/kv-cache-and-routing.md`).

Runs against the REAL production workload (`inference-prod`, 2 co-located
replicas) — the point is to prove cache-aware routing on the promoted, signed
prod deployment, not a synthetic pool. Applied directly (kubectl), NOT via
ArgoCD — same convention as `helm/charts/observability` (cluster infra).

## Components

```
Client → Gateway(:80) → HTTPRoute → InferencePool ──selects──▶ vLLM pod A   (the pool:
                             │                                 vLLM pod B    2 identical
                             └── endpointPickerRef ──▶ EPP  ───────────────  model servers)
```

- **InferencePool** (`inference.networking.k8s.io/v1`, v1.6.0) — the CR that
  groups the vLLM pods (by label) and points at the EPP.
- **EPP** — the endpoint picker: per request, scores each pod by prefix-cache
  match + load, picks the best one.
- **Gateway + HTTPRoute** — the ingress path that hands traffic to the pool.

## Apply order (numeric prefixes enforce it)

```
# 0. Namespace
kubectl apply -f 00-namespace.yaml

# 1. The model-server pool (2 vLLM replicas of the SAME signed image + model)
kubectl apply -f 10-model-servers/

# 2. UPSTREAM: Gateway API Inference Extension CRDs (v1.6.0) + a Gateway
#    controller (Istio or kgateway). See 20-inference-extension/README.md
kubectl apply -f 20-inference-extension/crds.yaml

# 3. OUR routing: EPP + InferencePool + Gateway + HTTPRoute
kubectl apply -f 30-routing/
```

## Demo (prefix-cache routing)

Two requests share the SAME system prompt. The 2nd should route to the replica
whose KV cache is already warm — lower TTFT + a prefix_cache_hits increment.

```bash
GW=<gateway-address>
# (1) cold
curl -s -o /dev/null -w "TTFT: %{time_starttransfer}s\n" -X POST http://$GW/v1/chat/completions \
  -H 'Content-Type: application/json' --data @traffic/prefix-a.json
# (2) same system prefix, different question -> warm replica
curl -s -o /dev/null -w "TTFT: %{time_starttransfer}s\n" -X POST http://$GW/v1/chat/completions \
  -H 'Content-Type: application/json' --data @traffic/prefix-b.json
```

Pinned: Gateway API Inference Extension **v1.6.0**
(`inference.networking.k8s.io/v1`). EPP image
`registry.k8s.io/gateway-api-inference-extension/epp:v1.6.0`.
