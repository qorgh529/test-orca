#!/usr/bin/env bash
# Morning start (docs/features/daily-stop-start/design.md §3.3): RDS start first (it is slowest),
# node groups back to their saved size, then Karpenter pools, gateway, app and backup CronJob.
# Idempotent. --dry-run prints the commands and calls neither AWS nor the cluster.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() { echo "usage: $0 [--dry-run] [-h|--help]"; }
DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

require AWS_REGION EKS_CLUSTER_NAME
RDS_INSTANCE_ID="${RDS_INSTANCE_ID:-${EKS_CLUSTER_NAME}-mysql}"
STATE="$ROOT/.daily-nodegroup-state.json"
export AWS_REGION
if (( ! DRY_RUN )); then
  for c in aws kubectl jq envsubst; do command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }; done
fi

run() { if (( DRY_RUN )); then echo "[DRY-RUN] $*"; else "$@"; fi; }

# Every resource below is required: any kubectl error (NotFound included) fails the restore via set -e.
# Scale up to n only when below n, so replicas an autoscaler already added are kept.
scale_min() {
  local ns=$1 d=$2 n=$3 cur
  if (( DRY_RUN )); then run kubectl -n "$ns" scale "deploy/$d" --replicas="$n"; return; fi
  cur=$(kubectl -n "$ns" get deploy "$d" -o jsonpath='{.spec.replicas}')
  [[ "$cur" =~ ^[0-9]+$ ]] || { echo "unexpected replicas for $ns deploy/$d: '$cur'" >&2; exit 1; }
  if (( cur >= n )); then echo "$ns deploy/$d at $cur replicas, kept"; return 0; fi
  kubectl -n "$ns" scale "deploy/$d" --replicas="$n"
}

# Target "min desired max" for a node group: saved state, else NG_<NAME>_* env, else 2/2/4.
# A state file that cannot be read fails here, before any change: its sizes are unknown.
target_size() {
  local ng=$1 v p
  if [ -f "$STATE" ]; then
    command -v jq >/dev/null || { echo "jq is required to read $(basename "$STATE")" >&2; exit 1; }
    v=$(jq -r --arg ng "$ng" '.[$ng] // empty | "\(.minSize) \(.desiredSize) \(.maxSize)"' "$STATE") \
      || { echo "cannot parse $(basename "$STATE"): fix or remove it, then re-run" >&2; exit 1; }
    if [ -n "$v" ]; then echo "$v"; return; fi
  fi
  p=$(echo "${ng#ng-}" | tr '[:lower:]' '[:upper:]')
  local min="NG_${p}_MIN_SIZE" d="NG_${p}_DESIRED_SIZE" max="NG_${p}_MAX_SIZE"
  echo "${!min:-2} ${!d:-2} ${!max:-4}"
}

notice() {
  cat <<EOF
== Notice: Non-stoppable resources & remaining costs ($AWS_REGION) ==
  - EKS Control Plane ($EKS_CLUSTER_NAME): cannot be stopped (~\$0.10/hr, ~\$2.40/day)
  - NAT Gateway (VPC public subnets, 2 AZs): cannot be stopped (~\$0.059/hr per NAT GW, ~\$2.83/day for 2 AZs + data processing)
  - Application Load Balancer (petclinic-alb): kept active with Ingress (~\$0.0252/hr, ~\$0.60/day + LCU)
  - Persistent Storage & Edge (EBS gp3 PVCs, RDS gp3 storage, WAFv2 WebACL, Route 53, Secrets Manager): billed while stopped
  - RDS Auto-Start Note: AWS automatically restarts a stopped RDS instance after 7 consecutive days.
EOF
}

echo "== 1/4 RDS $RDS_INSTANCE_ID start"
if (( DRY_RUN )); then
  st=stopped; echo "[DRY-RUN] assuming RDS status: $st"
else
  st=$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
fi
case "$st" in
  stopped|stopping)
    # A stop still in progress (start right after daily-stop.sh) must finish before start is accepted.
    if [ "$st" = stopping ]; then
      run aws rds wait db-instance-stopped --db-instance-identifier "$RDS_INSTANCE_ID"
    fi
    run aws rds start-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" \
      --query 'DBInstance.DBInstanceStatus' --output text ;;
  *) echo "RDS is $st: start not requested" ;;
esac

echo "== 2/4 Managed node groups"
changed=()
for ng in ng-critical ng-platform; do
  sz=$(target_size "$ng")
  read -r min desired max <<<"$sz"
  if ! [[ "$min $desired $max" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || (( desired < 1 || min > desired || desired > max )); then
    echo "invalid size for $ng: min=$min desired=$desired max=$max (check $(basename "$STATE") / NG_* env)" >&2
    exit 1
  fi
  if (( DRY_RUN )); then
    cur="0 0 4"; echo "[DRY-RUN] assuming $ng min/desired/max: $cur"
  else
    cur=$(aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng" \
      --query 'nodegroup.scalingConfig.[minSize,desiredSize,maxSize]' --output text | tr -s '\t ' ' ')
  fi
  if [ "$cur" = "$min $desired $max" ]; then echo "$ng already $min/$desired/$max"; continue; fi
  run aws eks update-nodegroup-config --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng" \
    --scaling-config "minSize=$min,desiredSize=$desired,maxSize=$max" --query 'update.status' --output text
  changed+=("$ng")
done
for ng in "${changed[@]}"; do
  run aws eks wait nodegroup-active --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$ng"
done
run aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
for c in kube-system/coredns kube-system/karpenter kube-system/aws-load-balancer-controller \
         external-secrets/external-secrets keda/keda-operator; do
  run kubectl -n "${c%/*}" rollout status "deploy/${c#*/}" --timeout=600s
done

echo "== 3/4 Wait for RDS available"
run aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"

echo "== 4/4 Karpenter pools, gateway, app, backup"
if (( DRY_RUN )); then
  echo "[DRY-RUN] render infra/karpenter/nodepool-app.yaml | kubectl apply -f -"
else
  render "$ROOT/infra/karpenter/nodepool-app.yaml" | kubectl apply -f -
fi
scale_min nginx-gateway nginx-gateway 2
scale_min nginx-gateway petclinic-gateway-nginx 2
run kubectl -n nginx-gateway rollout status deploy/nginx-gateway --timeout=300s
run kubectl -n nginx-gateway rollout status deploy/petclinic-gateway-nginx --timeout=300s
# Unpause KEDA first: while paused-replicas=0 is set it would hold was-* at 0.
for so in was-stable was-canary; do
  run kubectl -n petclinic annotate "scaledobject/$so" autoscaling.keda.sh/paused-replicas- autoscaling.keda.sh/paused-
done
scale_min petclinic was-stable 2
scale_min petclinic was-canary 1
scale_min petclinic web 2
scale_min petclinic web-canary 1
run kubectl apply -f "$ROOT/k8s/web/hpa.yaml"
for d in was-stable web was-canary web-canary; do
  run kubectl -n petclinic rollout status "deploy/$d" --timeout=600s
done
run kubectl -n petclinic patch cronjob/db-backup -p '{"spec":{"suspend":false}}'

echo "== Restored: RDS $RDS_INSTANCE_ID, node groups ng-critical/ng-platform, Karpenter np-app/np-app-spot, gateway, web/was, db-backup"
notice
