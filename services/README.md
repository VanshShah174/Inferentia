# Supporting Services

This directory contains the source code for services that Inferentia builds and deploys alongside the inference workload. These services demonstrate AI integration *into the DevOps toolchain itself* — not just as the served workload.

---

## Services

### alert-enricher

**Purpose:** Alertmanager webhook receiver that enriches SLO alerts with AI-generated context before paging on-call.

**How it works:**
1. Prometheus detects an SLO breach (e.g., TTFT p95 > 2s for 5 minutes)
2. Alertmanager fires to the alert-enricher webhook
3. Alert-enricher calls the Claude API with alert context + recent metrics
4. Claude generates a human-readable summary: what's wrong, likely cause, suggested action
5. Enriched alert is forwarded to the notification channel (Slack/PagerDuty)

**Why it exists:** Demonstrates that AI can reduce mean-time-to-understand (MTTU) in incident response. On-call engineers receive context, not just a metric threshold number.

**Tech:** Python (FastAPI), Claude API, Prometheus query client

---

### safety-classifier

**Purpose:** Input safety gate that scans prompts for injection attempts and harmful content before inference compute is spent.

**How it works:**
1. Request arrives at the Gateway
2. Before routing to vLLM, the safety classifier evaluates the prompt
3. If the prompt is safe → pass through to inference
4. If the prompt is malicious → return 400 immediately (zero compute wasted)

**Why it exists:** This is the AI-specific admission gate that no traditional Pod Security Standard covers. It's the equivalent of input validation for LLM workloads.

**Tech:** Python (FastAPI), lightweight classification model or rule-based detection

---

## Design Principles

- Each service has its own Dockerfile in `containers/<service-name>/`
- Each service is deployed via the platform's standard pipeline (Helm + ArgoCD)
- Each service is scanned, signed, and admitted through the same gates as the inference workload
- Services are intentionally small and focused — one responsibility each
