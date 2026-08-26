# Architecture & Request Lifecycle

> This document will be expanded as each phase is built. The structure below reflects the target state.

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            AWS ACCOUNT                                    │
│                                                                          │
│  ┌─────────────┐    ┌──────────────────────────────────────────────┐    │
│  │  Route53    │    │              VPC                               │    │
│  │  + ACM      │    │                                               │    │
│  └──────┬──────┘    │  ┌─────────────────────────────────────────┐ │    │
│         │           │  │         Public Subnets                    │ │    │
│         │           │  │    ALB (AWS Load Balancer Controller)     │ │    │
│         │           │  └──────────────┬──────────────────────────┘ │    │
│         │           │                 │                             │    │
│         │           │  ┌──────────────▼──────────────────────────┐ │    │
│         │           │  │         Private Subnets                   │ │    │
│         │           │  │                                           │ │    │
│         │           │  │  ┌─────────────────────────────────────┐ │ │    │
│         │           │  │  │           EKS Cluster                │ │ │    │
│         │           │  │  │                                      │ │ │    │
│         │           │  │  │  [Control Plane Namespace]           │ │ │    │
│         │           │  │  │   ArgoCD, Kyverno, KEDA,            │ │ │    │
│         │           │  │  │   cert-manager, Prometheus           │ │ │    │
│         │           │  │  │                                      │ │ │    │
│         │           │  │  │  [Routing Namespace]                 │ │ │    │
│         │           │  │  │   Gateway API (Envoy), EPP, llm-d   │ │ │    │
│         │           │  │  │                                      │ │ │    │
│         │           │  │  │  [Inference Namespace]               │ │ │    │
│         │           │  │  │   vLLM pods, model PVC (EBS)         │ │ │    │
│         │           │  │  │                                      │ │ │    │
│         │           │  │  │  [Observability Namespace]           │ │ │    │
│         │           │  │  │   Grafana, Loki, Jaeger, OTel        │ │ │    │
│         │           │  │  └─────────────────────────────────────┘ │ │    │
│         │           │  └─────────────────────────────────────────┘ │    │
│         │           └──────────────────────────────────────────────┘    │
│         │                                                                │
│  ┌──────┴──────┐  ┌──────────┐  ┌───────────┐  ┌─────────────────┐    │
│  │     ECR     │  │ Secrets  │  │    KMS    │  │   S3 (model     │    │
│  │  (images)   │  │ Manager  │  │(encryption)│  │  artifacts)    │    │
│  └─────────────┘  └──────────┘  └───────────┘  └─────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Request Lifecycle (End-to-End)

```
Step  1: Client sends HTTPS POST to inference.inferentia.dev
Step  2: Route53 resolves → ALB IP. TLS terminated at ALB (ACM cert).
Step  3: ALB forwards to Envoy Gateway pod inside cluster.
Step  4: Envoy checks: authentication (Bearer token), rate limit (tokens/min).
Step  5: Safety classifier scans prompt for injection/harmful content.
Step  6: HTTPRoute matches → InferencePool. Envoy calls EPP via gRPC ext-proc.
Step  7: EPP runs filter → score → pick. Selects vLLM pod with best cache match.
Step  8: vLLM pod: PREFILL — tokenizes prompt, forward pass, builds KV cache. (TTFT)
Step  9: vLLM pod: DECODE — generates tokens autoregressively, one per forward pass. (TPOT)
Step 10: Tokens stream back as SSE through Envoy → ALB → Client.
Step 11: Prometheus scrapes metrics. KEDA evaluates scaling. Alerts fire if SLO breached.
```

---

## The Three Planes

| Plane | Components | Responsibility |
|-------|-----------|---------------|
| **Control** | ArgoCD, Kyverno, KEDA, cert-manager, Prometheus Operator | Declares and enforces desired state |
| **Routing** | Gateway API (Envoy), EPP, llm-d, InferencePool CRD | Cache-aware request routing |
| **Data** | vLLM pods, model weights PVC, KV cache in memory | Actual inference computation |

---

## Node Group Strategy

| Node Group | Instance Type | Workload | Scaling |
|-----------|--------------|----------|---------|
| `system` | t3.medium (2-3) | Platform tools (ArgoCD, Prometheus, Kyverno) | Fixed |
| `inference-cpu` | c5.2xlarge | vLLM pods (CPU mode) | KEDA on KV cache utilization |
| `inference-gpu` | g5.xlarge (Phase 8) | vLLM pods (GPU mode) | KEDA on KV cache utilization |

---

## Security Layers

```
Layer 1 — CI (build-time):     Gitleaks, Checkov, Trivy, Syft, Cosign
Layer 2 — Admission (deploy):  Kyverno (signed? SBOM? limits? no-privilege?)
Layer 3 — Runtime (run-time):  Falco (syscalls, network, file access)
Layer 4 — Inference-specific:  Prompt safety classifier, token rate limits
```

---

## Detailed Sections

> Each section below will be filled as the corresponding phase is completed.

### Phase 1: Infrastructure (Terraform + EKS)

_To be documented after implementation._

### Phase 2: Baseline Inference (vLLM)

_To be documented after implementation._

### Phase 3: Routing Plane (llm-d + Gateway API)

_To be documented after implementation._

### Phase 4: Observability Stack

_To be documented after implementation._

### Phase 5: GitOps (ArgoCD + Argo Rollouts)

_To be documented after implementation._

### Phase 6: Security Gates

_To be documented after implementation._

### Phase 7: Autoscaling + Alerting

_To be documented after implementation._
