# Architecture Decision Records

This document captures significant technical decisions made during the design and implementation of Inferentia. Each entry records what was decided, what alternatives existed, and why the chosen path was selected.

---

## ADR-001: Amazon EKS as the Deployment Target

**Date:** 2024-06-01

**Status:** Accepted

**Context:**

Inferentia needs a Kubernetes environment to run the inference workload. The options range from local development clusters to fully managed cloud offerings. The project's goal is to demonstrate production-grade operational discipline — the environment must be realistic enough that the practices transfer directly to a real team's infrastructure.

**Alternatives Considered:**

| Option | Pros | Cons |
|--------|------|------|
| kind (local) | Free, fast iteration, no cloud account needed | Not production-realistic. No real IAM, networking, or storage. Reviewers would question whether the skills transfer. |
| Self-managed K8s on EC2 | Full control, demonstrates deep K8s knowledge | Maintenance burden distracts from the project's actual thesis (inference operations, not cluster bootstrapping). |
| GKE (Google) | Excellent K8s integration, Autopilot mode | AWS is dominant in enterprise; EKS skills are more broadly applicable for target roles. |
| AKS (Azure) | Good managed offering | Smaller market share for the roles this project targets. |
| **Amazon EKS** | Industry standard for enterprise. Real VPC, IAM, ALB, ECR integration. Skills transfer directly to production teams. | Costs money (~$150-300/month for a dev cluster). Requires AWS account and credential management. |

**Decision:**

Amazon EKS as the primary deployment target.

**Rationale:**

1. **Market relevance** — EKS is the most widely adopted managed Kubernetes in enterprise. Skills demonstrated here transfer directly to the roles this project targets.
2. **Real infrastructure** — VPC networking, IRSA, ALB, ECR, Secrets Manager, EBS CSI — all become real, not simulated. Reviewers can see these are genuine integrations, not local hacks.
3. **Security story becomes concrete** — IRSA (IAM Roles for Service Accounts) provides actual least-privilege identity. VPC provides actual network isolation. KMS provides actual encryption. None of these exist on kind.
4. **Cost is manageable** — Dev cluster can be provisioned/destroyed via Terraform as needed. Not a permanent spend.
5. **GPU portability proven** — EKS supports GPU node groups (g5.xlarge). The same manifests port to real GPU inference by changing three values — verifiable claim.

**Consequences:**

- Terraform modules must be built for VPC, EKS, ECR, and IAM
- AWS credentials management becomes a concern (handled via SSO or IAM Identity Center)
- Cost tracking is needed (tagging strategy in Terraform)
- Local development requires either a remote cluster or a kind fallback for fast iteration

---

## ADR-002: vLLM as the Inference Engine

**Date:** 2024-06-01

**Status:** Accepted

**Context:**

Multiple inference engines exist for serving LLMs. The choice affects performance, API compatibility, and operational characteristics.

**Alternatives Considered:**

| Option | Pros | Cons |
|--------|------|------|
| **vLLM** | PagedAttention, continuous batching, OpenAI-compatible API, best throughput benchmarks, active community | Heavier than simpler options, Python-based |
| TGI (HuggingFace) | Good HF integration, simple setup | Less flexible routing, no PagedAttention equivalent at same maturity |
| Ollama | Simple, good developer UX | Not production-grade, no batch scheduling, limited metrics |
| TensorRT-LLM (NVIDIA) | Best raw GPU performance | NVIDIA-only, complex setup, less community support |
| llama.cpp | CPU-optimized, lightweight | No continuous batching, limited concurrent request handling, no native metrics |

**Decision:**

vLLM as the single-node inference engine.

**Rationale:**

1. **PagedAttention** — Enables efficient KV cache memory management, directly relevant to our scaling story
2. **OpenAI-compatible API** — Any existing tooling (LangChain, SDKs) works without modification
3. **Continuous batching** — Multiple concurrent requests share the model, critical for utilization
4. **Rich metrics endpoint** — Exposes TTFT, TPOT, KV cache utilization natively via Prometheus format
5. **llm-d integration** — llm-d's EPP is designed to work with vLLM's prefix caching and metrics

**Consequences:**

- Container image is Python-based (larger, slower build)
- CPU mode works but is significantly slower than GPU (acceptable for demonstrating architecture)
- Memory requirements are higher than llama.cpp (need appropriately sized nodes)

---

## ADR-003: llm-d for Cache-Aware Routing

**Date:** 2024-06-01

**Status:** Accepted

**Context:**

Standard Kubernetes Services use round-robin or random load balancing. For inference workloads, this destroys KV cache locality — the single biggest performance differentiator for multi-turn conversations.

**Alternatives Considered:**

| Option | Pros | Cons |
|--------|------|------|
| Standard K8s Service | Simple, no extra components | Round-robin routing, no cache awareness, 10-20x worse TTFT on cache miss |
| Custom routing controller | Full control, minimal dependencies | Have to build and maintain it ourselves, not credible as production reference |
| Istio with custom WASM | Powerful service mesh | Massive overhead for a routing decision, overkill |
| **llm-d** | Purpose-built for LLM routing, uses Gateway API Inference Extension CRDs, cache-aware EPP | Newer project, less community maturity |

**Decision:**

llm-d as the Kubernetes-native routing layer.

**Rationale:**

1. **Cache-aware routing** — The EPP's filter → score → pick pipeline directly addresses the core operational challenge of inference workloads
2. **Gateway API native** — Uses standard CRDs (InferencePool, InferenceObjective), not proprietary APIs
3. **Disaggregated serving support** — Prefill/decode pool separation is architecturally documented even if not exercised in CPU mode
4. **The project's thesis** — Demonstrating purpose-built inference routing is the single strongest differentiator from "I deployed a container"

**Consequences:**

- Additional Helm releases to manage (router + modelservice)
- Dependency on a newer project (acceptable for demonstration purposes)
- Gateway API CRDs must be installed before llm-d

---

## ADR-004: Four-Branch Promotion Model

**Date:** 2024-06-01

**Status:** Accepted

**Context:**

The project needs a branching strategy that maps to environment promotion and ArgoCD deployment targets.

**Decision:**

Four branches: `dev` → `qa` → `ppd` → `main` (prod). Each branch maps to an ArgoCD-watched environment.

**Rationale:**

1. Mirrors enterprise workflows where code is validated at each stage before reaching production
2. ArgoCD ApplicationSets can target branches, making the GitOps story concrete
3. Branch protection rules enforce the promotion process (no direct push to main/ppd)
4. Demonstrates the operational discipline of progressive promotion

**Consequences:**

- PRs required for promotion (slightly slower for solo development)
- ArgoCD needs per-environment Application or ApplicationSet configs
- pre-commit hook blocks direct commits to `main` and `ppd`

---

## Template for Future ADRs

```markdown
## ADR-NNN: [Title]

**Date:** YYYY-MM-DD

**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-NNN

**Context:**
[What is the situation? What forces are at play?]

**Alternatives Considered:**
[What options exist?]

**Decision:**
[What was chosen?]

**Rationale:**
[Why this option over others?]

**Consequences:**
[What follows from this decision? Both positive and negative.]
```
