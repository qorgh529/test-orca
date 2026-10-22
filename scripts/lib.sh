# Sourced by scripts/*.sh. Loads .env and provides require/render.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "missing required env: $v" >&2; exit 1; }
  done
}

# Only these are substituted; anything else (e.g. $RDS_HOST inside container commands) is left alone.
TEMPLATE_VARS='${AWS_REGION} ${AWS_ACCOUNT_ID} ${EKS_CLUSTER_NAME} ${PUBLIC_SUBNET_A_ID} ${PUBLIC_SUBNET_C_ID}
${DOMAIN_NAME} ${ACM_CERTIFICATE_ARN} ${WAF_WEB_ACL_ARN} ${ECR_WEB_REPOSITORY_URI} ${ECR_WAS_REPOSITORY_URI}
${IMAGE_TAG} ${RDS_SECRET_NAME} ${RDS_APP_SECRET_NAME} ${RDS_BACKUP_SECRET_NAME} ${GRAFANA_ADMIN_SECRET_NAME} ${PROMETHEUS_SERVER_URL} ${CW_LOG_GROUP_NAME}
${BACKUP_S3_BUCKET_NAME}'

render() { envsubst "$TEMPLATE_VARS" < "$1"; }

# Render every *.yaml in the given dirs/files as one multi-document stream.
render_all() {
  local f
  for f in $(find "$@" -name '*.yaml' | sort); do
    render "$f"
    printf '\n---\n'
  done
}
