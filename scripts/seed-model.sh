#!/usr/bin/env bash
# =============================================================================
# seed-model.sh — one-time: HuggingFace model weights -> S3 (Download #1)
# =============================================================================
# This is the ONE-TIME provisioning seed of the model artifact store. It is NOT
# part of the deploy loop. Run it ONCE after `terraform apply` creates the S3
# bucket, before the first vLLM deploy.
#
#   HuggingFace  --(this script, run by an operator)-->  S3      [Download #1]
#   S3           --(the in-cluster Job, every deploy)-->  PVC     [Download #2]
#
# For the public Qwen 0.5B model no HF token is needed. (A gated model would
# need one, supplied via env / Secrets Manager — not committed.)
#
# Usage:
#   AWS_ACCOUNT_ID=123456789012 ./scripts/seed-model.sh
# =============================================================================
set -euo pipefail

MODEL_REPO="${MODEL_REPO:-Qwen/Qwen2.5-0.5B-Instruct}"
MODEL_KEY="${MODEL_KEY:-Qwen2.5-0.5B-Instruct}"
REGION="${AWS_REGION:-ca-central-1}"

: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID (e.g. export AWS_ACCOUNT_ID=123456789012)}"
BUCKET="${BUCKET:-inferentia-model-store-${AWS_ACCOUNT_ID}}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo ">> Downloading ${MODEL_REPO} from HuggingFace to ${WORKDIR}/${MODEL_KEY} ..."
python -m pip install --quiet --user huggingface_hub
python - "$MODEL_REPO" "${WORKDIR}/${MODEL_KEY}" <<'PY'
import sys
from huggingface_hub import snapshot_download
repo, dst = sys.argv[1], sys.argv[2]
snapshot_download(repo_id=repo, revision="main", local_dir=dst)
print("download complete:", dst)
PY

echo ">> Syncing to s3://${BUCKET}/${MODEL_KEY}/ ..."
aws s3 sync "${WORKDIR}/${MODEL_KEY}" "s3://${BUCKET}/${MODEL_KEY}/" --region "${REGION}"

echo ">> Done. Verify:"
aws s3 ls "s3://${BUCKET}/${MODEL_KEY}/" --region "${REGION}"
echo ">> The model is seeded. The in-cluster model-download Job will S3 -> PVC on deploy."
