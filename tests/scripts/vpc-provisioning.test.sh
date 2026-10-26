#!/usr/bin/env bash
# Offline regression test for `provision-aws-resources.sh vpc` and scripts/nat-{start,stop}.sh
# (docs/features/vpc-provisioning/design.md). aws is a stateful fake on PATH: created resources are
# kept as files under $DB, so a second run sees the first run's resources. No AWS account needed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/infra/aws" "$T/scripts" "$T/bin"
cp "$REPO/infra/aws/provision-aws-resources.sh" "$T/infra/aws/"
cp "$REPO/scripts/lib.sh" "$REPO/scripts/nat-start.sh" "$REPO/scripts/nat-stop.sh" "$T/scripts/"
DB="$T/db"
LOG="$T/calls.log"

# DB layout: vpc ("id cidr"), subnet.<name> ("id cidr az"), igw ("id vpc|None"), rt.<name> (id),
# assoc.<subnet-id> (rt id), route.<rt-id> ("gateway-id nat-id", None when unset),
# nat.<name> (id), eip.<name> ("alloc-id nat-id|None"). INSTANCES = running EC2 count.
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "region=$AWS_REGION aws $*" >> "$LOG"
a=" $* "
arg() { local v=${a#* $1 }; [ "$v" != "$a" ] && echo "${v%% *}"; }   # value after a flag
tagname() { grep -o 'Name=tag:Name,Values=[^ ]*' <<<"$a" | head -1 | cut -d= -f3; }
specname() { grep -o 'Key=Name,Value=[^}]*' <<<"$a" | head -1 | cut -d= -f3; }
q=$(arg --query)
none() { [[ "$q" == *"[0]"* ]] && echo None; }   # a [0] query on an empty list prints None; [] prints nothing
f() { [ -f "$DB/$1" ] && cat "$DB/$1"; }
case "$a" in
  *" describe-vpcs "*) if v=$(f vpc); then
      if [[ "$q" == *CidrBlock* ]]; then tr ' ' '\t' <<<"$v"; else cut -d' ' -f1 <<<"$v"; fi; else none; fi ;;
  *" create-vpc "*) echo "vpc-1 $(arg --cidr-block)" > "$DB/vpc"; echo vpc-1 ;;
  *" describe-subnets "*) if v=$(f "subnet.$(tagname)"); then
      if [[ "$q" == *CidrBlock* ]]; then tr ' ' '\t' <<<"$v"; else cut -d' ' -f1 <<<"$v"; fi; else none; fi ;;
  *" create-subnet "*) n=$(specname); echo "subnet-$n $(arg --cidr-block) $(arg --availability-zone)" > "$DB/subnet.$n"
    echo "subnet-$n" ;;
  *" describe-internet-gateways "*) if v=$(f igw); then tr ' ' '\t' <<<"$v"; else echo None; fi ;;
  *" create-internet-gateway "*) echo "igw-1 None" > "$DB/igw"; echo igw-1 ;;
  *" attach-internet-gateway "*) echo "$(arg --internet-gateway-id) $(arg --vpc-id)" > "$DB/igw" ;;
  *" describe-route-tables "*"--route-table-ids "*) r=$(arg --route-table-ids)
    if v=$(f "route.$r"); then tr ' ' '\t' <<<"$v"; fi ;;
  *" describe-route-tables "*"association.subnet-id"*) s=$(grep -o 'association.subnet-id,Values=[^ ]*' <<<"$a" | cut -d= -f2)
    f "assoc.$s" || echo None ;;
  *" describe-route-tables "*) f "rt.$(tagname)" || echo None ;;
  *" create-route-table "*) n=$(specname); echo "rtb-$n" > "$DB/rt.$n"; echo "rtb-$n" ;;
  *" associate-route-table "*) echo "$(arg --route-table-id)" > "$DB/assoc.$(arg --subnet-id)"; echo '{}' ;;
  *" create-route "*|*" replace-route "*) r=$(arg --route-table-id)
    echo "$(arg --gateway-id || echo None) $(arg --nat-gateway-id || echo None)" > "$DB/route.$r" ;;
  *" describe-nat-gateways "*) if [[ "$q" == *State* ]]; then
      for n in "$DB"/nat.*; do [ -f "$n" ] && printf '%s\tavailable\n' "$(cat "$n")"; done
    else f "nat.$(tagname)" || echo None; fi ;;
  *" allocate-address "*) n=$(specname); echo "eipalloc-$n None" > "$DB/eip.$n"; echo "eipalloc-$n" ;;
  *" create-nat-gateway "*) n=$(specname); echo "nat-$n" > "$DB/nat.$n"
    for e in "$DB"/eip.*; do read -r id _ < "$e"; [ "$id" = "$(arg --allocation-id)" ] && echo "$id nat-$n" > "$e"; done
    echo "nat-$n" ;;
  *" delete-nat-gateway "*) id=$(arg --nat-gateway-id); rm -f "$DB/nat.${id#nat-}"
    for e in "$DB"/eip.*; do read -r al at < "$e"; [ "$at" = "$id" ] && echo "$al None" > "$e"; done; true ;;
  *" describe-addresses "*) free=(); used=0
    for e in "$DB"/eip.*; do [ -f "$e" ] || continue; read -r al at < "$e"
      if [ "$at" = None ]; then free+=("$al"); else used=$((used + 1)); fi; done
    if [[ "$q" == length* ]]; then echo "$used"
    elif [[ "$q" == *"[0]"* ]]; then n=$(tagname); if [ -f "$DB/eip.$n" ] && read -r al at < "$DB/eip.$n" && [ "$at" = None ]; then echo "$al"; else echo None; fi
    else echo "${free[*]}"; fi ;;
  *" release-address "*) for e in "$DB"/eip.*; do read -r al _ < "$e"; [ "$al" = "$(arg --allocation-id)" ] && rm -f "$e"; done; true ;;
  *" describe-instances "*) echo "${INSTANCES:-0}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/aws"
