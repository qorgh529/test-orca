#!/usr/bin/env bash
# Unit-test the PetClinic alert rules with promtool (needs promtool, python3 + PyYAML; no cluster).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python3}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# promtool reads plain rule files: take spec from the PrometheusRule.
"$PY" -c 'import sys, yaml; yaml.safe_dump(yaml.safe_load(open(sys.argv[1], encoding="utf-8"))["spec"], open(sys.argv[2], "w"))' \
  "$ROOT/k8s/monitoring/prometheusrule-petclinic.yaml" "$tmp/rules.yaml"
cp "$ROOT/tests/monitoring/petclinic-rules.test.yaml" "$tmp/"
cd "$tmp"
promtool check rules rules.yaml
promtool test rules petclinic-rules.test.yaml
