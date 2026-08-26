# Trade-offs & Honest Limitations

This document names what Inferentia does not do, why each limitation exists, and what would concretely change to bridge each gap. Being explicit about boundaries is the most credible thing a portfolio project can do.

---

## 1. CPU-Only Inference (No GPU in Main Branch)

**What's limited:** The main branch runs vLLM on CPU nodes (c5/m5 instance types). Inference is significantly slower than GPU — TTFT and TPOT are 10-50x worse than production GPU workloads.

**Why:** GPU instances cost $1-4/hour. Keeping the main branch CPU-only means the project can be reproduced and validated without a $500+ cloud bill. The architecture, routing, observability, and security layers are identical regardless of compute backend.

**What changes for GPU:**
1. Node group instance type: `c5.2xlarge` → `g5.xlarge`
2. Resource request: `cpu: "4"` → `nvidia.com/gpu: "1"`
3. Model size: Qwen 0.5B → Llama-3.2-3B or larger
4. NVIDIA device plugin DaemonSet installed
5. vLLM container uses CUDA-enabled base image

**Evidence:** Phase 8 (optional) verifies this on a real g5.xlarge with the same manifests and documents the three changes.

---

## 2. Single-Region Deployment

**What's limited:** Everything runs in a single AWS region (us-east-1). No cross-region failover, no global load balancing.

**Why:** Multi-region adds complexity (data replication, conflict resolution, global DNS routing) that is orthogonal to the project's thesis about inference-specific operations.

**What changes for multi-region:**
- Route53 latency-based routing across regions
- EKS cluster per region with ArgoCD multi-cluster management
- Model weights stored in S3 with cross-region replication
- Global Accelerator or CloudFront for edge routing
- KV cache is inherently per-pod/per-region (no cross-region cache sharing)

---

## 3. No Production-Scale Traffic Validation

**What's limited:** Load testing is performed on a small cluster (2-4 inference pods). Results demonstrate that autoscaling works, not that it works at 10,000 concurrent users.

**Why:** Production-scale load testing requires many large nodes running simultaneously, which is cost-prohibitive for a portfolio project. The patterns (KEDA scaling, EPP routing, Argo Rollouts canary) are identical at any scale — only the numbers change.

**What changes for production scale:**
- Larger node groups (10-50 inference nodes)
- Karpenter for rapid node provisioning (not just managed node groups)
- Dedicated load-testing infrastructure (distributed k6, separate VPC)
- Capacity planning based on token throughput modeling
- Queue-based admission when all pods are saturated

---

## 4. No Multi-Tenancy Isolation

**What's limited:** Single-tenant deployment. One namespace, one model, one set of users. No tenant-level quotas, billing separation, or data isolation.

**Why:** Multi-tenancy is a product concern, not an infrastructure demonstration. Adding it would dilute focus from the core thesis (inference operations) into generic SaaS platform territory.

**What changes for multi-tenancy:**
- Namespace-per-tenant with NetworkPolicy isolation
- ResourceQuota per namespace (token limits, pod limits)
- Kyverno policies scoped per tenant
- InferencePool per tenant (dedicated model instances)
- Billing attribution via pod labels + cost allocation tags
- Tenant-aware rate limiting at the Gateway

---

## 5. No Disaggregated Prefill/Decode in CPU Mode

**What's limited:** Prefill and decode happen on the same pod. The disaggregated architecture (separate prefill pool and decode pool connected via RDMA/NIXL) is documented but not exercised.

**Why:** Disaggregated serving requires GPU nodes with high-bandwidth interconnect (RDMA). It makes no sense on CPU. The architecture is designed for it (separate InferencePool CRDs for each), but the CPU baseline runs both on the same pod.

**What changes for disaggregated:**
- Two node groups: prefill pool (compute-optimized GPU) and decode pool (memory-optimized GPU)
- NIXL for KV cache transfer between prefill and decode pods
- EFA (Elastic Fabric Adapter) for RDMA on AWS
- Separate KEDA ScaledObjects per pool (compute-bound vs memory-bound signals)
- EPP configured to return a prefill/decode pair, not a single pod

---

## 6. No Formal Threat Model Document

**What's limited:** Security is implemented at three gates (CI, admission, runtime) but there is no formal STRIDE or PASTA threat model document.

**Why:** A formal threat model is a team exercise requiring stakeholder input on risk appetite and data classification. For a solo project, the security controls themselves demonstrate the practice — the formal document would be performative without real organizational context.

**What would exist in production:**
- STRIDE analysis per component (Gateway, EPP, vLLM, model store)
- Data flow diagram with trust boundaries
- Risk register with severity ratings
- Penetration test scope document
- Incident response runbook

---

## 7. No DAST (Dynamic Application Security Testing)

**What's limited:** Security testing is static (SAST via Checkov, Trivy, Gitleaks). No dynamic testing of the running application for vulnerabilities.

**Why:** DAST requires a running staging environment receiving synthetic traffic and a tool like OWASP ZAP or Burp Suite actively probing it. This is a continuous process, not a one-time demo.

**What changes for DAST:**
- OWASP ZAP or Nuclei running against the staging endpoint post-deploy
- Prompt-specific DAST: fuzzing the inference endpoint with adversarial inputs
- Integration into the CI pipeline as a post-deploy step
- Results feeding into the same Claude API triage for summarization

---

## 8. LeaderWorkerSet for Multi-Node Sharding (Stubbed, Not Deployed)

**What's limited:** A LeaderWorkerSet manifest exists in `manifests/examples/` but is not deployed. Multi-node tensor parallelism is documented, not exercised.

**Why:** Models small enough to run on CPU fit in a single node. Multi-node sharding only makes sense for 70B+ parameter models that exceed single-GPU VRAM. Deploying it without a real need would be demonstrating tooling, not solving a problem.

**What changes for multi-node:**
- LeaderWorkerSet CRD installed and deployed
- Model: Llama-3.1-70B or Mixtral-8x7B (requires 2-4 GPUs)
- Tensor parallelism configured in vLLM (`--tensor-parallel-size=4`)
- High-bandwidth networking between nodes (EFA on AWS)
- Pod topology constraints to ensure co-location

---

## The Principle

Every item above is a conscious choice, not an oversight. The project demonstrates depth within its scope rather than breadth across everything. Each limitation has a documented bridge path — meaning any interviewer asking "but what about X?" gets a concrete answer, not a blank stare.

> Knowing what you didn't build — and being able to articulate exactly what would change — signals more maturity than building everything poorly.
