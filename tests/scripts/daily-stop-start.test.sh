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

# Fakes answer from env: RDS_STATUS, NG_SCALING ("min desired max"), UPDATE_STATUS, REPLICAS,
# and KUBECTL_GET_ERROR (stderr text; makes every kubectl get fail).
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$LOG"
case "$*" in
  *describe-db-instances*) echo "${RDS_STATUS:-available}" ;;
  *update-nodegroup-config*) a="$*"; ng=${a##*--nodegroup-name }; echo "upd-${ng%% *}" ;;
  *describe-update*) echo "${UPDATE_STATUS:-Successful}" ;;
  # Return only as many fields as the --query asks for ([minSize,desiredSize] -> 2).
  *describe-nodegroup*) n=$(grep -o ',' <<<"${*##*--query}" | wc -l)
    echo "${NG_SCALING:-2 2 4}" | cut -d' ' -f1-$((n + 1)) | tr ' ' '\t' ;;
esac
EOF
cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$LOG"
# Only `apply -f -` gets piped input; reading stdin otherwise hangs when it is an open pipe.
[[ " $* " == *" -f - "* ]] && cat >/dev/null
if [[ " $* " == *" get "* ]]; then
  if [ -n "${KUBECTL_GET_ERROR:-}" ]; then echo "$KUBECTL_GET_ERROR" >&2; exit 1; fi
  [[ "$*" == *jsonpath* ]] && echo "${REPLICAS:-0}"
fi
exit 0
EOF
# nat-{stop,start}.sh have their own test (vpc-provisioning.test.sh): here they only log when called.
for n in nat-stop nat-start; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\n' "$n" > "$T/scripts/$n.sh"
done
chmod +x "$T/bin/aws" "$T/bin/kubectl"
export LOG PATH="$T/bin:$PATH" AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=test-eks
NOTFOUND='Error from server (NotFound): resource not found'

fails=0
# check <name> <script> <expect: ok | error text> [--flag ...] [VAR=value ...] — fresh call log; then extra asserts via `called`.
check() {
  local name=$1 script=$2 want=$3 rc=0 flags=(); shift 3
  while [[ "${1:-}" == --* ]]; do flags+=("$1"); shift; done
  : > "$LOG"
  env "$@" bash "$T/scripts/$script.sh" "${flags[@]}" < /dev/null > "$T/out" 2>&1 || rc=$?
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

# GitHub Codex P2: a node group update that EKS accepts but then fails is an error, not "done".
t "stop fails when a node group update fails" eval '
  rm -f "$STATE" &&
  check stop-update-failed daily-stop "ng-critical update upd-ng-critical: Failed" NG_SCALING="2 2 4" UPDATE_STATUS=Failed KUBECTL_GET_ERROR="$NOTFOUND" &&
  ! grep -q "Non-stoppable resources" "$T/out"'
t "start fails when a node group update fails" eval '
  rm -f "$STATE" &&
  check start-update-failed daily-start "ng-critical update upd-ng-critical: Failed" RDS_STATUS=available NG_SCALING="0 0 4" UPDATE_STATUS=Failed &&
  ! grep -q "== Restored" "$T/out"'
t "stop and start track each update to Successful" eval '
  rm -f "$STATE" && check stop-update-ok daily-stop ok NG_SCALING="2 2 4" KUBECTL_GET_ERROR="$NOTFOUND" &&
  called "describe-update.*ng-critical --update-id upd-ng-critical" &&
  called "describe-update.*ng-platform --update-id upd-ng-platform" &&
  rm -f "$STATE" && check start-update-ok daily-start ok RDS_STATUS=available NG_SCALING="0 0 4" &&
  called "describe-update.*ng-platform --update-id upd-ng-platform" && ! called "wait nodegroup-active"'

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
t "start leaves a stopped RDS alone when the state file is corrupt" eval '
  echo "{broken" > "$STATE" && check corrupt-rds daily-start "cannot parse" RDS_STATUS=stopped NG_SCALING="0 0 5" &&
  ! called start-db-instance && ! called update-nodegroup-config'
t "start rejects a saved desiredSize of 0" eval '
  echo "{\"ng-critical\":{\"minSize\":0,\"desiredSize\":0,\"maxSize\":4}}" > "$STATE" &&
  check zero daily-start "invalid size for ng-critical" RDS_STATUS=available NG_SCALING="0 0 4" &&
  ! called update-nodegroup-config'
t "stop refuses to overwrite a corrupt state file" eval '
  echo "{broken" > "$STATE" &&
  check stop-corrupt daily-stop "cannot update" NG_SCALING="2 2 4" KUBECTL_GET_ERROR="$NOTFOUND" &&
  ! called update-nodegroup-config'

# apm-tracing: the injection webhook is fail-open, so the operator must be up before was is scaled.
t "start waits for the OTel operator before scaling was" eval '
  rm -f "$STATE" && check otel-order daily-start ok RDS_STATUS=available NG_SCALING="0 0 4" &&
  op=$(grep -n "opentelemetry-operator-system rollout status deploy/opentelemetry-operator" "$LOG" | cut -d: -f1) &&
  was=$(grep -n "scale deploy/was-stable" "$LOG" | head -1 | cut -d: -f1) && [ -n "$op" ] && [ "$op" -lt "$was" ]'

# vpc-provisioning: NAT goes last on stop (nodes gone) and first on start (nodes need egress), only on request.
t "stop leaves NAT alone without --stop-nat" eval '
  rm -f "$STATE" && check no-nat-stop daily-stop ok NG_SCALING="2 2 4" KUBECTL_GET_ERROR="$NOTFOUND" && ! called nat-stop'
t "stop --stop-nat deletes NAT after the node groups are down" eval '
  rm -f "$STATE" && check nat-stop daily-stop ok --stop-nat NG_SCALING="2 2 4" KUBECTL_GET_ERROR="$NOTFOUND" &&
  ng=$(grep -n "describe-update.*ng-platform" "$LOG" | tail -1 | cut -d: -f1) &&
  nat=$(grep -n "^nat-stop" "$LOG" | cut -d: -f1) && [ -n "$nat" ] && [ "$ng" -lt "$nat" ] &&
  grep -q "deleted by --stop-nat" "$T/out"'
t "start --start-nat creates NAT before RDS and node groups" eval '
  rm -f "$STATE" && check nat-start daily-start ok --start-nat RDS_STATUS=stopped NG_SCALING="0 0 4" &&
  nat=$(grep -n "^nat-start" "$LOG" | cut -d: -f1) && rds=$(grep -n "start-db-instance" "$LOG" | cut -d: -f1) &&
  [ -n "$nat" ] && [ "$nat" -lt "$rds" ]'
t "start leaves NAT alone without --start-nat" eval '
  rm -f "$STATE" && check no-nat-start daily-start ok RDS_STATUS=stopped NG_SCALING="0 0 4" && ! called nat-start'

(( fails == 0 )) || { echo "$fails case(s) failed"; exit 1; }
echo "OK: daily stop/start offline tests"