export LOG DB PATH="$T/bin:$PATH"

fails=0
# run <expect: ok | error text> <script> [args]: fresh call log, shell region forced to us-east-1.
run() {
  local want=$1 rc=0; shift
  : > "$LOG"
  env AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 bash "$@" < /dev/null > "$T/out" 2>&1 || rc=$?
  if [ "$want" = ok ] && [ "$rc" = 0 ]; then return 0; fi
  if [ "$want" != ok ] && [ "$rc" != 0 ] && grep -qF -- "$want" "$T/out"; then return 0; fi
  echo "--- exit $rc, wanted ${want}"; cat "$T/out"; return 1
}
VPC="$T/infra/aws/provision-aws-resources.sh vpc"
called() { grep -q -- "$1" "$LOG"; }
count() { grep -c -- "$1" "$LOG" || true; }
fresh() { rm -rf "$DB"; mkdir -p "$DB"; }
result() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
t() { local name=$1; shift; local rc=0; "$@" || rc=$?; result "$rc" "$name"; }

t "vpc builds everything from nothing in ap-northeast-2" eval '
  fresh && run ok $VPC &&
  [ "$(count " create-vpc ")" = 1 ] && [ "$(count " create-subnet ")" = 6 ] &&
  [ "$(count " create-route-table ")" = 4 ] && [ "$(count " create-nat-gateway ")" = 2 ] &&
  [ "$(count " allocate-address ")" = 2 ] && called "attach-internet-gateway --internet-gateway-id igw-1 --vpc-id vpc-1" &&
  ! grep -v "^region=ap-northeast-2 " "$LOG" | grep -q . &&
  called "create-subnet --vpc-id vpc-1 --cidr-block 10.0.16.0/20 --availability-zone ap-northeast-2a" &&
  called "create-subnet --vpc-id vpc-1 --cidr-block 10.0.49.0/24 --availability-zone ap-northeast-2c"'
t "vpc routes: public -> IGW, app -> NAT in its AZ, db has none" eval '
  [ "$(cat "$DB/route.rtb-petclinic-rt-public")" = "igw-1 None" ] &&
  [ "$(cat "$DB/route.rtb-petclinic-rt-app-2a")" = "None nat-petclinic-nat-2a" ] &&
  [ "$(cat "$DB/route.rtb-petclinic-rt-app-2c")" = "None nat-petclinic-nat-2c" ] &&
  [ ! -f "$DB/route.rtb-petclinic-rt-db" ] &&
  [ "$(cat "$DB/assoc.subnet-petclinic-db-2c")" = rtb-petclinic-rt-db ] &&
  [ "$(cat "$DB/assoc.subnet-petclinic-public-2a")" = rtb-petclinic-rt-public ]'
t "vpc prints the seven .env lines" eval '
  grep -qx "VPC_ID=vpc-1" "$T/out" && grep -qx "PUBLIC_SUBNET_C_ID=subnet-petclinic-public-2c" "$T/out" &&
  grep -qx "APP_PRIVATE_SUBNET_A_ID=subnet-petclinic-app-2a" "$T/out" &&
  grep -qx "DB_PRIVATE_SUBNET_C_ID=subnet-petclinic-db-2c" "$T/out" && [ "$(grep -c "^[A-Z_]*_ID=" "$T/out")" = 7 ]'
