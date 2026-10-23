#!/usr/bin/env bash
# Apply DB password changes made in Secrets Manager (RDS_APP_SECRET_NAME / RDS_BACKUP_SECRET_NAME).
# ESO refreshes K8s Secrets hourly, but running pods keep the old env vars, so:
#   1. force-sync the ExternalSecrets  2. re-run db-init (ALTER USER with the new passwords)
#   3. rolling-restart was-stable / was-canary (db-backup reads the secret on each run).
# To rotate the admin (master) password, change it on RDS and in RDS_SECRET_NAME first, then run this.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

require AWS_REGION EKS_CLUSTER_NAME RDS_SECRET_NAME RDS_APP_SECRET_NAME RDS_BACKUP_SECRET_NAME
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"

now=$(date +%s)
for es in petclinic-rds-admin petclinic-rds petclinic-rds-backup; do
  kubectl -n petclinic annotate externalsecret "$es" force-sync="$now" --overwrite
done
# Ready alone may be stale from before the force-sync; wait until the refresh time moves past $now.
# Stop before db-init if any secret was not refreshed: ALTER USER with old passwords would "succeed".
for es in petclinic-rds-admin petclinic-rds petclinic-rds-backup; do
  synced=""
  for _ in $(seq 1 30); do
    t=$(kubectl -n petclinic get externalsecret "$es" -o jsonpath='{.status.refreshTime}')
    [ -n "$t" ] && [ "$(date -d "$t" +%s)" -ge "$now" ] && { synced=1; break; }
    sleep 2
  done
  [ -n "$synced" ] || { echo "ExternalSecret $es not refreshed within 60s; rotation aborted before db-init" >&2; exit 1; }
done
kubectl -n petclinic wait --for=condition=Ready externalsecret/petclinic-rds-admin externalsecret/petclinic-rds externalsecret/petclinic-rds-backup --timeout=120s

kubectl -n petclinic delete job db-init --ignore-not-found
render "$ROOT/k8s/jobs/job-db-init.yaml" | kubectl apply -f -
kubectl -n petclinic wait --for=condition=Complete job/db-init --timeout=300s

kubectl -n petclinic rollout restart deploy/was-stable deploy/was-canary
kubectl -n petclinic rollout status deploy/was-stable --timeout=600s
kubectl -n petclinic rollout status deploy/was-canary --timeout=600s
echo "DB credentials rotated."
