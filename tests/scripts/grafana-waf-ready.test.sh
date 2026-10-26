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

managed='{"Name":"AWSManagedRulesCommonRuleSet","Priority":1,"OverrideAction":{"None":{}},
  "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesCommonRuleSet"}}}'
grafana() {  # $1 priority, $2 action
  echo "{\"Name\":\"BlockUnauthorizedGrafanaAccess\",\"Priority\":$1,\"Action\":{\"$2\":{}},
    \"Statement\":{\"AndStatement\":{\"Statements\":[{\"ByteMatchStatement\":{\"SearchString\":\"/grafana\"}},
    {\"NotStatement\":{\"Statement\":{\"IPSetReferenceStatement\":{\"ARN\":\"arn:test:ipset\"}}}}]}}}"
}
acl() { echo "{\"WebACL\":{\"Rules\":[$1]}}"; }

fail=0
check() {  # name, expected (ready|blocked)
  local got=blocked
  (. "$REPO/scripts/lib.sh" 2>/dev/null; grafana_waf_ready) && got=ready
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $got)"; fail=1; fi
}

ACL=$(acl "$(grafana 0 Block),$managed") check "rule first, Block, IP set" ready
ACL=$(acl "$managed") check "no /grafana rule" blocked
ACL=$(acl "$managed,$(grafana 2 Block)") check "rule behind a managed rule group" blocked
ACL=$(acl "$(grafana 0 Count),$managed") check "rule only counts" blocked
ACL=$(acl "$(grafana 0 Block | sed 's/IPSetReferenceStatement/Unused/'),$managed") check "rule without IP set" blocked
ACL_NAME=None ACL=$(acl "$(grafana 0 Block)") check "WebACL not found" blocked

[ "$fail" = 0 ] && echo "OK: grafana_waf_ready offline tests"
exit "$fail"
