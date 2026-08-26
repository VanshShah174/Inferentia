# Inferentia

A self-hosted LLM inference platform on Kubernetes that demonstrates where standard DevOps practices apply unchanged to AI workloads and where they must be extended for a workload that batches requests on GPU, holds per-user state in VRAM, and scales on token throughput rather than request rate.

## The Thesis

> The workload changed. The discipline didn't.

LLM inference violates assumptions that general-purpose DevOps tooling was built around — stateless request handling, CPU-based scaling, uniform load balancing. Inferentia is the reference implementation showing how existing practices (GitOps, Helm, admission control, observability, progressive delivery) transfer to this workload class, and where they must be extended.

## What This Serves

A small open-weights language model (Qwen 2.5 0.5B Instruct) running inside vLLM on Amazon EKS, exposed as an OpenAI-compatible API. The model is a placeholder — the infrastructure, security, observability, and operational discipline surrounding it is the deliverable.

## Architecture Overview

```
Client → ALB → Gateway API (Envoy) → Endpoint Picker (cache-aware) → vLLM Pod → SSE stream back
                    │                        │
                    │                        └── Scores pods by KV cache prefix match
                    └── Auth, rate limit, safety classifier
```

Five layers:
1. **Serving engine** — vLLM (continuous batching, PagedAttention, OpenAI-compatible API)
2. **Routing plane** — llm-d (cache-aware routing via Gateway API Inference Extension)
3. **Kubernetes primitives** — EKS, Gateway API, Kyverno, HPA/KEDA
4. **DevOps toolchain** — Terraform, Helm, ArgoCD, Argo Rollouts, four-branch GitOps
5. **Security & observability** — Full CI pipeline, runtime policies, inference-specific SLOs

See [docs/architecture.md](docs/architecture.md) for the complete request lifecycle.

## Repository Layout

```
containers/    Dockerfiles for images we build (vLLM, alert-enricher, model-downloader)
services/      Source for supporting services (alert enricher, safety classifier)
helm/          Application deployment charts and values
manifests/     Non-Helm bootstrap Kubernetes objects (namespaces, jobs, examples)
argocd/        GitOps definitions for progressive delivery
policies/      Kyverno admission and Falco runtime rules
terraform/     Infrastructure as code — module + environment structure
scripts/       User-facing demo, load test, and setup scripts
ci/            CI-runtime helpers (scan triage, image signing, promotion gates)
docs/          Architecture, decisions, trade-offs, deployment guide
```

## Tech Stack

| Layer | Tools |
|-------|-------|
| Infrastructure | Terraform, AWS EKS, VPC, ECR, IAM (IRSA) |
| Inference | vLLM, llm-d, Gateway API Inference Extension |
| Packaging | Helm, Docker (multi-stage, pinned) |
| GitOps | ArgoCD, Argo Rollouts (canary on TTFT/TPOT) |
| CI Security | Gitleaks, Checkov, Trivy, Syft, Cosign, Claude API triage |
| Admission | Kyverno (supply chain, resource hygiene, security posture, cost/isolation) |
| Runtime | Falco, Prometheus alerts, AI-enriched Alertmanager webhook |
| Observability | Prometheus, Grafana, Loki, OpenTelemetry, Jaeger |
| Autoscaling | KEDA on KV cache utilization, HPA on request rate |

## Key Design Principles

- **Every layer produces evidence. Every gate enforces it. Every metric reports on it.**
- CI produces signed images with SBOMs. Kyverno enforces at admission. Prometheus verifies at runtime. ArgoCD ensures Git is the source of truth.
- Security is built in (SSDLC), not bolted on. Three independent gates: build-time, deploy-time, run-time.

## Branch Strategy

```
main  ← production (protected)
ppd   ← pre-production validation
qa    ← integration testing
dev   ← active development
```

Changes flow: `dev → qa → ppd → main`. ArgoCD watches each branch for its corresponding environment.

## Documentation

- [Architecture & Request Lifecycle](docs/architecture.md)
- [Architecture Decision Records](docs/decisions.md)
- [Trade-offs & Honest Limitations](docs/trade-offs.md)
- [KV Cache & Cache-Aware Routing](docs/kv-cache-and-routing.md)

## Getting Started

> Phase 0 complete. Infrastructure and deployment phases in progress.

```bash
# Clone
git clone https://github.com/VanshShah174/Inferentia.git
cd Inferentia

# Install pre-commit hooks
pip install pre-commit
pre-commit install

# Switch to dev branch for active work
git checkout dev
```

## License

[Apache-2.0](LICENSE)
