#!/usr/bin/env bash
# Evening NAT stop (docs/features/vpc-provisioning/design.md §3.3), after scripts/daily-stop.sh:
# delete the petclinic NAT gateways and release their EIPs (~$2.83/day for two). The app route tables
# keep pointing at the deleted NATs until scripts/nat-start.sh repoints them.
# Only NAT addresses are released: the ones on the NATs deleted here, plus unattached ones named
# petclinic-nat-2a/2c (left by a failed nat-start). Other Project=petclinic EIPs are never touched.
# Waits up to NAT_STOP_INSTANCE_WAIT seconds (default 300) for EC2 instances in petclinic-vpc to go,
# then refuses (their egress would break); --force skips that. Idempotent. --dry-run calls no AWS API.
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
  echo "[DRY-RUN] delete NAT gateways tagged Project=$P in $P-vpc, wait until deleted, release their EIPs"
  exit 0
fi

VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$P-vpc" "Name=tag:Project,Values=$P" \
  --query 'Vpcs[0].VpcId' --output text)
if [ -z "$VPC" ] || [ "$VPC" = None ]; then echo "no VPC tagged $P-vpc in $AWS_REGION: nothing to stop"; exit 0; fi

# Node groups report scaled-in before their instances finish terminating: give them a few minutes.
if (( ! FORCE )); then
  wait_s=${NAT_STOP_INSTANCE_WAIT:-300}
  [[ "$wait_s" =~ ^[0-9]+$ ]] || { echo "NAT_STOP_INSTANCE_WAIT must be a number of seconds" >&2; exit 1; }
  end=$((SECONDS + wait_s))
  while :; do
    n=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" Name=instance-state-name,Values=pending,running,stopping \
      --query 'length(Reservations[].Instances[])' --output text)
    [ "$n" = 0 ] && break
    if (( SECONDS >= end )); then
      echo "$n EC2 instance(s) still running in $VPC after ${wait_s}s: deleting the NATs would cut their egress." >&2
      echo "Re-run once they are gone (scripts/daily-stop.sh first), or pass --force." >&2
      exit 1
    fi
    echo "waiting for $n instance(s) in $VPC to terminate"
    sleep 10
  done
fi

# Deleting ones (an earlier run) are waited for too. Their EIPs are read before the delete: a deleted
# NAT no longer lists them.
nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=tag:Project,Values=$P" \
  Name=state,Values=available,pending,deleting \
  --query 'NatGateways[].[NatGatewayId,State,NatGatewayAddresses[0].AllocationId]' --output text)
eips=()
if [ -z "$nats" ]; then
  echo "no NAT gateways"
else
  while read -r id st eip; do
    [ "$st" = deleting ] || aws ec2 delete-nat-gateway --nat-gateway-id "$id" >/dev/null
    [ -n "$eip" ] && [ "$eip" != None ] && eips+=("$eip")
    echo "deleting $id"
  done <<<"$nats"
  # shellcheck disable=SC2046  # one argument per NAT id
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids $(cut -f1 <<<"$nats")
fi

# Leftovers of a failed nat-start: unattached and named for a NAT. Assigned first so a failed call stops here.
left=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$P-nat-2a,$P-nat-2c" "Name=tag:Project,Values=$P" \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text)
for a in $left; do
  [[ " ${eips[*]} " == *" $a "* ]] || eips+=("$a")
done
for a in "${eips[@]}"; do
  aws ec2 release-address --allocation-id "$a"
  echo "released $a"
done
echo "NAT gateways stopped"
