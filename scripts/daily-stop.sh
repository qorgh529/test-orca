#!/usr/bin/env bash
# Evening stop (docs/features/daily-stop-start/design.md §3.2). Order matters: Karpenter runs on
# ng-critical, so app pods and Karpenter nodes go first, then RDS, then the managed node groups.
# Idempotent. --dry-run prints the commands and calls neither AWS nor the cluster.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() { echo "usage: $0 [--dry-run] [--stop-nat] [-h|--help]"; }
DRY_RUN=0 STOP_NAT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --stop-nat) STOP_NAT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

require AWS_REGION EKS_CLUSTER_NAME
RDS_INSTANCE_ID="${RDS_INSTANCE_ID:-${EKS_CLUSTER_NAME}-mysql}"
STATE="$ROOT/.daily-nodegroup-state.json"
export AWS_REGION
if (( ! DRY_RUN )); then
  for c in aws kubectl jq; do command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }; done
fi

run() { if (( DRY_RUN )); then echo "[DRY-RUN] $*"; else "$@"; fi; }

# Poll one node group update to completion. `aws eks wait nodegroup-active` only checks the node group
# status, so an update that EKS accepted but later failed would still look done.
wait_update() {
  local ng=$1 id=$2 st=unknown _
  if (( DRY_RUN )); then echo "[DRY-RUN] poll aws eks describe-update --nodegroup-name $ng until Successful"; return; fi
  for _ in $(seq 1 60); do
    st=$(aws eks describe-update --name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng" --update-id "$id" \
      --query 'update.status' --output text)
    case "$st" in
      Successful) echo "$ng update $id: Successful"; return 0 ;;
      Failed|Cancelled)
        echo "$ng update $id: $st" >&2
        aws eks describe-update --name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng" --update-id "$id" \
          --query 'update.errors' --output json >&2 || true
        exit 1 ;;
    esac
    sleep 15
  done
  echo "$ng update $id: still $st after 15 minutes" >&2; exit 1
}

# kubectl <verb> <resource> [args] in <ns> ("" = cluster scope), skipped only when the resource is NotFound.
# Any other lookup error (Forbidden, expired auth, API unreachable) aborts before the node groups go to 0.
kube() {
  local ns=$1 verb=$2 res=$3 err; shift 3
  local nsarg=(); [ -n "$ns" ] && nsarg=(-n "$ns")
  if (( ! DRY_RUN )) && ! err=$(kubectl "${nsarg[@]}" get "$res" 2>&1 >/dev/null); then
    if [[ "$err" == *"(NotFound)"* ]]; then echo "skip: ${ns:-cluster} $res not found"; return 0; fi
    echo "$err" >&2; echo "cannot read ${ns:-cluster} $res, stopping before any further change" >&2; exit 1
  fi
  run kubectl "${nsarg[@]}" "$verb" "$res" "$@"
}

nat_notice() {
  if (( STOP_NAT )); then
    echo "  - NAT Gateways (2 AZs): deleted by --stop-nat; recreate with scripts/nat-start.sh or daily-start.sh --start-nat"
  else
    echo "  - NAT Gateway (VPC public subnets, 2 AZs): still running (~\$0.059/hr per NAT GW, ~\$2.83/day for 2 AZs + data processing); delete with scripts/nat-stop.sh or daily-stop.sh --stop-nat"
  fi
}

notice() {
  cat <<EOF
== Notice: Non-stoppable resources & remaining costs ($AWS_REGION) ==
  - EKS Control Plane ($EKS_CLUSTER_NAME): cannot be stopped (~\$0.10/hr, ~\$2.40/day)
$(nat_notice)
  - Application Load Balancer (petclinic-alb): kept active with Ingress (~\$0.0252/hr, ~\$0.60/day + LCU)
  - Persistent Storage & Edge (EBS gp3 PVCs, RDS gp3 storage, WAFv2 WebACL, Route 53, Secrets Manager): billed while stopped
  - RDS Auto-Start Note: AWS automatically restarts a stopped RDS instance after 7 consecutive days.
EOF
}

run aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"

echo "== 1/3 App tier and Karpenter app nodes"
kube petclinic patch cronjob/db-backup -p '{"spec":{"suspend":true}}'
for so in was-stable was-canary; do
  kube petclinic annotate "scaledobject/$so" autoscaling.keda.sh/paused-replicas=0 --overwrite
done
run kubectl -n petclinic delete hpa web web-canary --ignore-not-found
for d in web web-canary was-stable was-canary; do kube petclinic scale "deploy/$d" --replicas=0; done
# Control plane first, or it scales its data plane back up.
kube nginx-gateway scale deploy/nginx-gateway --replicas=0
kube nginx-gateway scale deploy/petclinic-gateway-nginx --replicas=0
for np in np-app np-app-spot; do
  kube "" patch "nodepool/$np" --type merge -p '{"spec":{"limits":{"cpu":"0","memory":"0Gi"}}}'
done
run kubectl delete nodeclaim --all --wait=true --timeout=180s

echo "== 2/3 RDS $RDS_INSTANCE_ID"
if (( DRY_RUN )); then
  st=available; echo "[DRY-RUN] assuming RDS status: $st"
else
  st=$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
fi
case "$st" in
  available) run aws rds stop-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" \
               --query 'DBInstance.DBInstanceStatus' --output text ;;
  stopping|stopped) echo "RDS already $st" ;;
  *) echo "RDS is $st: not stopping now, re-run later" ;;
esac

echo "== 3/3 Managed node groups to 0"
updates=()
for ng in ng-critical ng-platform; do
  if (( DRY_RUN )); then
    sc="2 2 4"; echo "[DRY-RUN] assuming $ng min/desired/max: $sc"
  else
    sc=$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng" \
      --query 'nodegroup.scalingConfig.[minSize,desiredSize,maxSize]' --output text)
  fi
  read -r min desired max <<<"$sc"
  [[ "$min $desired $max" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] \
    || { echo "unexpected scalingConfig for $ng: '$sc'" >&2; exit 1; }
  if (( min == 0 && desired == 0 )); then echo "$ng already 0"; continue; fi
  # Keep the size from before the first stop: a re-run at desired 0 must not overwrite it.
  if (( desired > 0 )); then
    if (( DRY_RUN )); then
      echo "[DRY-RUN] save $ng $min/$desired/$max to ${STATE#"$ROOT"/}"
    else
      cur='{}'; [ -f "$STATE" ] && cur=$(cat "$STATE")
      if ! (umask 077; jq --arg ng "$ng" --argjson min "$min" --argjson d "$desired" --argjson max "$max" \
          '.[$ng] = {minSize: $min, desiredSize: $d, maxSize: $max}' <<<"$cur" > "$STATE.tmp"); then
        rm -f "$STATE.tmp"
        echo "cannot update ${STATE#"$ROOT"/} (corrupt JSON?): fix or remove it, then re-run" >&2; exit 1
      fi
      mv "$STATE.tmp" "$STATE"
    fi
  fi
  id=$(run aws eks update-nodegroup-config --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng" \
    --scaling-config "minSize=0,desiredSize=0,maxSize=$max" --query 'update.id' --output text)
  if (( DRY_RUN )); then echo "$id"; fi
  updates+=("$ng=$id")
done
for u in "${updates[@]}"; do
  wait_update "${u%%=*}" "${u#*=}"
done

# Last: the nodes are gone, so nothing loses egress (nat-stop.sh still refuses while instances run).
if (( STOP_NAT )); then
  echo "== NAT gateways"
  if (( DRY_RUN )); then bash "$ROOT/scripts/nat-stop.sh" --dry-run; else bash "$ROOT/scripts/nat-stop.sh"; fi
fi

notice
