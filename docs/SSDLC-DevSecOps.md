# SSDLC & DevSecOps in Inferentia

Security in Inferentia is built into the structure, not bolted on. This document maps the platform to the Secure Software Development Lifecycle (SSDLC) and DevSecOps practices, and is **explicit about what is implemented versus what is designed-but-not-built**. Honesty about scope is part of the discipline.

**Legend:** ✅ implemented & verified · 🟡 partial / configured · 📐 designed, not built (documented as future work)

---

## The Core Idea

> Every layer produces evidence. Every gate enforces it. Every metric reports on it.

Three independent gates, each of which must pass:

1. **Build time (CI)** — is the code/artifact safe to build?
2. **Deploy time (admission)** — is the artifact safe to run?
3. **Run time** — is the running workload behaving as expected?

Compromising one gate does not bypass the others.

---

## SSDLC Phase Mapping

### Phase 1 — Planning & Requirements
| Practice | Status | Where |
|---|---|---|
| Architecture & attack surface documented | ✅ | `docs/architecture.md` |
| Security decisions as ADRs ("all images must be signed") | ✅ | `docs/decisions.md` |
| Trade-offs & scope stated honestly | ✅ | `docs/trade-offs.md` |
| Formal threat model (STRIDE/PASTA) | 📐 | future work |

### Phase 2 — Design
| Practice | Status | Where |
|---|---|---|
| Least privilege (scoped IAM, no blanket admin) | ✅ | `terraform/modules/` — GitHub OIDC + EKS Pod Identity roles |
| Network segmentation (private subnets; default-deny NetworkPolicy) | ✅ | `terraform/modules/vpc/`, `helm/charts/vllm-inference` NetworkPolicy |
| Defense in depth (multiple independent Kyverno categories) | ✅ | `policies/kyverno/` |
| Secure defaults (non-root, drop-all-caps, resource limits) | ✅ | `helm/charts/*/values.yaml` |

### Phase 3 — Implementation
| Practice | Status | Where |
|---|---|---|
| No static cloud credentials (OIDC + Pod Identity everywhere) | ✅ | CI OIDC role, model-download Job via Pod Identity |
| Dependency / base-image pinning (by digest, not `latest`) | ✅ | `containers/vllm-cpu/Dockerfile` |
| Pre-commit secret scanning + linting | ✅ | `.pre-commit-config.yaml`, `.secrets.baseline` |
| Prompt input validation / safety classifier | 📐 | designed; not built |

### Phase 4 — Testing & Verification (CI)
| Practice | Status | Where |
|---|---|---|
| Container CVE scan (Trivy, fails on CRITICAL/HIGH) | ✅ | `.github/workflows/build-and-scan.yaml` |
| IaC scan (Checkov, SARIF to Security tab) | ✅ | same workflow (soft-fail while iterating) |
| SBOM generation (Syft, SPDX JSON) | ✅ | same workflow |
| Secret scanning (Gitleaks / detect-secrets) | ✅ | pre-commit + CI |
| DAST (dynamic testing) | 📐 | needs a staging env with traffic sim |

### Phase 5 — Deployment
| Practice | Status | Where |
|---|---|---|
| Keyless image signing (Cosign / Sigstore) | ✅ | `sign-and-publish` workflow |
| Admission control rejects unsigned images | ✅ verified | `policies/kyverno/supply-chain/verify-image-signatures.yaml` (negative test blocked with 401) |
| Signed-digest promotion gate (re-verify on promote to prod) | ✅ | `.github/workflows/promotion-gate.yaml` |
| Immutable artifacts (build once, promote unchanged by digest) | ✅ | digest recorded in CI, resolved downstream |
| Progressive delivery (canary on TTFT/TPOT via Argo Rollouts) | 📐 | designed; GitOps promotion via ArgoCD is implemented, canary is not |

### Phase 6 — Operations & Monitoring
| Practice | Status | Where |
|---|---|---|
| Inference-aware metrics (TTFT/TPOT/KV-cache/throughput) | ✅ | `helm/charts/observability/` Grafana dashboard |
| Autoscaling on inference signals (KEDA) | ✅ verified | `helm/charts/observability/keda-scaledobject.yaml` |
| Audit trail (every state change is a Git commit) | ✅ | ArgoCD + Git history |
| Runtime threat detection (Falco) | 📐 | designed; not deployed |
| AI-enriched alerting (Alertmanager webhook) | 📐 | designed; not built |

