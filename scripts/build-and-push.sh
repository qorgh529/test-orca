#!/usr/bin/env bash
# Build web/was images and push them to ECR with an immutable tag.
# Default: on AWS CodeBuild (docs/features/codebuild-image-build/design.md) — zip the working tree,
# upload it to the CodeBuild source bucket, start a build with buildspec.yml and follow it to the end.
# --local: build with the local docker daemon instead (needs a working docker; not on the LXC server).
#
#   IMAGE_TAG=v1.0.0 [BUILD_TARGET=all|web|was] ./scripts/build-and-push.sh [--local]
set -euo pipefail
# Per-run settings from the command line win over the (usually empty) ones copied into .env.
caller_tag="${IMAGE_TAG:-}" caller_target="${BUILD_TARGET:-}"
. "$(dirname "$0")/lib.sh"
IMAGE_TAG="${caller_tag:-${IMAGE_TAG:-}}" BUILD_TARGET="${caller_target:-${BUILD_TARGET:-}}"

usage() { echo "usage: IMAGE_TAG=<tag> [BUILD_TARGET=all|web|was] $0 [--local]"; }
LOCAL=0
for a in "$@"; do
  case "$a" in
    --local) LOCAL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

require AWS_REGION AWS_ACCOUNT_ID ECR_WEB_REPOSITORY_URI ECR_WAS_REPOSITORY_URI IMAGE_TAG
[ "$IMAGE_TAG" != "latest" ] || { echo "IMAGE_TAG must not be 'latest'" >&2; exit 1; }
# Docker tag grammar; it also lands in an S3 key and the CodeBuild environment.
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
  || { echo "IMAGE_TAG must match [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}" >&2; exit 1; }
BUILD_TARGET="${BUILD_TARGET:-all}"
case "$BUILD_TARGET" in all|web|was) ;; *) echo "BUILD_TARGET must be all, web or was" >&2; exit 1 ;; esac
targets=(was web); [ "$BUILD_TARGET" = all ] || targets=("$BUILD_TARGET")
uri() { if [ "$1" = web ]; then echo "$ECR_WEB_REPOSITORY_URI"; else echo "$ECR_WAS_REPOSITORY_URI"; fi; }

if (( LOCAL )); then
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  # np-app nodes are amd64 (infra/karpenter/nodepool-app.yaml).
  for t in "${targets[@]}"; do
    docker build --platform linux/amd64 -f "$ROOT/docker/$t/Dockerfile" -t "$(uri "$t"):$IMAGE_TAG" "$ROOT"
  done
  for t in "${targets[@]}"; do docker push "$(uri "$t"):$IMAGE_TAG"; done
  exit 0
fi

require EKS_CLUSTER_NAME
CODEBUILD_PROJECT_NAME="${CODEBUILD_PROJECT_NAME:-${EKS_CLUSTER_NAME}-image-build}"
CODEBUILD_S3_BUCKET_NAME="${CODEBUILD_S3_BUCKET_NAME:-${EKS_CLUSTER_NAME}-codebuild-${AWS_ACCOUNT_ID}}"
for b in "${BACKUP_S3_BUCKET_NAME:-}" "${TEMPO_S3_BUCKET_NAME:-}"; do
  [ "$CODEBUILD_S3_BUCKET_NAME" != "$b" ] \
    || { echo "CODEBUILD_S3_BUCKET_NAME must differ from BACKUP_S3_BUCKET_NAME and TEMPO_S3_BUCKET_NAME" >&2; exit 1; }
done
for c in aws git python3; do command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }; done

# Repositories are IMMUTABLE: fail now instead of after a full build.
for t in "${targets[@]}"; do
  repo=$(uri "$t"); repo=${repo#*/}
  if aws ecr describe-images --repository-name "$repo" --image-ids "imageTag=$IMAGE_TAG" >/dev/null 2>&1; then
    echo "$repo:$IMAGE_TAG already exists (immutable tags): pick a new IMAGE_TAG" >&2; exit 1
  fi
done

echo "== Packaging source"
# Tracked plus untracked-but-not-ignored files, so uncommitted edits are built too. .gitignore already
# keeps .env, target/ and the daily state file out; env files and key material are dropped again as a backstop.
archive=$(mktemp --suffix=.zip)
trap 'rm -f "$archive"' EXIT
git -C "$ROOT" ls-files -z --cached --others --exclude-standard \
  | python3 -I -c '
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
names = sorted({n for n in sys.stdin.buffer.read().decode().split("\0") if n})
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for n in names:
        base = os.path.basename(n)
        if ((base.startswith(".env") and base != ".env.example") or base.startswith("id_")
                or base.endswith((".secret", ".pem", ".key", ".pfx", ".p12"))):
            continue
        p = os.path.join(root, n)
        if os.path.isfile(p) and not os.path.islink(p):  # deleted-but-tracked files are skipped
            z.write(p, n)
' "$ROOT" "$archive"
# One key per run: a second run with the same tag must not replace a source that is still queued.
key="source/${IMAGE_TAG}-$(date -u +%Y%m%dT%H%M%SZ)-$(cat /proc/sys/kernel/random/uuid).zip"
aws s3 cp --only-show-errors "$archive" "s3://${CODEBUILD_S3_BUCKET_NAME}/${key}"

echo "== Starting CodeBuild $CODEBUILD_PROJECT_NAME ($BUILD_TARGET:$IMAGE_TAG)"
build_id=$(aws codebuild start-build \
  --project-name "$CODEBUILD_PROJECT_NAME" \
  --source-type-override S3 \
  --source-location-override "${CODEBUILD_S3_BUCKET_NAME}/${key}" \
  --environment-variables-override \
    "name=IMAGE_TAG,value=${IMAGE_TAG},type=PLAINTEXT" \
    "name=ECR_WEB_REPOSITORY_URI,value=${ECR_WEB_REPOSITORY_URI},type=PLAINTEXT" \
    "name=ECR_WAS_REPOSITORY_URI,value=${ECR_WAS_REPOSITORY_URI},type=PLAINTEXT" \
    "name=AWS_REGION,value=${AWS_REGION},type=PLAINTEXT" \
    "name=AWS_ACCOUNT_ID,value=${AWS_ACCOUNT_ID},type=PLAINTEXT" \
    "name=BUILD_TARGET,value=${BUILD_TARGET},type=PLAINTEXT" \
  --query 'build.id' --output text)
echo "build: $build_id"

last=""
while :; do
  read -r status phase < <(aws codebuild batch-get-builds --ids "$build_id" \
    --query 'builds[0].[buildStatus,currentPhase]' --output text)
  [ "$status $phase" = "$last" ] || echo "$(date +%H:%M:%S) $status $phase"
  last="$status $phase"
  case "$status" in
    IN_PROGRESS) sleep 10 ;;
    SUCCEEDED)
      for t in "${targets[@]}"; do echo "pushed $(uri "$t"):$IMAGE_TAG"; done
      exit 0 ;;
    *)
      echo "build $build_id: $status" >&2
      aws codebuild batch-get-builds --ids "$build_id" \
        --query 'builds[0].{logGroup: logs.groupName, logStream: logs.streamName, failedPhases: phases[?phaseStatus==`FAILED`].[phaseType, contexts[0].message]}' \
        --output json >&2 || true
      exit 1 ;;
  esac
done
