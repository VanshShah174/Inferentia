#!/usr/bin/env bash
# =============================================================================
# seed-ecr.sh — one-time: build + push the UNSIGNED vLLM image to ECR
# =============================================================================
# Breaks the day-one chicken-and-egg: dev (and qa) pull the image from ECR, but
# CI only builds it at the PR dev->qa stage. This seeds the FIRST image so the
# first dev deploy has something to pull. It is a ONE-TIME provisioning step,
# same category as seed-model.sh and the Terraform state-bucket bootstrap.
#
# The seeded image is UNSIGNED — that's fine: Kyverno only requires a signature
# in ppd + prod (signing happens at PR->ppd). dev + qa run unsigned images.
# From the first PR dev->qa onward, CI replaces this seed with its built image.
#
# Usage:
#   AWS_ACCOUNT_ID=123456789012 ./scripts/seed-ecr.sh
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-ca-central-1}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"
: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID (e.g. export AWS_ACCOUNT_ID=123456789012)}"

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
REPO="inferentia/vllm-cpu"
IMAGE="${REGISTRY}/${REPO}:${IMAGE_TAG}"

echo ">> Logging in to ECR (${REGISTRY}) ..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo ">> Building ${IMAGE} from containers/vllm-cpu/Dockerfile ..."
docker build -t "${IMAGE}" -f containers/vllm-cpu/Dockerfile containers/vllm-cpu/

echo ">> Pushing ${IMAGE} (unsigned) ..."
docker push "${IMAGE}"

echo ">> Done. Verify:"
aws ecr describe-images --repository-name "${REPO}" --region "${REGION}" \
  --query 'imageDetails[].imageTags' --output text
cat <<EOF

Seeded (unsigned): ${IMAGE}
  - dev + qa can now pull this image (Kyverno does not require a signature there).
  - ppd + prod require a Cosign signature, produced by CI at PR->ppd.
  - The first PR dev->qa replaces this seed with the CI-built image.
EOF
