#!/usr/bin/env bash
# Offline checks (no cluster needed). Requires python3 + PyYAML.
#   1. YAML syntax           2. no :latest / untagged images
#   3. no plaintext secrets  4. node-tier placement + non-root securityContext
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# .env is created by copying .env.example and is sourced by every script: it must source cleanly.
if ! (set -eu; set -a; . "$ROOT/.env.example") >/dev/null 2>&1; then
  echo "FAIL .env.example does not source cleanly (quote values containing spaces)"
  exit 1
fi

"${PYTHON:-python3}" - "$ROOT" <<'PY'
import pathlib, re, subprocess, sys
import yaml

root = pathlib.Path(sys.argv[1])
errors = []
def err(msg): errors.append(msg)

tracked = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True).stdout.split()
files = [root / f for f in tracked if not f.startswith("app/")]
yamls = [f for f in files if f.suffix in (".yaml", ".yml")]

# 1. YAML syntax
docs = {}
for f in yamls:
    try:
        docs[f] = [d for d in yaml.safe_load_all(f.read_text(encoding="utf-8")) if d]
    except yaml.YAMLError as e:
        err(f"{f.relative_to(root)}: invalid YAML: {e}")

# 2. Images pinned
def check_image(where, image):
    if "${" in image:
        if not image.endswith(":${IMAGE_TAG}"):
            err(f"{where}: templated image must use :${{IMAGE_TAG}}: {image}")
        return
    name = image.split("@")[0].rsplit("/", 1)[-1]
    if ":" not in name and "@" not in image:
        err(f"{where}: image has no tag: {image}")
    elif name.endswith(":latest"):
        err(f"{where}: image uses :latest: {image}")

for f in files:
    if f.name == "Dockerfile":
        for line in f.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*FROM\s+(\S+)", line, re.I)
            if m:
                check_image(f.relative_to(root), m.group(1))
for f, ds in docs.items():
    text = f.read_text(encoding="utf-8")
    for m in re.finditer(r"^\s*(?:-\s*)?image:\s*['\"]?([^\s'\"#]+)", text, re.M):
        check_image(f.relative_to(root), m.group(1))
    for d in ds:
        img = d.get("image") if isinstance(d, dict) else None
        if isinstance(img, dict) and "repository" in img:
            check_image(f.relative_to(root), f"{img['repository']}:{img.get('tag', '')}".rstrip(":"))

# 3. Plaintext secrets
if ".env" in tracked:
    err(".env is tracked by git")
secret_patterns = [
    (r"AKIA[0-9A-Z]{16}", "AWS access key id"),
    (r"(?i)aws_secret_access_key\s*[:=]", "AWS secret key"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key"),
    (r"(?i)\b(password|passwd|secret|token)\b(?::\s+|\s*=\s*)['\"]?(?![\s'\"]*$)(?!\$|\{\{|<|file:|env\.)[^\s'\"]{4,}", "hard-coded credential"),
    (r"\b\d{12}\b", "possible AWS account id"),
]
for f in files:
    if f.suffix in (".jar",) or f.name in (".env.example",) or f.parts[-2:] == ("docs", f.name):
        continue
    try:
        text = f.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for pat, what in secret_patterns:
        for m in re.finditer(pat, text):
            line = text[: m.start()].count("\n") + 1
            err(f"{f.relative_to(root)}:{line}: {what}: {m.group(0)[:40]}")
for f, ds in docs.items():
    for d in ds:
        if isinstance(d, dict) and d.get("kind") == "Secret" and (d.get("data") or d.get("stringData")):
            err(f"{f.relative_to(root)}: Secret with inline data (use ExternalSecret)")
# The MySQL (RDS) build profile must not carry credentials.
pom = (root / "app/pom.xml").read_text(encoding="utf-8")
mysql = re.search(r"<id>MySQL</id>.*?</profile>", pom, re.S)
if not mysql or re.search(r"<jdbc\.(username|password)>[^<]+</jdbc", mysql.group(0)):
    err("app/pom.xml: MySQL profile has hard-coded jdbc credentials")

# 4. Placement + securityContext
TIERS = {"app": None, "critical": "critical", "platform": "platform"}
def pod_spec(d):
    kind = d.get("kind")
    if kind in ("Deployment", "Job", "DaemonSet", "StatefulSet"):
        return d["spec"]["template"]["spec"]
    if kind == "CronJob":
        return d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None

def expect_tier(where, spec, tier):
    if (spec.get("nodeSelector") or {}).get("workload-tier") != tier:
        err(f"{where}: nodeSelector workload-tier != {tier}")
    taint = TIERS[tier]
    if taint and not any(t.get("key") == "node-role" and t.get("value") == taint
                         and t.get("effect") == "NoSchedule" for t in spec.get("tolerations") or []):
        err(f"{where}: missing toleration node-role={taint}:NoSchedule")

workloads = 0
for f, ds in docs.items():
    rel = f.relative_to(root)
    if rel.parts[0] != "k8s":
        continue
    for d in ds:
        if not isinstance(d, dict):
            continue
        spec = pod_spec(d)
        if spec is None:
            continue
        workloads += 1
        where = f"{rel}:{d['kind']}/{d['metadata']['name']}"
        expect_tier(where, spec, "critical" if rel.parts[1] == "jobs" else "app")
        psc = spec.get("securityContext") or {}
        if psc.get("runAsNonRoot") is not True or psc.get("runAsUser", 0) == 0:
            err(f"{where}: pod securityContext must set runAsNonRoot: true and a non-zero runAsUser")
        for c in (spec.get("initContainers") or []) + spec["containers"]:
            sc = c.get("securityContext") or {}
            if sc.get("allowPrivilegeEscalation") is not False:
                err(f"{where}/{c['name']}: allowPrivilegeEscalation must be false")
            if "ALL" not in ((sc.get("capabilities") or {}).get("drop") or []):
                err(f"{where}/{c['name']}: capabilities.drop must include ALL")
if workloads == 0:
    err("no workloads found under k8s/")

# Helm values: monitoring on ng-platform, Fluent Bit everywhere.
kps = docs.get(root / "k8s/monitoring/kube-prometheus-values.yaml", [{}])[0]
for name, spec in (("prometheus", kps.get("prometheus", {}).get("prometheusSpec", {})),
                   ("alertmanager", kps.get("alertmanager", {}).get("alertmanagerSpec", {})),
                   ("grafana", kps.get("grafana", {}))):
    expect_tier(f"kube-prometheus-values:{name}", spec, "platform")
fb = docs.get(root / "k8s/logging/fluent-bit-values.yaml", [{}])[0]
if not any(t.get("operator") == "Exists" and "key" not in t for t in fb.get("tolerations") or []):
    err("fluent-bit-values: tolerations must include {operator: Exists}")

# Dockerfiles drop root.
for f in files:
    if f.name == "Dockerfile":
        users = re.findall(r"^\s*USER\s+(\S+)", f.read_text(encoding="utf-8"), re.M)
        if not users or users[-1] in ("0", "root"):
            err(f"{f.relative_to(root)}: final USER must be non-root")

if errors:
    print("\n".join("FAIL " + e for e in errors))
    sys.exit(1)
print(f"OK: {len(yamls)} YAML files, {workloads} workloads checked")
PY
