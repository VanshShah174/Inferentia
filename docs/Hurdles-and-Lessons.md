# Hurdles & Lessons — Building Inferentia

> The parts that didn't work the first time. This is the honest engineering log —
> the problems that actually cost hours, the root cause, and how each was solved.
> If you're building a self-hosted LLM platform on EKS, these are the traps.

---

## 1. ECR push kept failing with 403 Forbidden

**Symptom.** `docker push` to ECR intermittently returned `403 Forbidden` / `denied: Your authorization token has expired`.

**Root cause.** ECR auth tokens are short-lived (12h), and a stale `docker login` session silently expired mid-workflow.

**Fix.** Always run a **fresh** `aws ecr get-login-password | docker login` immediately before the push — never reuse an earlier login. In CI this is handled by the `amazon-ecr-login` action right before the push step.

**Lesson.** ECR credentials are ephemeral by design. Treat login as a per-push step, not a one-time setup.

---

## 2. Model weights and the ReadWriteOnce PVC across replicas

**Symptom.** Trying to run 2 vLLM replicas that shared one model PVC caused pods to get stuck `Pending` or churn endlessly. Adding `podAffinity` to co-locate them either deadlocked (the first replica had no peer to attract to) or fought the scheduler.

**Root cause.** EBS volumes are **ReadWriteOnce** — a single volume can only be mounted by pods on **one node**. Two replicas on different nodes can't share it, even read-only.

**Fix.** Two clean options, depending on the goal:
- **Single promoted replica** backed by the RWO PVC (what prod runs) — simple and correct.
- **Independent replicas**, each with its own `emptyDir` + a per-pod init download from S3 — no shared volume to fight over.

**Lesson.** Don't force a multi-replica topology onto a single-writer volume. Either accept one replica per volume, give each pod its own copy, or move to ReadWriteMany (EFS). Every "clever" affinity workaround was a symptom of fighting the storage model.

---

## 3. ArgoCD self-heal kept reverting live changes

**Symptom.** I'd `kubectl scale` or `kubectl patch` a deployment, and moments later ArgoCD silently reverted it. Endless whack-a-mole.

**Root cause.** ArgoCD `selfHeal: true` continuously reconciles live state back to Git. Any manual change to a managed object is treated as drift and undone. **Git is the source of truth — not the cluster.**

**Fix.** Change **Git**, not live objects. When a temporary live change was genuinely needed (e.g. during the routing demo), I explicitly paused `selfHeal` on that Application first, then made the change — and committed the permanent version to the branch afterward.

**Lesson.** In GitOps, the cluster is an output, not an input. If you find yourself fighting the controller, you're editing the wrong layer.

---

## 4. The model-download Job vs. ArgoCD sync-waves

**Symptom.** As a Helm `pre-install` hook, the model-download Job ran **before** the PVC existed under ArgoCD, and hook-managed PVCs deadlocked. A later sync-wave Job also deadlocked — ArgoCD waits for a wave to be Healthy before the next, but the PVC (Pending) and Deployment (waiting on the model) never go Healthy until the Job runs.

**Root cause.** Ordering. The Job, PVC, and Deployment have a circular readiness dependency if placed in the wrong waves.

**Fix.**
- Make the Job a **normal resource in the same sync-wave (0) as the PVC**, so its pod becomes the PVC's first consumer and triggers `WaitForFirstConsumer` binding.
- The Deployment's `wait-for-model` **initContainer** enforces "model ready before vLLM boots."
- Use `Replace=true,Force=true` on the Job (its `spec.selector`/`template` are immutable, so a plain replace wedges the whole sync).

**Lesson.** With ArgoCD, resource *ordering* is a first-class design concern. Init containers express intra-pod ordering; sync-waves express inter-resource ordering — use the right tool for each.

---

## 5. KV-cache autoscaling never triggered

**Symptom.** KEDA was configured to scale on `vllm:kv_cache_usage_perc`, but on the 0.5B CPU model the cache never filled past ~0%, so it never scaled.

**Root cause.** A tiny model with short completions barely uses KV cache. KV-cache utilization is the *right* production signal, but it doesn't move for this workload.

**Fix.** Added a second KEDA trigger on **request queue depth** (`num_requests_running + num_requests_waiting`, threshold 3) — the signal that actually saturates a small CPU replica under concurrency. Under a 300-request / 16-concurrency load test, prod scaled **1 → 3** and back down after cooldown.

**Lesson.** Pick the scaling signal that matches your *actual* workload, not the textbook one. Document why (the KV-cache trigger stays as the documented production-intent signal).

