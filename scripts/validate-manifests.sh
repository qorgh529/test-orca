#!/usr/bin/env bash
# Offline checks (no cluster needed). Requires python3 + PyYAML.
#   1. YAML syntax           2. no :latest / untagged images (templated: STABLE/CANARY_IMAGE_TAG)
#   3. no plaintext secrets  4. node-tier placement + non-root securityContext
#   5. stable/canary tags, DB secret per role, JDBC pool cap, KEDA fallback, Prometheus HA, PDBs
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
        if not image.endswith((":${STABLE_IMAGE_TAG}", ":${CANARY_IMAGE_TAG}")):
            err(f"{where}: templated image must use :${{STABLE_IMAGE_TAG}} or :${{CANARY_IMAGE_TAG}}: {image}")
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
# No Maven profile may carry a DB password.
pom = (root / "app/pom.xml").read_text(encoding="utf-8")
for m in re.finditer(r"<jdbc\.password>[^<]+</jdbc\.password>", pom):
    err(f"app/pom.xml:{pom[:m.start()].count(chr(10)) + 1}: hard-coded jdbc.password")

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

# 5. Operational guards (design Steps 9-11)
k8s_docs = [(f.relative_to(root), d) for f, ds in docs.items() if f.relative_to(root).parts[0] == "k8s"
            for d in ds if isinstance(d, dict)]
def find(kind, name):
    return next((d for _, d in k8s_docs if d.get("kind") == kind and d["metadata"]["name"] == name), None)

# Stable and canary roll out different images.
for rel, d in k8s_docs:
    if d.get("kind") != "Deployment":
        continue
    track = (d["metadata"].get("labels") or {}).get("track")
    want = {"stable": ":${STABLE_IMAGE_TAG}", "canary": ":${CANARY_IMAGE_TAG}"}.get(track)
    for c in pod_spec(d)["containers"]:
        if want and "${" in c["image"] and not c["image"].endswith(want):
            err(f"{rel}:Deployment/{d['metadata']['name']}: track {track} must use {want}")

# Each DB role reads only its own secret; only db-init may use the admin account.
DB_SECRETS = {"petclinic-rds-admin-secret", "petclinic-rds-secret", "petclinic-rds-backup-secret"}
ALLOWED = {"was-stable": {"petclinic-rds-secret"}, "was-canary": {"petclinic-rds-secret"},
           "db-backup": {"petclinic-rds-backup-secret"}, "db-init": DB_SECRETS}
for rel, d in k8s_docs:
    spec = pod_spec(d)
    if spec is None:
        continue
    name = d["metadata"]["name"]
    for c in (spec.get("initContainers") or []) + spec["containers"]:
        for e in c.get("env") or []:
            ref = ((e.get("valueFrom") or {}).get("secretKeyRef") or {}).get("name")
            if ref in DB_SECRETS and ref not in ALLOWED.get(name, set()):
                err(f"{rel}:{d['kind']}/{name}: must not read {ref}")
            if name == "db-init" and e["name"] in ("JDBC_USERNAME", "MYSQL_PWD") and ref != "petclinic-rds-admin-secret":
                err(f"{rel}:Job/db-init: {e['name']} must come from petclinic-rds-admin-secret")
for es in ("petclinic-rds-admin", "petclinic-rds", "petclinic-rds-backup"):
    if find("ExternalSecret", es) is None:
        err(f"k8s/secrets: missing ExternalSecret/{es}")

# JDBC pool is capped (RDS connection budget).
props = (root / "app/src/main/resources/spring/data-access.properties").read_text(encoding="utf-8")
m = re.search(r"^jdbc\.pool\.maxActive=(\d+)\s*$", props, re.M)
if not m or int(m.group(1)) > 10:
    err("data-access.properties: jdbc.pool.maxActive must be set and <= 10")
if 'p:maxActive="${jdbc.pool.maxActive}"' not in (root / "app/src/main/resources/spring/datasource-config.xml").read_text(encoding="utf-8"):
    err("datasource-config.xml: dataSource must use ${jdbc.pool.maxActive}")

# KEDA keeps a safe replica count when Prometheus is down.
for name in ("was-stable", "was-canary"):
    so = find("ScaledObject", name)
    if not so or not (so["spec"].get("fallback") or {}).get("replicas"):
        err(f"ScaledObject/{name}: fallback.replicas must be set")

# Prometheus survives one AZ.
if int(kps.get("prometheus", {}).get("prometheusSpec", {}).get("replicas", 1)) < 2:
    err("kube-prometheus-values: prometheus.prometheusSpec.replicas must be >= 2")

# Stable tracks keep a pod through voluntary disruptions.
for app in ("web", "was"):
    sel = {"app": app, "track": "stable"}
    if not any(d.get("kind") == "PodDisruptionBudget" and (d["spec"].get("selector") or {}).get("matchLabels") == sel
               for _, d in k8s_docs):
        err(f"missing PodDisruptionBudget for {sel}")

# EBS CSI add-on version is pinned (design §4.1).
eks = docs.get(root / "infra/eksctl/cluster.yaml", [{}])[0]
for a in eks.get("addons") or []:
    if a["name"] == "aws-ebs-csi-driver" and not a.get("version"):
        err("infra/eksctl/cluster.yaml: addon aws-ebs-csi-driver must set version")

# Webhook URLs carry tokens: read from the ESO-synced Secret file, never inlined in Helm values.
for r in kps.get("alertmanager", {}).get("config", {}).get("receivers") or []:
    for w in r.get("webhook_configs") or []:
        if "url" in w or not w.get("url_file"):
            err(f"kube-prometheus-values: receiver {r.get('name')} must use url_file, not url")

if errors:
    print("\n".join("FAIL " + e for e in errors))
    sys.exit(1)
print(f"OK: {len(yamls)} YAML files, {workloads} workloads checked")
PY
