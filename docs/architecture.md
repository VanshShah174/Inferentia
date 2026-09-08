# Inferentia — Architecture

**From code push to streaming response.** This diagram renders natively on GitHub (Mermaid).

```mermaid
flowchart TD
    dev([Developer pushes to Git]):::git

    subgraph CI["CI Pipeline — GitHub Actions (per-concern, SHA-pinned)"]
        direction LR
        lint[Lint] --> scan[Build + Scan<br/>Trivy / Gitleaks] --> sign[Cosign sign<br/>keyless / OIDC] --> triage[AI triage] --> gate[Promotion gate<br/>verify digest]
    end

    ecr[(ECR<br/>signed image + SBOM)]:::store
    s3[(S3<br/>model weights, versioned)]:::store

    argo[ArgoCD ApplicationSet<br/>watches 4 branches → 4 namespaces]:::gitops
    kyverno{{Kyverno Admission<br/>verify-image-signatures · resource hygiene}}:::policy

    subgraph EKS["EKS Cluster — one cluster, 4 namespaces"]
        direction LR
        nsdev[dev]:::ns
        nsqa[qa]:::ns
        nsppd[ppd]:::ns
        nsprod[prod]:::ns
    end

    subgraph POD["Inside a namespace"]
        direction LR
        job[Init: S3 → weights]:::infra --> vllm[/vLLM Pod<br/>OpenAI-compatible /v1/]:::engine
        pvc[(model volume)]:::store -.-> vllm
    end

    subgraph SERVE["Request path"]
        direction TB
        client([User request]) --> gw[Gateway API / Envoy<br/>→ EPP: KV-cache-aware pick]:::route
        gw --> prefill[Prefill — compute-bound<br/>prompt tokens → KV cache]:::engine
        prefill --> decode[Decode — memory-bandwidth-bound<br/>PagedAttention · continuous batching]:::engine
        decode --> stream[Tokens stream back SSE]:::route
    end

    subgraph OBS["Observability + Autoscaling"]
        direction LR
        prom[Prometheus]:::obs --> graf[Grafana<br/>TTFT · TPOT · KV% · tok/s]:::obs
        keda[KEDA<br/>scale on KV-cache + queue depth]:::obs
    end

    subgraph AIOPS["AI Operations"]
        kagent[kagent agent<br/>brain = self-hosted vLLM]:::agent --> mcp[MCP tool server<br/>k8s tools]:::agent --> k8sapi[(live Kubernetes API)]:::infra
    end

    iac[Terraform — VPC · EKS · ECR · S3 · Pod Identity · OIDC<br/>one apply · one destroy · zero static credentials]:::iac

    dev --> CI
    sign --> ecr
    CI --> s3
    ecr --> argo
    s3 --> argo
    argo --> kyverno --> EKS
    nsprod --> POD
    vllm --> SERVE
    vllm --> prom
    keda -.scales.-> vllm
    kagent --> vllm
    iac -.provisions.-> EKS

    classDef git fill:#f4a261,stroke:#333,color:#111
    classDef store fill:#e9c46a,stroke:#333,color:#111
    classDef gitops fill:#a8dadc,stroke:#333,color:#111
    classDef policy fill:#f1a7a1,stroke:#333,color:#111
    classDef ns fill:#b7e4c7,stroke:#333,color:#111
    classDef engine fill:#caffbf,stroke:#333,color:#111
    classDef route fill:#e0c3fc,stroke:#333,color:#111
    classDef obs fill:#ffd6a5,stroke:#333,color:#111
    classDef agent fill:#fdffb6,stroke:#333,color:#111
    classDef infra fill:#d0d1ff,stroke:#333,color:#111
    classDef iac fill:#bde0fe,stroke:#333,color:#111
```

> The platform serves the model. The model operates the platform.
> **The workload changed. The discipline didn't.**
