#!/usr/bin/env bash
# Install cluster add-ons and apply all manifests in dependency order.
# Prereqs: infra/aws/provision-aws-resources.sh (all phases) and scripts/build-and-push.sh.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME VPC_ID PUBLIC_SUBNET_A_ID PUBLIC_SUBNET_C_ID \
  DOMAIN_NAME ROUTE53_HOSTED_ZONE_ID ACM_CERTIFICATE_ARN WAF_WEB_ACL_ARN \
  ECR_WEB_REPOSITORY_URI ECR_WAS_REPOSITORY_URI STABLE_IMAGE_TAG CANARY_IMAGE_TAG \
  RDS_SECRET_NAME RDS_APP_SECRET_NAME RDS_BACKUP_SECRET_NAME GRAFANA_ADMIN_SECRET_NAME PROMETHEUS_SERVER_URL CW_LOG_GROUP_NAME BACKUP_S3_BUCKET_NAME

"$ROOT/scripts/validate-manifests.sh"

K="$ROOT/k8s"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"

# Placement for cluster controllers: ng-critical only.
CRITICAL=$(mktemp)
trap 'rm -f "$CRITICAL"' EXIT
cat > "$CRITICAL" <<'EOF'
nodeSelector:
  workload-tier: critical
tolerations:
  - { key: node-role, operator: Equal, value: critical, effect: NoSchedule }
EOF

echo "== Namespaces, StorageClass, Gateway API CRDs"
kubectl apply -f "$K/base/namespace.yaml"
kubectl apply -f "$K/base"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

echo "== Helm repos"
helm repo add eks https://aws.github.io/eks-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo add kedacore https://kedacore.github.io/charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "== Controllers on ng-critical (SAs with IRSA are created by eksctl)"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.9.2 -n kube-system -f "$CRITICAL" \
  --set clusterName="$EKS_CLUSTER_NAME" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller

# Resource Metrics API (metrics.k8s.io) for the web CPU HPA; EKS does not ship it.
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version 3.12.2 -n kube-system -f "$CRITICAL"

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.0.6 -n kube-system -f "$CRITICAL" \
  --set settings.clusterName="$EKS_CLUSTER_NAME" \
  --set-json "controller.env=[{\"name\":\"AWS_REGION\",\"value\":\"$AWS_REGION\"}]" \
  --set serviceAccount.create=false --set serviceAccount.name=karpenter

helm upgrade --install keda kedacore/keda --version 2.15.2 -n keda -f "$CRITICAL"

helm upgrade --install external-secrets external-secrets/external-secrets \
  --version 0.10.4 -n external-secrets -f "$CRITICAL" \
  --set-json 'webhook.nodeSelector={"workload-tier":"critical"}' \
  --set-json 'webhook.tolerations=[{"key":"node-role","operator":"Equal","value":"critical","effect":"NoSchedule"}]' \
  --set-json 'certController.nodeSelector={"workload-tier":"critical"}' \
  --set-json 'certController.tolerations=[{"key":"node-role","operator":"Equal","value":"critical","effect":"NoSchedule"}]' \
  --set serviceAccount.create=false --set serviceAccount.name=external-secrets --wait

echo "== Karpenter np-app NodePool"
render_all "$ROOT/infra/karpenter" | kubectl apply -f -

echo "== NGF gateway on np-app (ClusterIP; the ALB targets pod IPs), 2 replicas across AZs"
helm upgrade --install nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 1.5.1 -n nginx-gateway \
  --set fullnameOverride=nginx-gateway --set service.type=ClusterIP \
  --set nginxGateway.replicaCount=2 \
  --set-json 'nodeSelector={"workload-tier":"app"}' \
  --set-json 'topologySpreadConstraints=[{"maxSkew":1,"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"DoNotSchedule","labelSelector":{"matchLabels":{"app.kubernetes.io/name":"nginx-gateway-fabric","app.kubernetes.io/instance":"nginx-gateway"}}}]'

echo "== Secrets (ESO)"
render_all "$K/secrets" "$K/monitoring/externalsecret-grafana.yaml" | kubectl apply -f -
kubectl -n petclinic wait --for=condition=Ready externalsecret/petclinic-rds-admin externalsecret/petclinic-rds externalsecret/petclinic-rds-backup --timeout=120s
kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-admin --timeout=120s

echo "== Monitoring (ng-platform) and logging (all nodes)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 65.8.1 -n monitoring -f <(render "$K/monitoring/kube-prometheus-values.yaml") --wait
kubectl apply -f "$K/monitoring/servicemonitor-petclinic.yaml" -f "$K/monitoring/networkpolicy-prometheus.yaml"
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  --version 0.1.34 -n amazon-cloudwatch -f <(render "$K/logging/fluent-bit-values.yaml")

echo "== DB init Job + backup CronJob"
kubectl -n petclinic create configmap petclinic-db-scripts \
  --from-file="$ROOT/app/src/main/resources/db/mysql/schema.sql" \
  --from-file="$ROOT/app/src/main/resources/db/mysql/data.sql" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n petclinic delete job db-init --ignore-not-found
render_all "$K/jobs" | kubectl apply -f -
kubectl -n petclinic wait --for=condition=Complete job/db-init --timeout=300s

echo "== Workloads and routing (canary held at 0% until it passes the check below)"
render_all "$K/was" | kubectl apply -f -
render_all "$K/web" | kubectl apply -f -
STABLE_WEIGHT=100 CANARY_WEIGHT=0 render_all "$K/gateway" | kubectl apply -f -
kubectl -n petclinic rollout status deploy/was-stable --timeout=600s
kubectl -n petclinic rollout status deploy/web --timeout=300s
kubectl -n petclinic rollout status deploy/was-canary --timeout=600s
kubectl -n petclinic rollout status deploy/web-canary --timeout=300s

echo "== Route 53 alias -> ALB"
alb=""
for _ in $(seq 1 60); do
  alb=$(kubectl -n nginx-gateway get ingress petclinic-alb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [ -n "$alb" ] && break
  sleep 10
done
[ -n "$alb" ] || { echo "ALB hostname not assigned" >&2; exit 1; }
alb_zone=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='$alb'].CanonicalHostedZoneId" --output text)
aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" --change-batch \
  "$(jq -n --arg name "$DOMAIN_NAME" --arg zone "$alb_zone" --arg alb "$alb" '{Changes: [{Action: "UPSERT",
      ResourceRecordSet: {Name: $name, Type: "A",
        AliasTarget: {HostedZoneId: $zone, DNSName: $alb, EvaluateTargetHealth: true}}}]}')" >/dev/null

# End-to-end canary check: web-canary /healthz does not touch WAS, so hit a page served by was-canary.
# --connect-to goes straight to the ALB (no wait on DNS) while TLS still validates against DOMAIN_NAME.
echo "== Canary path check (X-Canary: always)"
ok=""
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 10 --connect-to "$DOMAIN_NAME:443:$alb:443" \
      -H "X-Canary: always" "https://$DOMAIN_NAME/owners?lastName="; then ok=1; break; fi
  sleep 10
done
[ -n "$ok" ] || { echo "canary path check failed: https://$DOMAIN_NAME/owners via X-Canary: always; canary stays at 0%" >&2; exit 1; }

echo "== Open canary: 90/10"
STABLE_WEIGHT=90 CANARY_WEIGHT=10 render "$K/gateway/httproute-canary.yaml" | kubectl apply -f -

echo "Done: https://$DOMAIN_NAME"
