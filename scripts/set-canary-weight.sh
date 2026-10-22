#!/usr/bin/env bash
# Shift live traffic between web and web-canary without redeploying.
#   scripts/set-canary-weight.sh <canary-percent>
#   0 = rollback (all traffic to stable), e.g. 5 / 25 / 50 to widen, 100 = all traffic to canary.
# Promotion: once canary is trusted, redeploy with STABLE_IMAGE_TAG set to the canary tag.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || { echo "usage: $0 <canary-percent 0-100>" >&2; exit 1; }
[[ "$1" =~ ^[0-9]+$ ]] && (( $1 <= 100 )) || { echo "canary percent must be an integer 0-100 (got $1)" >&2; exit 1; }
canary=$1 stable=$((100 - $1))

require AWS_REGION EKS_CLUSTER_NAME
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"

apply_route_weights "$stable" "$canary"
echo "HTTPRoute petclinic: web $stable / web-canary $canary"
