#!/usr/bin/env bash
# Morning NAT start (docs/features/vpc-provisioning/design.md §3.4), before scripts/daily-start.sh:
# one EIP + NAT gateway per AZ in petclinic-public-2<az>, and petclinic-rt-app-2<az> 0.0.0.0/0 pointed
# at it. Also the NAT step of `provision-aws-resources.sh vpc`. Idempotent: a NAT that is already
# up is kept (its route is still checked), and an unattached EIP left by a failed run is reused.
# --dry-run prints the plan and calls no AWS API.
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

# The subnets are in Seoul; .env or the shell must not send this anywhere else.
export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
P=petclinic

if (( DRY_RUN )); then
  for az in a c; do
    echo "[DRY-RUN] $P-nat-2$az: EIP + NAT gateway in $P-public-2$az, $P-rt-app-2$az 0.0.0.0/0 -> NAT"
  done
  exit 0
fi

# lookup <describe-what> <name> <query>: one resource by Name tag inside petclinic-vpc ("" when missing).
lookup() {
  local id
  id=$(aws ec2 "describe-$1" --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$2" --query "$3" --output text)
  [ "$id" = None ] && id=""
  echo "$id"
}

VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$P-vpc" "Name=tag:Project,Values=$P" \
  --query 'Vpcs[0].VpcId' --output text)
[ -n "$VPC" ] && [ "$VPC" != None ] \
  || { echo "no VPC tagged $P-vpc in $AWS_REGION: run ./infra/aws/provision-aws-resources.sh vpc first" >&2; exit 1; }

for az in a c; do
  name="$P-nat-2$az"
  pub=$(lookup subnets "$P-public-2$az" 'Subnets[0].SubnetId')
  rt=$(lookup route-tables "$P-rt-app-2$az" 'RouteTables[0].RouteTableId')
  [ -n "$pub" ] && [ -n "$rt" ] || { echo "$P-public-2$az or $P-rt-app-2$az missing in $VPC" >&2; exit 1; }

  nat=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$name" \
    Name=state,Values=available,pending --query 'NatGateways[0].NatGatewayId' --output text)
  if [ -z "$nat" ] || [ "$nat" = None ]; then
    eip=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$name" "Name=tag:Project,Values=$P" \
      --query 'Addresses[?AssociationId==null].AllocationId | [0]' --output text)
    if [ -z "$eip" ] || [ "$eip" = None ]; then
      eip=$(aws ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$name},{Key=Project,Value=$P}]" \
        --query AllocationId --output text)
    fi
    nat=$(aws ec2 create-nat-gateway --subnet-id "$pub" --allocation-id "$eip" \
      --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=$name},{Key=Project,Value=$P}]" \
      --query NatGateway.NatGatewayId --output text)
    echo "$name: creating $nat"
  else
    echo "$name: $nat exists"
  fi
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat"

  # After nat-stop.sh the route still names the deleted NAT (blackhole): repoint it.
  cur=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[GatewayId,NatGatewayId]" --output text)
  if [ -z "$cur" ]; then
    aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat" >/dev/null
  elif ! grep -qw -- "$nat" <<<"$cur"; then
    aws ec2 replace-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat"
  fi
  echo "$name: up, $P-rt-app-2$az 0.0.0.0/0 -> $nat"
done
