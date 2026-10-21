#!/usr/bin/env bash
# Provision AWS resources around the EKS cluster. The VPC and its subnets are inputs (.env).
#
#   ./infra/aws/provision-aws-resources.sh pre-cluster   # IAM, ECR, log group, backup bucket, WAF, ACM
#   ./infra/aws/provision-aws-resources.sh cluster       # eksctl create cluster + Karpenter discovery tags
#   ./infra/aws/provision-aws-resources.sh post-cluster  # RDS MySQL Multi-AZ + Secrets Manager secrets
#
# Not idempotent: each phase is meant to run once. Re-runs fail on "already exists".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "missing required env: $v" >&2; exit 1; }
  done
}

export AWS_DEFAULT_REGION="${AWS_REGION:-}"

pre_cluster() {
  require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME CW_LOG_GROUP_NAME BACKUP_S3_BUCKET_NAME DOMAIN_NAME ROUTE53_HOSTED_ZONE_ID
  local dir="$ROOT/infra/aws/iam-policies" name

  echo "== IAM policies (IRSA)"
  for name in lbc karpenter-controller eso fluent-bit db-backup; do
    aws iam create-policy \
      --policy-name "${EKS_CLUSTER_NAME}-${name}" \
      --policy-document "$(envsubst < "$dir/${name}-policy.json")" >/dev/null
  done

  echo "== Karpenter node role"
  local role="KarpenterNodeRole-${EKS_CLUSTER_NAME}"
  aws iam create-role --role-name "$role" \
    --assume-role-policy-document "file://$dir/karpenter-node-trust.json" >/dev/null
  for name in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
    aws iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::aws:policy/$name"
  done

  echo "== ECR repositories"
  for name in petclinic-web petclinic-was; do
    aws ecr create-repository --repository-name "$name" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=KMS \
      --query repository.repositoryUri --output text
  done

  echo "== CloudWatch log group"
  aws logs create-log-group --log-group-name "$CW_LOG_GROUP_NAME"
  aws logs put-retention-policy --log-group-name "$CW_LOG_GROUP_NAME" --retention-in-days 30

  echo "== Backup bucket (private, encrypted, versioned)"
  aws s3api create-bucket --bucket "$BACKUP_S3_BUCKET_NAME" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$BACKUP_S3_BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$BACKUP_S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-versioning --bucket "$BACKUP_S3_BUCKET_NAME" --versioning-configuration Status=Enabled

  echo "== WAFv2 WebACL (regional, AWS managed rules)"
  local rules='[' prio=0 rule
  for rule in AWSManagedRulesCommonRuleSet AWSManagedRulesSQLiRuleSet AWSManagedRulesKnownBadInputsRuleSet; do
    [ "$prio" -gt 0 ] && rules+=','
    rules+="{\"Name\":\"$rule\",\"Priority\":$prio,\"OverrideAction\":{\"None\":{}},
      \"Statement\":{\"ManagedRuleGroupStatement\":{\"VendorName\":\"AWS\",\"Name\":\"$rule\"}},
      \"VisibilityConfig\":{\"SampledRequestsEnabled\":true,\"CloudWatchMetricsEnabled\":true,\"MetricName\":\"$rule\"}}"
    prio=$((prio + 1))
  done
  rules+=']'
  aws wafv2 create-web-acl --scope REGIONAL --name "${EKS_CLUSTER_NAME}-web-acl" \
    --default-action Allow={} \
    --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=${EKS_CLUSTER_NAME}-web-acl" \
    --rules "$rules" --query Summary.ARN --output text

  echo "== ACM certificate (DNS validation via Route 53)"
  local cert_arn rr
  cert_arn=$(aws acm request-certificate --domain-name "$DOMAIN_NAME" --validation-method DNS \
    --query CertificateArn --output text)
  # The validation record shows up a few seconds after the request.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    rr=$(aws acm describe-certificate --certificate-arn "$cert_arn" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)
    [ "$rr" != "null" ] && break
    sleep 3
  done
  [ "$rr" != "null" ] || { echo "ACM validation record not available yet" >&2; exit 1; }
  aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" --change-batch \
    "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":$(echo "$rr" | jq .Name),\"Type\":$(echo "$rr" | jq .Type),\"TTL\":300,\"ResourceRecords\":[{\"Value\":$(echo "$rr" | jq .Value)}]}}]}" >/dev/null
  aws acm wait certificate-validated --certificate-arn "$cert_arn"
  echo "$cert_arn"

  echo "Set ECR_*_REPOSITORY_URI, WAF_WEB_ACL_ARN and ACM_CERTIFICATE_ARN in .env from the output above."
}

