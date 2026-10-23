#!/usr/bin/env bash
# Prepare a Rocky Linux 10 (x86_64) Orca server to run this repo's scripts and the ORCA_WORKFLOW agents.
# Run it on that host, from a clone of this repo; it asks for the sudo password once (dnf) and is safe to re-run.
#
#   ./scripts/bootstrap-rocky.sh            # install everything, then run the offline checks
#   SKIP_DNF=1 ./scripts/bootstrap-rocky.sh # only the user-local CLIs (no sudo)
#
# dnf: git gh jq gettext(envsubst) python3-pyyaml JDK 21 (./mvnw test) podman-docker (build-and-push.sh)
# ~/.local/bin, checksum-verified: kubectl (EKS 1.36), helm, eksctl, promtool, aws v2
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/.local/bin"
KUBECTL_MINOR="${KUBECTL_MINOR:-1.36}"
HELM_VERSION="${HELM_VERSION:-v3.16.4}"
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-3.15.0}"

[ "$(uname -m)" = x86_64 ] || { echo "x86_64 only (got $(uname -m))" >&2; exit 1; }
. /etc/os-release
case "${ID:-}:${VERSION_ID%%.*}" in
  rocky:10|rhel:10|almalinux:10) ;;
  *) echo "expected an EL10 host, got ${PRETTY_NAME:-unknown}" >&2; exit 1 ;;
esac

if [ -z "${SKIP_DNF:-}" ]; then
  echo "== dnf packages"
  [ -f /etc/yum.repos.d/gh-cli.repo ] \
    || curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo | sudo tee /etc/yum.repos.d/gh-cli.repo >/dev/null
  sudo dnf install -y git gh jq gettext python3-pyyaml java-21-openjdk-devel podman-docker unzip tar
fi

mkdir -p "$BIN"
case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH" ;; esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

if ! command -v kubectl >/dev/null; then
  echo "== kubectl (stable-$KUBECTL_MINOR)"
  v=$(curl -fsSL "https://dl.k8s.io/release/stable-$KUBECTL_MINOR.txt")
  fetch "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl" "$T/kubectl"
  echo "$(curl -fsSL "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl.sha256")  $T/kubectl" | sha256sum -c -
  install -m 0755 "$T/kubectl" "$BIN/kubectl"
fi

if ! command -v helm >/dev/null; then
  echo "== helm $HELM_VERSION"
  f="helm-$HELM_VERSION-linux-amd64.tar.gz"
  fetch "https://get.helm.sh/$f" "$T/$f"
  (cd "$T" && echo "$(curl -fsSL "https://get.helm.sh/$f.sha256sum" | cut -d' ' -f1)  $f" | sha256sum -c -)
  tar -xzf "$T/$f" -C "$T" && install -m 0755 "$T/linux-amd64/helm" "$BIN/helm"
fi

# ponytail: eksctl tracks the latest release; pin it here if a release ever breaks cluster.yaml.
if ! command -v eksctl >/dev/null; then
  echo "== eksctl (latest)"
  u=https://github.com/eksctl-io/eksctl/releases/latest/download
  fetch "$u/eksctl_Linux_amd64.tar.gz" "$T/eksctl_Linux_amd64.tar.gz"
  (cd "$T" && curl -fsSL "$u/eksctl_checksums.txt" | grep ' eksctl_Linux_amd64.tar.gz$' | sha256sum -c -)
  tar -xzf "$T/eksctl_Linux_amd64.tar.gz" -C "$T" && install -m 0755 "$T/eksctl" "$BIN/eksctl"
fi

if ! command -v promtool >/dev/null; then
  echo "== promtool $PROMETHEUS_VERSION (scripts/test-prometheus-rules.sh)"
  d="prometheus-$PROMETHEUS_VERSION.linux-amd64" u="https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION"
  fetch "$u/$d.tar.gz" "$T/$d.tar.gz"
  (cd "$T" && curl -fsSL "$u/sha256sums.txt" | grep " $d.tar.gz$" | sha256sum -c -)
  tar -xzf "$T/$d.tar.gz" -C "$T" && install -m 0755 "$T/$d/promtool" "$BIN/promtool"
fi

# AWS publishes a PGP signature, not a checksum, for this installer; it is fetched over HTTPS only.
if ! command -v aws >/dev/null; then
  echo "== aws cli v2"
  fetch https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip "$T/awscliv2.zip"
  unzip -q "$T/awscliv2.zip" -d "$T"
  "$T/aws/install" --install-dir "$HOME/.local/aws-cli" --bin-dir "$BIN" --update
fi

echo "== versions"
git --version; gh --version | head -1; jq --version; envsubst --version | head -1
python3 -c 'import yaml; print("PyYAML", yaml.__version__)'; java -version 2>&1 | head -1; docker --version
kubectl version --client | head -1; helm version --short; eksctl version; promtool --version | head -1; aws --version
for a in claude codex agy; do printf '%-7s %s\n' "$a" "$(command -v "$a" || echo 'missing (ORCA_WORKFLOW agent)')"; done

echo "== offline checks"
"$ROOT/scripts/validate-manifests.sh"
"$ROOT/scripts/test-prometheus-rules.sh"

cat <<EOF
== done. Not automated (credentials stay on this host, never in git):
  gh auth login                       # push / PR from this host
  aws configure sso                   # then: export AWS_PROFILE=<profile>
  cp .env.example .env && \$EDITOR .env # values as on the laptop (the laptop has no .env yet)
Make sure $BIN is on PATH in new shells (Rocky's default ~/.bashrc adds it).
EOF