### Phase 7 — Maintenance & Decommission
| Practice | Status | Where |
|---|---|---|
| Full reproducibility (rebuild from Git) | ✅ | `terraform/` + `helm/` — one apply / one destroy |
| Model versioning through the same pipeline | ✅ | Helm values + ArgoCD ApplicationSet |
| Automated dependency updates (Renovate/Dependabot) | 📐 | future work |

---

## The CI/CD Security Pipeline (shift-left)

```
Developer machine            CI (GitHub Actions)             Cluster
─────────────────           ──────────────────             ─────────

pre-commit                  PR to qa / ppd                 Admission (Kyverno)
 • Gitleaks                  • Trivy (CVE, fail HIGH/CRIT)   • image signed?
 • detect-secrets           • Checkov (IaC → SARIF)         • policy pass?
 • yaml / tf fmt            • Syft (SBOM, SPDX)             • non-root, limits?
      │                      • build once, record DIGEST         │
      ▼                      • OIDC → ECR push (keyless)         ▼
 clean commit                     │                          Runtime
                            sign-and-publish                 • Grafana SLOs
                             • Cosign keyless sign            • KEDA autoscale
                             • Rekor transparency log         • Git = audit trail
                                  │
                            promotion-gate (→ prod)
                             • re-verify signed digest
```

---

## The Three Gates

```
Gate 1 — CI (build time):     secrets scanned, CVEs checked, IaC validated, SBOM produced → PR blocked on failure
Gate 2 — Admission (deploy):  image signature verified, security policies enforced        → pod rejected on failure
Gate 3 — Runtime (run time):  SLOs monitored, autoscaling on real signals, Git audit trail → alert / drift correction
```

Verified in practice: an **unsigned** ECR image was **rejected at admission** by Kyverno (`verify-image-signatures`, `401 Unauthorized` on signature lookup). A malicious image that somehow passed CI still cannot run — the signature gate stops it.

---

## What's AI-Specific

Traditional DevSecOps doesn't cover these; Inferentia addresses them:

| Concern | Handling | Status |
|---|---|---|
| **Data leakage via prompts** | Fully self-hosted — the model runs in-cluster, no external LLM API, no data egress | ✅ |
| **Model supply chain** | Weights versioned in S3, pulled by a tracked Job via Pod Identity (not arbitrary runtime downloads) | ✅ |
| **Agent → cluster blast radius** | kagent reaches only what a least-privilege NetworkPolicy + read-only MCP tools allow | ✅ |
| **Prompt injection** | Safety classifier in front of the model | 📐 designed |
| **Cost-based DoS** | Token-rate limiting at the gateway | 📐 designed |

---

## The Evidence Chain

```
commit        → pre-commit proves no secrets      (clean commit)
CI build      → Trivy proves no critical CVEs      (scan report)
              → Syft proves the dependency set     (SBOM)
              → Cosign proves who built it          (signature + Rekor)
deploy        → Kyverno proves only signed runs     (admission log)
runtime       → Grafana proves SLOs met             (dashboards)
              → Git history proves intent            (commit log)
```

Nothing is asserted; the implemented links are evidenced. The 📐 items above are the honest boundary of what this portfolio build did **not** deploy.

---

## Honest Scope Summary

**Fully implemented & verified:** IaC least-privilege, keyless OIDC/Pod Identity (zero static creds), pre-commit + CI scanning (Trivy/Checkov/Syft/Gitleaks), Cosign signing, Kyverno admission enforcement (verified with a negative test), signed-digest promotion gate, GitOps across 4 environments, inference-aware Grafana + KEDA autoscaling, full reproducibility.

**Designed but not built (documented, not hidden):** Falco runtime detection, DAST, Argo Rollouts canary, safety classifier, AI-enriched alerting, formal threat model, automated dependency updates.

For a portfolio platform, the implemented coverage spans all three gates (build, deploy, run). The unbuilt items are named explicitly so the claims stay defensible.