cluster() {
  require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME VPC_ID PUBLIC_SUBNET_A_ID PUBLIC_SUBNET_C_ID APP_PRIVATE_SUBNET_A_ID APP_PRIVATE_SUBNET_C_ID
  envsubst < "$ROOT/infra/eksctl/cluster.yaml" | eksctl create cluster -f -

  local sg
  sg=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
  aws ec2 create-tags --resources "$APP_PRIVATE_SUBNET_A_ID" "$APP_PRIVATE_SUBNET_C_ID" "$sg" \
    --tags "Key=karpenter.sh/discovery,Value=$EKS_CLUSTER_NAME"
}

post_cluster() {
  require AWS_REGION EKS_CLUSTER_NAME VPC_ID DB_PRIVATE_SUBNET_A_ID DB_PRIVATE_SUBNET_C_ID RDS_SECRET_NAME RDS_DB_NAME RDS_PORT GRAFANA_ADMIN_SECRET_NAME
  local s
  for s in "$RDS_SECRET_NAME" "$GRAFANA_ADMIN_SECRET_NAME"; do
    case "$s" in
      petclinic/*) ;;
      *) echo "secret names must start with petclinic/ (ESO IAM scope): $s" >&2; exit 1 ;;
    esac
  done
  local db_id="${EKS_CLUSTER_NAME}-mysql" cluster_sg rds_sg password host

  echo "== RDS security group: 3306 from the EKS cluster security group only"
  cluster_sg=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
  rds_sg=$(aws ec2 create-security-group --group-name "${db_id}-sg" --vpc-id "$VPC_ID" \
    --description "PetClinic RDS MySQL - 3306 from EKS only" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$rds_sg" \
    --protocol tcp --port "$RDS_PORT" --source-group "$cluster_sg" >/dev/null

  aws rds create-db-subnet-group --db-subnet-group-name "${db_id}-subnets" \
    --db-subnet-group-description "PetClinic DB private subnets" \
    --subnet-ids "$DB_PRIVATE_SUBNET_A_ID" "$DB_PRIVATE_SUBNET_C_ID" >/dev/null

  echo "== RDS MySQL 8.0 Multi-AZ (encrypted, private)"
  password=$(aws secretsmanager get-random-password --password-length 32 --exclude-punctuation \
    --query RandomPassword --output text)
  # Password goes through stdin so it never appears in the process list.
  aws rds create-db-instance --cli-input-json file:///dev/stdin \
    --db-instance-identifier "$db_id" \
    --engine mysql --engine-version 8.0.39 \
    --db-instance-class db.t3.medium \
    --allocated-storage 20 --storage-type gp3 --storage-encrypted \
    --multi-az --no-publicly-accessible \
    --db-name "$RDS_DB_NAME" --port "$RDS_PORT" \
    --master-username petclinic_admin \
    --vpc-security-group-ids "$rds_sg" \
    --db-subnet-group-name "${db_id}-subnets" \
    --backup-retention-period 7 --copy-tags-to-snapshot --deletion-protection \
    <<<"{\"MasterUserPassword\":\"$password\"}" >/dev/null
  aws rds wait db-instance-available --db-instance-identifier "$db_id"
  host=$(aws rds describe-db-instances --db-instance-identifier "$db_id" \
    --query 'DBInstances[0].Endpoint.Address' --output text)

  echo "== Secrets Manager: $RDS_SECRET_NAME"
  aws secretsmanager create-secret --name "$RDS_SECRET_NAME" --secret-string file:///dev/stdin \
    <<<"{\"username\":\"petclinic_admin\",\"password\":\"$password\",\"host\":\"$host\",\"port\":\"$RDS_PORT\",\"dbname\":\"$RDS_DB_NAME\"}" >/dev/null
  echo "RDS endpoint: $host"

  echo "== Secrets Manager: $GRAFANA_ADMIN_SECRET_NAME"
  password=$(aws secretsmanager get-random-password --password-length 32 --exclude-punctuation \
    --query RandomPassword --output text)
  aws secretsmanager create-secret --name "$GRAFANA_ADMIN_SECRET_NAME" --secret-string file:///dev/stdin \
    <<<"{\"username\":\"admin\",\"password\":\"$password\"}" >/dev/null
}

case "${1:-}" in
  pre-cluster) pre_cluster ;;
  cluster) cluster ;;
  post-cluster) post_cluster ;;
  *) echo "usage: $0 {pre-cluster|cluster|post-cluster}" >&2; exit 1 ;;
esac