t "vpc re-run reuses everything and changes nothing" eval '
  run ok $VPC && grep -q "reusing vpc-1" "$T/out" && grep -qx "VPC_ID=vpc-1" "$T/out" &&
  ! grep -E " (create|allocate|associate|attach|replace)-" "$LOG"'
t "vpc stops on a petclinic-vpc with another CIDR" eval '
  fresh && echo "vpc-9 10.20.0.0/16" > "$DB/vpc" && run "is 10.20.0.0/16, not 10.0.0.0/16" $VPC && ! called " create-"'
t "vpc stops on a subnet with another CIDR" eval '
  fresh && echo "vpc-1 10.0.0.0/16" > "$DB/vpc" &&
  echo "subnet-x 10.0.2.0/24 ap-northeast-2a" > "$DB/subnet.petclinic-public-2a" &&
  run "petclinic-public-2a exists as 10.0.2.0/24 ap-northeast-2a" $VPC && ! called " create-subnet "'
t "vpc stops on a subnet tied to another route table" eval '
  fresh && run ok $VPC && echo rtb-other > "$DB/assoc.subnet-petclinic-db-2a" &&
  run "subnet subnet-petclinic-db-2a is associated with rtb-other" $VPC && ! called " associate-route-table "'

t "nat-stop refuses while instances run" eval '
  fresh && run ok $VPC && INSTANCES=3 run "3 EC2 instance(s) still running" "$T/scripts/nat-stop.sh" &&
  ! called delete-nat-gateway && ! called release-address'
t "nat-stop deletes both NATs, waits, releases their EIPs" eval '
  run ok "$T/scripts/nat-stop.sh" && [ "$(count " delete-nat-gateway ")" = 2 ] &&
  called "wait nat-gateway-deleted --nat-gateway-ids nat-petclinic-nat-2a nat-petclinic-nat-2c" &&
  [ "$(count " release-address ")" = 2 ] && ! ls "$DB"/nat.* "$DB"/eip.* 2>/dev/null &&
  ! grep -v "^region=ap-northeast-2 " "$LOG" | grep -q .'
t "nat-stop re-run is a no-op" eval '
  run ok "$T/scripts/nat-stop.sh" && grep -q "no NAT gateways" "$T/out" && ! called delete-nat-gateway && ! called release-address'
t "nat-start recreates NATs and repoints the blackholed app routes" eval '
  echo "None nat-old" > "$DB/route.rtb-petclinic-rt-app-2a" &&
  run ok "$T/scripts/nat-start.sh" && [ "$(count " create-nat-gateway ")" = 2 ] &&
  called "replace-route --route-table-id rtb-petclinic-rt-app-2a --destination-cidr-block 0.0.0.0/0 --nat-gateway-id nat-petclinic-nat-2a" &&
  [ "$(cat "$DB/route.rtb-petclinic-rt-app-2c")" = "None nat-petclinic-nat-2c" ] && ! called " create-route "'
t "nat-start keeps running NATs" eval '
  run ok "$T/scripts/nat-start.sh" && ! called create-nat-gateway && ! called allocate-address && ! called replace-route'
t "nat-start reuses an unattached EIP from a failed run" eval '
  fresh && run ok $VPC && run ok "$T/scripts/nat-stop.sh" && echo "eipalloc-left None" > "$DB/eip.petclinic-nat-2a" &&
  run ok "$T/scripts/nat-start.sh" && [ "$(count " allocate-address ")" = 1 ] &&
  called "create-nat-gateway --subnet-id subnet-petclinic-public-2a --allocation-id eipalloc-left"'
t "nat-start fails without the VPC" eval '
  fresh && run "no VPC tagged petclinic-vpc in ap-northeast-2" "$T/scripts/nat-start.sh" && ! called create-nat-gateway'
t "nat-stop without the VPC is a no-op" eval '
  fresh && run ok "$T/scripts/nat-stop.sh" && grep -q "nothing to stop" "$T/out"'
t "--dry-run calls no AWS API" eval '
  run ok "$T/scripts/nat-start.sh" --dry-run && [ ! -s "$LOG" ] && run ok "$T/scripts/nat-stop.sh" --dry-run && [ ! -s "$LOG" ]'

(( fails == 0 )) || { echo "$fails case(s) failed"; exit 1; }
echo "OK: vpc provisioning offline tests"
