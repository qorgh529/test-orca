#!/usr/bin/env bash
# Offline regression test for scripts/daily-{stop,start}.sh: aws and kubectl are fakes on PATH that log
# their calls, the scripts run from a temp copy of the repo layout. No AWS account or cluster needed.
# Needs jq (the scripts require it outside --dry-run); without it the test is skipped and says so.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP daily stop/start offline tests: jq not installed"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/infra/karpenter" "$T/k8s/web" "$T/bin"
cp "$REPO/scripts/lib.sh" "$REPO/scripts/daily-stop.sh" "$REPO/scripts/daily-start.sh" "$T/scripts/"
cp "$REPO/infra/karpenter/nodepool-app.yaml" "$T/infra/karpenter/"
cp "$REPO/k8s/web/hpa.yaml" "$T/k8s/web/"
STATE="$T/.daily-nodegroup-state.json"
LOG="$T/calls.log"

# Fakes answer from env: RDS_STATUS, NG_SCALING ("min desired max"), REPLICAS,
# and KUBECTL_GET_ERROR (stderr text; makes every kubectl get fail).
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *describe-db-instances*) echo "${RDS_STATUS:-available}" ;;
  *describe-nodegroup*) echo "${NG_SCALING:-2 2 4}" | tr ' ' '\t' ;;
esac
EOF
cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$LOG"
[ -t 0 ] || cat >/dev/null
if [[ " $* " == *" get "* ]]; then
  if [ -n "${KUBECTL_GET_ERROR:-}" ]; then echo "$KUBECTL_GET_ERROR" >&2; exit 1; fi
  [[ "$*" == *jsonpath* ]] && echo "${REPLICAS:-0}"
fi
exit 0
EOF
chmod +x "$T/bin/aws" "$T/bin/kubectl"
export LOG PATH="$T/bin:$PATH" AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=test-eks
NOTFOUND='Error from server (NotFound): resource not found'

fails=0
# check <name> <script> <expect: ok | error text> [VAR=value ...] — fresh call log; then extra asserts via `called`.
check() {
  local name=$1 script=$2 want=$3 rc=0; shift 3
  : > "$LOG"
  env "$@" bash "$T/scripts/$script.sh" > "$T/out" 2>&1 || rc=$?
  if [ "$want" = ok ] && [ "$rc" = 0 ]; then return 0; fi
  if [ "$want" != ok ] && [ "$rc" != 0 ] && grep -qF -- "$want" "$T/out"; then return 0; fi
  echo "--- $name: exit $rc, wanted ${want}"; cat "$T/out"; return 1
}
called() { grep -q -- "$1" "$LOG"; }
result() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
# Each case body is one && chain: set -e does not apply under `|| rc=$?`.
t() { local name=$1; shift; local rc=0; "$@" || rc=$?; result "$rc" "$name"; }

# H1: lookup errors other than NotFound stop daily-stop before the node groups go to 0.
t "stop aborts on Forbidden lookup" eval '
  check forbidden daily-stop "cannot read petclinic cronjob/db-backup" \
    KUBECTL_GET_ERROR="Error from server (Forbidden): cronjobs.batch is forbidden" &&
  ! called update-nodegroup-config && ! called stop-db-instance'
t "stop skips NotFound resources and continues" eval '
  rm -f "$STATE" && check notfound daily-stop ok KUBECTL_GET_ERROR="$NOTFOUND" &&
  grep -q "skip: petclinic cronjob/db-backup not found" "$T/out" && called "update-nodegroup-config.*ng-critical"'
t "stop rejects non-numeric scalingConfig" eval '
  check bad-scaling daily-stop "unexpected scalingConfig" NG_SCALING="None None None" KUBECTL_GET_ERROR="$NOTFOUND" &&
  ! called update-nodegroup-config'

# H1: daily-start treats a missing required resource as a failed restore, not a skip.
t "start fails on missing deployment" eval '
  rm -f "$STATE" &&
  check missing daily-start "$NOTFOUND" RDS_STATUS=available NG_SCALING="2 2 4" KUBECTL_GET_ERROR="$NOTFOUND" &&
  ! grep -q "== Restored" "$T/out"'
t "start rejects non-numeric replicas" eval '
  check bad-replicas daily-start "unexpected replicas" RDS_STATUS=available NG_SCALING="2 2 4" REPLICAS=abc'

# M1: stopping waits for stopped, then starts.
t "start waits for stopping RDS, then starts it" eval '
  check stopping daily-start ok RDS_STATUS=stopping NG_SCALING="0 0 4" &&
  [ "$(grep -o -e "wait db-instance-stopped" -e "start-db-instance" "$LOG" | tr "\n" " ")" = "wait db-instance-stopped start-db-instance " ]'

# M3: maxSize alone differing is restored; a full match is left alone.
t "start restores maxSize when only it differs" eval '
  check maxsize daily-start ok RDS_STATUS=available NG_SCALING="2 2 2" &&
  called "ng-critical --scaling-config minSize=2,desiredSize=2,maxSize=4"'
t "start is a no-op on a running environment" eval '
  check noop daily-start ok RDS_STATUS=available NG_SCALING="2 2 4" REPLICAS=3 &&
  ! called update-nodegroup-config && ! called start-db-instance && ! called " scale "'
t "start rejects desired > max from env" eval '
  check bad-env daily-start "invalid size for ng-critical" RDS_STATUS=available NG_CRITICAL_DESIRED_SIZE=9 &&
  ! called update-nodegroup-config'

# M2: state file save / keep / restore / reject.
t "stop saves the original size" eval '
  rm -f "$STATE" && check save daily-stop ok NG_SCALING="1 3 5" KUBECTL_GET_ERROR="$NOTFOUND" &&
  [ "$(jq -c ".\"ng-critical\"" "$STATE")" = "{\"minSize\":1,\"desiredSize\":3,\"maxSize\":5}" ]'
t "stop re-run at 0 keeps the saved size" eval '
  check rerun daily-stop ok NG_SCALING="0 0 5" KUBECTL_GET_ERROR="$NOTFOUND" &&
  [ "$(jq -r ".\"ng-critical\".desiredSize" "$STATE")" = 3 ]'
t "start restores the saved size" eval '
  check restore daily-start ok RDS_STATUS=stopped NG_SCALING="0 0 5" &&
  called "ng-critical --scaling-config minSize=1,desiredSize=3,maxSize=5"'
t "start rejects a corrupt state file before any change" eval '
  echo "{broken" > "$STATE" && check corrupt daily-start "cannot parse" RDS_STATUS=available NG_SCALING="0 0 5" &&
  ! called update-nodegroup-config'
t "start rejects a saved desiredSize of 0" eval '
  echo "{\"ng-critical\":{\"minSize\":0,\"desiredSize\":0,\"maxSize\":4}}" > "$STATE" &&
  check zero daily-start "invalid size for ng-critical" RDS_STATUS=available NG_SCALING="0 0 4" &&
  ! called update-nodegroup-config'
t "stop refuses to overwrite a corrupt state file" eval '
  echo "{broken" > "$STATE" &&
  check stop-corrupt daily-stop "cannot update" NG_SCALING="2 2 4" KUBECTL_GET_ERROR="$NOTFOUND" &&
  ! called update-nodegroup-config'

(( fails == 0 )) || { echo "$fails case(s) failed"; exit 1; }
echo "OK: daily stop/start offline tests"
