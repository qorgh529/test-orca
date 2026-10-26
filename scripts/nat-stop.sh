#!/usr/bin/env bash
# Evening NAT stop (docs/features/vpc-provisioning/design.md §3.3), after scripts/daily-stop.sh:
# delete the petclinic NAT gateways and release their EIPs (~$2.83/day for two). The app route tables
# keep pointing at the deleted NATs until scripts/nat-start.sh repoints them.
# Refuses while EC2 instances still run in petclinic-vpc (their egress would break); --force skips that.
# Idempotent. --dry-run prints the plan and calls no AWS API.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() { echo "usage: $0 [--dry-run] [--force] [-h|--help]"; }
DRY_RUN=0 FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
P=petclinic

if (( DRY_RUN )); then
  echo "[DRY-RUN] delete NAT gateways tagged Project=$P in $P-vpc, wait until deleted, release their unattached EIPs"
  exit 0
fi

VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$P-vpc" "Name=tag:Project,Values=$P" \
  --query 'Vpcs[0].VpcId' --output text)
if [ -z "$VPC" ] || [ "$VPC" = None ]; then echo "no VPC tagged $P-vpc in $AWS_REGION: nothing to stop"; exit 0; fi

if (( ! FORCE )); then
  n=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" Name=instance-state-name,Values=pending,running,stopping \
    --query 'length(Reservations[].Instances[])' --output text)
  if [ "$n" != 0 ]; then
    echo "$n EC2 instance(s) still running in $VPC: deleting the NATs would cut their egress." >&2
    echo "Run scripts/daily-stop.sh first and re-run, or pass --force." >&2
    exit 1
  fi
fi

# Deleting ones (an earlier run) are waited for too, so their EIPs are free below.
nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=tag:Project,Values=$P" \
  Name=state,Values=available,pending,deleting --query 'NatGateways[].[NatGatewayId,State]' --output text)
if [ -z "$nats" ]; then
  echo "no NAT gateways"
else
  while read -r id st; do
    [ "$st" = deleting ] || aws ec2 delete-nat-gateway --nat-gateway-id "$id" >/dev/null
    echo "deleting $id"
  done <<<"$nats"
  # shellcheck disable=SC2046  # one argument per NAT id
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids $(cut -f1 <<<"$nats")
fi

# Only EIPs no longer attached to anything: never pull an address out from under a live resource.
for a in $(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$P" \
    --query 'Addresses[?AssociationId==null].AllocationId' --output text); do
  aws ec2 release-address --allocation-id "$a"
  echo "released $a"
done
left=$(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$P" \
  --query 'length(Addresses[?AssociationId!=null])' --output text)
[ "$left" = 0 ] || echo "note: $left EIP(s) tagged Project=$P are still attached and were kept"
echo "NAT gateways stopped"