---

## 6. KEDA and the chart's HPA fought over the same Deployment

**Symptom.** KEDA's admission webhook rejected the ScaledObject: the target Deployment already had an HPA.

**Root cause.** Two autoscalers cannot own the same Deployment. The Helm chart shipped a CPU HPA; KEDA creates its own HPA under the hood.

**Fix.** Disabled the chart HPA (`autoscaling.enabled=false`) for the env KEDA manages — and set it in **Git**, because ArgoCD selfHeal kept recreating the chart HPA until the source said otherwise (see hurdle #3).

**Lesson.** One workload, one autoscaler. Decide who owns scaling and make everything else defer.

---

## 7. kagent agent "kept thinking" and never answered

**Symptom.** The kagent agent, backed by the self-hosted vLLM, accepted a prompt and hung with no reply and no error.

**Root cause — three chained issues:**
1. **NetworkPolicy.** `inference-prod` is default-deny ingress; the `kagent` namespace wasn't in the allow-list, so the agent's call to vLLM timed out (`i/o timeout`).
2. **Tool-calling.** kagent's ADK sends `tool_choice: auto`, but vLLM wasn't started with tool-calling enabled → `400: "auto" tool choice requires --enable-auto-tool-choice`.
3. **Stale connection.** After fixing vLLM, the old agent pod held a connection from before the fix.

**Fix.**
1. Added a least-privilege NetworkPolicy allowing `kagent` → vLLM:8000 only.
2. Patched vLLM args with `--enable-auto-tool-choice --tool-call-parser hermes`.
3. Restarted the agent pod for a fresh connection.

After that: the agent called an MCP `k8s_get_resources` tool and returned the real cluster node names.

**Lesson.** "It hangs" is rarely one bug. Read the *actual* error at each layer (agent log → vLLM log → the A2A response body) instead of guessing. Each layer told a different, true story.

---

## 8. The small model is weak at tool-calling

**Symptom.** Asked to "list pods," the agent called the wrong MCP tool (`describe` instead of `get`) and passed the namespace as a pod name → tool error.

**Root cause.** A 0.5B model is not reliable at free-form function-call argument selection.

**Fix.** Prompt it explicitly ("Use `k8s_get_resources` with `resource_type=pods` and `namespace=inference-prod`") — then it fires the tool correctly and returns real data. RBAC was verified (`kubectl auth can-i list pods` as the tools SA = yes) to rule out a permission issue first.

**Lesson.** Match expectations to model capacity. The *wiring* (agent → self-hosted model → MCP → cluster) is the achievement; the tiny model's tool accuracy is a documented limitation, not a failure.

---

## 9. MCP tool output blew past the context window

**Symptom.** `k8s_get_events` succeeded as a tool call, but the follow-up model call failed: `maximum context length is 2048 tokens ... prompt contains 1,617,939 characters`.

**Root cause.** The events payload was enormous; `--max-model-len` is 2048.

**Fix.** For the demo, use tools that return small, bounded output (`k8s_get_resources`). The production fix would be raising `--max-model-len` or truncating tool output before it re-enters the prompt.

**Lesson.** Tool output is untrusted, unbounded input to the next model call. Bound it, or the context window becomes your failure mode.

---

## 10. Orphaned EBS volumes survived `terraform destroy`

**Symptom.** After a clean `terraform destroy` (50 resources gone), 10 EBS volumes were still present and still billing.

**Root cause.** Those volumes were created **dynamically by the EBS CSI driver** for PersistentVolumeClaims — inside Kubernetes, not by Terraform. Terraform never tracked them, so destroy couldn't remove them.

**Fix.** Verified they were all tagged `kubernetes.io/cluster/inferentia-eks: owned` (unambiguously the dead cluster's), then deleted them explicitly. Confirmed zero volumes, EIPs, LBs, and ENIs remained.

**Lesson.** `terraform destroy` only removes what Terraform created. Dynamically-provisioned cluster storage is a separate cleanup step — always sweep for orphaned EBS volumes, load balancers, and ENIs after tearing down an EKS cluster, or you'll keep paying for it.

---

## Meta-lesson

Almost every hurdle came from **one layer fighting another** — storage vs. replicas, ArgoCD vs. manual edits, two autoscalers, NetworkPolicy vs. cross-namespace traffic, tool output vs. context window. The fix was never a clever hack; it was identifying *which layer owned the concern* and letting it own it.

> The workload changed. The discipline didn't.
