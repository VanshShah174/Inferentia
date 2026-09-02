# =============================================================================
# Inferentia — vLLM CPU Inference Image
# =============================================================================
# Purpose: Production-hardened vLLM image for CPU-based LLM inference
# Base: Official vLLM CPU image (pinned version, not :latest)
# Security: Non-root user, read-only filesystem compatible, no shell in prod
# =============================================================================

# Pin to exact version for reproducibility (never use :latest in production)
FROM vllm/vllm-openai-cpu:v0.28.0 AS base

# Metadata labels (OCI standard)
LABEL org.opencontainers.image.title="Inferentia vLLM CPU"
LABEL org.opencontainers.image.description="Self-hosted LLM inference engine for Qwen 2.5 0.5B on CPU"
LABEL org.opencontainers.image.source="https://github.com/VanshShah174/Inferentia"
LABEL org.opencontainers.image.version="0.1.0"
LABEL org.opencontainers.image.vendor="Inferentia"

# -----------------------------------------------------------------------------
# CVE remediation — upgrade the vulnerable packaging lib shipped in the base
# image to a fixed version. Trivy (build-and-scan) flagged setuptools as HIGH:
#   setuptools CVE-2025-47273 -> fixed 78.1.1 (path traversal)
# Pinned EXACTLY to 78.1.1: it is the fixed release AND stays within vLLM's
# constraint (vllm 0.28.0 requires setuptools <81.0.0,>=77.0.3). A newer
# setuptools (e.g. 84.x) clears the CVE but breaks that constraint.
# The vendored wheel (0.46.3) and jaraco.context (6.1.0) inside setuptools are
# already at fixed versions in the base image, so no action needed there.
# Done as root (before the USER switch) so /opt/venv is writable.
# -----------------------------------------------------------------------------
RUN pip install --no-cache-dir "setuptools==78.1.1"

# Create non-root user for security (CIS Benchmark 4.1)
RUN groupadd -r vllm && useradd -r -g vllm -d /home/vllm -s /sbin/nologin vllm \
    && mkdir -p /home/vllm/.cache /models \
    && chown -R vllm:vllm /home/vllm /models

# Set environment variables for CPU inference
ENV VLLM_CPU_KVCACHE_SPACE=1 \
    VLLM_TARGET_DEVICE=cpu \
    HF_HOME=/home/vllm/.cache/huggingface \
    TOKENIZERS_PARALLELISM=false

# Switch to non-root user
USER vllm
WORKDIR /home/vllm

# Health check — Kubernetes will use readiness/liveness probes,
# but this provides a Docker-native health signal
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Expose vLLM API port
EXPOSE 8000

# Default entrypoint — can be overridden by Helm chart args
ENTRYPOINT ["vllm", "serve"]

# Default arguments — overridden by Helm values per environment
CMD ["Qwen/Qwen2.5-0.5B-Instruct", \
     "--dtype", "bfloat16", \
     "--max-model-len", "512", \
     "--enforce-eager", \
     "--port", "8000"]
