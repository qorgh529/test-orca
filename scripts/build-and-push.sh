#!/usr/bin/env bash
# Build web/was images and push them to ECR with an immutable tag.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

require AWS_REGION AWS_ACCOUNT_ID ECR_WEB_REPOSITORY_URI ECR_WAS_REPOSITORY_URI IMAGE_TAG
[ "$IMAGE_TAG" != "latest" ] || { echo "IMAGE_TAG must not be 'latest'" >&2; exit 1; }

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# np-app nodes are amd64 (infra/karpenter/nodepool-app.yaml).
docker build --platform linux/amd64 -f "$ROOT/docker/was/Dockerfile" -t "$ECR_WAS_REPOSITORY_URI:$IMAGE_TAG" "$ROOT"
docker build --platform linux/amd64 -f "$ROOT/docker/web/Dockerfile" -t "$ECR_WEB_REPOSITORY_URI:$IMAGE_TAG" "$ROOT"

docker push "$ECR_WAS_REPOSITORY_URI:$IMAGE_TAG"
docker push "$ECR_WEB_REPOSITORY_URI:$IMAGE_TAG"
