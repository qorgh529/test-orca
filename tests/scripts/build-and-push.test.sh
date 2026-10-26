#!/usr/bin/env bash
# Offline regression test for scripts/build-and-push.sh (CodeBuild mode): aws is a fake on PATH that logs
# its calls, the script runs from a temp git repo with an .env copied from .env.example. No AWS account needed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/scripts" "$T/bin"
cp "$REPO/scripts/lib.sh" "$REPO/scripts/build-and-push.sh" "$T/repo/scripts/"
cp "$REPO/buildspec.yml" "$T/repo/"
# .env as a user would have it: copied from the template, per-run fields (IMAGE_TAG, BUILD_TARGET) left empty.
sed -e 's|^AWS_ACCOUNT_ID=.*|AWS_ACCOUNT_ID=test-account|' \
    -e 's|^ECR_WEB_REPOSITORY_URI=.*|ECR_WEB_REPOSITORY_URI=registry.example/petclinic-web|' \
    -e 's|^ECR_WAS_REPOSITORY_URI=.*|ECR_WAS_REPOSITORY_URI=registry.example/petclinic-was|' \
    -e 's|^BACKUP_S3_BUCKET_NAME=.*|BACKUP_S3_BUCKET_NAME=backup-bucket|' \
    "$REPO/.env.example" > "$T/repo/.env"
: > "$T/repo/id_rsa"; : > "$T/repo/local.pem"; : > "$T/repo/notes.secret"
git -C "$T/repo" init -q && git -C "$T/repo" add scripts buildspec.yml
LOG="$T/calls.log"

# Fakes answer from env: BUILD_STATUS (final batch-get-builds status), EXISTING_TAG (describe-images hit).
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *describe-images*) [[ "$*" == *"imageTag=${EXISTING_TAG:-none}"* ]] ;;
  "s3 cp"*) cp "$4" "$T/uploaded.zip" ;;
  *start-build*) echo "proj:build-1" ;;
  *batch-get-builds*"buildStatus,currentPhase"*) printf '%s\t%s\n' "${BUILD_STATUS:-SUCCEEDED}" COMPLETED ;;
  *batch-get-builds*) echo '{}' ;;
esac
EOF
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH" LOG T

fail=0
run() { : > "$LOG"; env "$@" bash "$T/repo/scripts/build-and-push.sh" > "$T/out" 2>&1; }
export -f run
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" "$LOG"; fail=1; fi
}

run IMAGE_TAG=v1 BUILD_TARGET=web
check "command-line BUILD_TARGET/IMAGE_TAG win over empty .env values" \
  grep -q 'name=BUILD_TARGET,value=web,type=PLAINTEXT' "$LOG"
check "only the requested repository is checked for an existing tag" \
  bash -c '! grep -q "repository-name petclinic-was" "$LOG" && grep -q "repository-name petclinic-web" "$LOG"'
key1=$(grep -o 'source-location-override [^ ]*' "$LOG")
check "source key is per run and carries the tag" \
  grep -Eq 'source/v1-[0-9]{8}T[0-9]{6}Z-[0-9a-f-]{36}\.zip' <<<"$key1"
run IMAGE_TAG=v1 BUILD_TARGET=web
check "a second run with the same tag gets a different key" \
  bash -c '[ "$1" != "$(grep -o "source-location-override [^ ]*" "$LOG")" ]' _ "$key1"
check "archive has buildspec.yml but no .env or key material" \
  python3 -I -c 'import sys, zipfile
n = set(zipfile.ZipFile(sys.argv[1]).namelist())
sys.exit(not ("buildspec.yml" in n and not n & {".env", "id_rsa", "local.pem", "notes.secret"}))' "$T/uploaded.zip"

check "IMAGE_TAG with shell characters is rejected" bash -c '! run IMAGE_TAG="v1;rm" && grep -q "IMAGE_TAG must match" "$T/out"'
check "existing tag stops before upload" bash -c '! run IMAGE_TAG=v2 EXISTING_TAG=v2 && ! grep -q "s3 cp" "$LOG"'
# Set in .env: lib.sh lets .env win over the caller for everything but IMAGE_TAG/BUILD_TARGET.
cp "$T/repo/.env" "$T/env.bak"
sed -i 's|^CODEBUILD_S3_BUCKET_NAME=.*|CODEBUILD_S3_BUCKET_NAME=backup-bucket|' "$T/repo/.env"
check "source bucket equal to the backup bucket is rejected" \
  bash -c '! run IMAGE_TAG=v1 && grep -q "must differ from BACKUP_S3_BUCKET_NAME" "$T/out" && ! grep -q "s3 cp" "$LOG"'
mv "$T/env.bak" "$T/repo/.env"
check "failed build exits non-zero" bash -c '! run IMAGE_TAG=v1 BUILD_STATUS=FAILED'

[ "$fail" = 0 ] && echo "OK: build-and-push offline tests"
exit "$fail"
