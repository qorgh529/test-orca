#!/usr/bin/env bash
# Offline regression test for grafana_waf_ready (scripts/lib.sh): deploy-all.sh must not publish /grafana
# unless the WebACL blocks it for IPs outside the allow-list, ahead of every other rule. aws is a fake that
# serves the WebACL JSON given in $ACL. Needs jq; without it the test is skipped and says so.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP grafana_waf_ready offline tests: jq not installed"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *list-web-acls*) echo "${ACL_NAME-test-web-acl}" ;;
  *get-web-acl*) printf '%s\n' "$ACL" ;;
esac
EOF
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH" WAF_WEB_ACL_ARN=arn:test/webacl/test-web-acl/abc

export EKS_CLUSTER_NAME=test-eks
managed='{"Name":"AWSManagedRulesCommonRuleSet","Priority":1,"OverrideAction":{"None":{}},
  "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesCommonRuleSet"}}}'
# The rule as grafana-waf writes it and as `aws wafv2 get-web-acl` prints it (SearchString base64).
good=$(jq -nc '{Name: "BlockUnauthorizedGrafanaAccess", Priority: 0, Action: {Block: {}},
  Statement: {AndStatement: {Statements: [
    {ByteMatchStatement: {FieldToMatch: {UriPath: {}}, PositionalConstraint: "STARTS_WITH",
      SearchString: "L2dyYWZhbmE=", TextTransformations: [{Priority: 0, Type: "URL_DECODE"},
      {Priority: 1, Type: "NORMALIZE_PATH"}, {Priority: 2, Type: "LOWERCASE"}]}},
    {NotStatement: {Statement: {IPSetReferenceStatement:
      {ARN: "arn:aws:wafv2:r:a:regional/ipset/test-eks-grafana-allowed-ips/id"}}}}]}}}')
rule() { jq -c "$1" <<<"$good"; }  # a variant of the good rule
acl() { echo "{\"WebACL\":{\"Rules\":[$1]}}"; }

fail=0
check() {  # name, expected (ready|blocked)
  local got=blocked
  (. "$REPO/scripts/lib.sh" 2>/dev/null; export EKS_CLUSTER_NAME=test-eks; grafana_waf_ready) && got=ready
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $got)"; fail=1; fi
}

ACL=$(acl "$good,$managed") check "rule first, Block, AND(path, NOT our IP set)" ready
ACL=$(acl "$(rule '.Statement.AndStatement.Statements[0].ByteMatchStatement.SearchString = "/grafana"'),$managed") \
  check "SearchString printed raw" ready
ACL=$(acl "$managed") check "no /grafana rule" blocked
ACL=$(acl "$managed,$(rule '.Priority = 2')") check "rule behind a managed rule group" blocked
ACL=$(acl "$(rule '.Action = {Count: {}}'),$managed") check "rule only counts" blocked
ACL=$(acl "$(rule '.Statement = .Statement.AndStatement.Statements[1].NotStatement.Statement'),$managed") \
  check "IP set match without NOT (blocks the allowed IPs instead)" blocked
ACL=$(acl "$(rule '.Statement.AndStatement.Statements[1] = .Statement.AndStatement.Statements[1].NotStatement.Statement'),$managed") \
  check "NOT removed inside the AND" blocked
ACL=$(acl "$(rule '.Statement.AndStatement.Statements[0].ByteMatchStatement.SearchString = "L2FkbWlu"'),$managed") \
  check "path other than /grafana" blocked
ACL=$(acl "$(rule '.Statement.AndStatement.Statements[0].ByteMatchStatement.TextTransformations = [{Priority: 0, Type: "LOWERCASE"}]'),$managed") \
  check "no URL_DECODE / NORMALIZE_PATH" blocked
ACL=$(acl "$(rule '.Statement.AndStatement.Statements[1].NotStatement.Statement.IPSetReferenceStatement.ARN |= sub("test-eks-grafana"; "other")'),$managed") \
  check "a different IP set" blocked
ACL_NAME=None ACL=$(acl "$good") check "WebACL not found" blocked

[ "$fail" = 0 ] && echo "OK: grafana_waf_ready offline tests"
exit "$fail"
