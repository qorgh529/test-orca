#!/usr/bin/env bash
# Provision AWS resources around the EKS cluster. The VPC and its subnets are inputs (.env).
#
#   ./infra/aws/provision-aws-resources.sh pre-cluster   # IAM, ECR, log group, backup/Tempo buckets, WAF, ACM
#   ./infra/aws/provision-aws-resources.sh cluster       # eksctl create cluster + Karpenter discovery tags
#   ./infra/aws/provision-aws-resources.sh post-cluster  # RDS MySQL Multi-AZ + Secrets Manager secrets
#
# Idempotent: every step looks the resource up first and reuses (or updates) it, so a phase that
# stopped half-way can simply be run again. Existing resources are not reconfigured beyond what
# each step notes (e.g. an existing WAF WebACL or RDS instance keeps its settings).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "missing required env: $v" >&2; exit 1; }
  done
}

# Run an AWS call whose only acceptable failure is "already there" (matched by $1 in the error text).
tolerate() {
  local pattern=$1 out
  shift
  out=$("$@" 2>&1) && return 0
  grep -q "$pattern" <<<"$out" && return 0
  echo "$out" >&2
  return 1
}

random_password() {
  aws secretsmanager get-random-password --password-length 32 --exclude-punctuation \
    --query RandomPassword --output text
}

# Create a DB secret, or keep its password and refresh the connection fields.
# Passwords travel env -> jq -> stdin so they never appear in any process's argv.
upsert_db_secret() {
  local name=$1 user=$2 host=$3 current password
  if current=$(aws secretsmanager get-secret-value --secret-id "$name" --query SecretString --output text 2>/dev/null); then
    password=$(jq -r .password <<<"$current")
    PW="$password" jq -n --arg user "$user" --arg host "$host" --arg port "$RDS_PORT" --arg db "$RDS_DB_NAME" \
      '{username: $user, password: env.PW, host: $host, port: $port, dbname: $db}' \
      | aws secretsmanager put-secret-value --secret-id "$name" --secret-string file:///dev/stdin >/dev/null
  else
    password=$(random_password)
    PW="$password" jq -n --arg user "$user" --arg host "$host" --arg port "$RDS_PORT" --arg db "$RDS_DB_NAME" \
      '{username: $user, password: env.PW, host: $host, port: $port, dbname: $db}' \
      | aws secretsmanager create-secret --name "$name" --secret-string file:///dev/stdin >/dev/null
  fi
}

export AWS_DEFAULT_REGION="${AWS_REGION:-}"

pre_cluster() {
  require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME CW_LOG_GROUP_NAME BACKUP_S3_BUCKET_NAME TEMPO_S3_BUCKET_NAME DOMAIN_NAME ROUTE53_HOSTED_ZONE_ID
  # The Tempo lifecycle deletes objects: it must never land on the backup bucket.
  [ "$TEMPO_S3_BUCKET_NAME" != "$BACKUP_S3_BUCKET_NAME" ] \
    || { echo "TEMPO_S3_BUCKET_NAME must differ from BACKUP_S3_BUCKET_NAME" >&2; exit 1; }
  local retention="${TEMPO_RETENTION_DAYS:-14}"
  [[ "$retention" =~ ^[1-9][0-9]*$ ]] || { echo "TEMPO_RETENTION_DAYS must be a positive integer" >&2; exit 1; }
  local dir="$ROOT/infra/aws/iam-policies" name arn doc v

  echo "== IAM policies (IRSA): create, or publish the current document as the default version"
  for name in lbc karpenter-controller eso fluent-bit db-backup tempo; do
    arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${EKS_CLUSTER_NAME}-${name}"
    doc=$(envsubst < "$dir/${name}-policy.json")
    if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
      # IAM keeps at most 5 versions: drop the non-default ones before adding the new default.
      for v in $(aws iam list-policy-versions --policy-arn "$arn" \
          --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
        aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
      done
      aws iam create-policy-version --policy-arn "$arn" --policy-document "$doc" --set-as-default >/dev/null
    else
      aws iam create-policy --policy-name "${EKS_CLUSTER_NAME}-${name}" --policy-document "$doc" >/dev/null
    fi
  done

  echo "== Karpenter node role"
  local role="KarpenterNodeRole-${EKS_CLUSTER_NAME}"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam create-role --role-name "$role" \
      --assume-role-policy-document "file://$dir/karpenter-node-trust.json" >/dev/null
  fi
  for name in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
    aws iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::aws:policy/$name"
  done

  echo "== ECR repositories"
  for name in petclinic-web petclinic-was; do
    aws ecr describe-repositories --repository-names "$name" \
        --query 'repositories[0].repositoryUri' --output text 2>/dev/null \
      || aws ecr create-repository --repository-name "$name" \
        --image-tag-mutability IMMUTABLE \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=KMS \
        --query repository.repositoryUri --output text
  done

  echo "== CloudWatch log group"
  tolerate ResourceAlreadyExistsException aws logs create-log-group --log-group-name "$CW_LOG_GROUP_NAME"
  aws logs put-retention-policy --log-group-name "$CW_LOG_GROUP_NAME" --retention-in-days 30

  echo "== Backup bucket (private, encrypted, versioned)"
  if ! aws s3api head-bucket --bucket "$BACKUP_S3_BUCKET_NAME" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BACKUP_S3_BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BACKUP_S3_BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$BACKUP_S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-versioning --bucket "$BACKUP_S3_BUCKET_NAME" --versioning-configuration Status=Enabled

  # Not versioned: the Tempo compactor deletes blocks, and noncurrent versions would pile up.
  echo "== Tempo trace bucket (private, encrypted, expires after $retention days)"
  if ! aws s3api head-bucket --bucket "$TEMPO_S3_BUCKET_NAME" 2>/dev/null; then
    aws s3api create-bucket --bucket "$TEMPO_S3_BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$TEMPO_S3_BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$TEMPO_S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-lifecycle-configuration --bucket "$TEMPO_S3_BUCKET_NAME" --lifecycle-configuration \
    "$(jq -n --argjson days "$retention" '{Rules: [{ID: "tempo-retention", Status: "Enabled", Filter: {},
        Expiration: {Days: $days}, AbortIncompleteMultipartUpload: {DaysAfterInitiation: 1}}]}')"

  echo "== WAFv2 WebACL (regional, AWS managed rules; an existing ACL is reused as-is)"
  local acl_name="${EKS_CLUSTER_NAME}-web-acl" acl_arn rules
  acl_arn=$(aws wafv2 list-web-acls --scope REGIONAL \
    --query "WebACLs[?Name=='$acl_name'].ARN | [0]" --output text)
  if [ "$acl_arn" = "None" ] || [ -z "$acl_arn" ]; then
    rules=$(jq -n '[$ARGS.positional | to_entries[] | {
        Name: .value, Priority: .key, OverrideAction: {None: {}},
        Statement: {ManagedRuleGroupStatement: {VendorName: "AWS", Name: .value}},
        VisibilityConfig: {SampledRequestsEnabled: true, CloudWatchMetricsEnabled: true, MetricName: .value}}]' \
      --args AWSManagedRulesCommonRuleSet AWSManagedRulesSQLiRuleSet AWSManagedRulesKnownBadInputsRuleSet)
    acl_arn=$(aws wafv2 create-web-acl --scope REGIONAL --name "$acl_name" \
      --default-action Allow={} \
      --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=$acl_name" \
      --rules "$rules" --query Summary.ARN --output text)
  fi
  echo "$acl_arn"

  echo "== ACM certificate (DNS validation via Route 53; an issued or pending one is reused)"
  local cert_arn rr
  cert_arn=$(aws acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION \
    --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn | [0]" --output text)
  if [ "$cert_arn" = "None" ] || [ -z "$cert_arn" ]; then
    cert_arn=$(aws acm request-certificate --domain-name "$DOMAIN_NAME" --validation-method DNS \
      --query CertificateArn --output text)
  fi
  # The validation record shows up a few seconds after the request.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    rr=$(aws acm describe-certificate --certificate-arn "$cert_arn" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)
    [ "$rr" != "null" ] && break
    sleep 3
  done
  [ "$rr" != "null" ] || { echo "ACM validation record not available yet" >&2; exit 1; }
  aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" --change-batch \
    "$(jq -n --argjson rr "$rr" '{Changes: [{Action: "UPSERT", ResourceRecordSet:
        {Name: $rr.Name, Type: $rr.Type, TTL: 300, ResourceRecords: [{Value: $rr.Value}]}}]}')" >/dev/null
  aws acm wait certificate-validated --certificate-arn "$cert_arn"
  echo "$cert_arn"

  echo "Set ECR_*_REPOSITORY_URI, WAF_WEB_ACL_ARN and ACM_CERTIFICATE_ARN in .env from the output above."
}

cluster() {
  require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME VPC_ID PUBLIC_SUBNET_A_ID PUBLIC_SUBNET_C_ID APP_PRIVATE_SUBNET_A_ID APP_PRIVATE_SUBNET_C_ID EBS_CSI_ADDON_VERSION
  if aws eks describe-cluster --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1; then
    echo "cluster $EKS_CLUSTER_NAME exists; skipping eksctl create, adding missing IRSA service accounts"
    # e.g. monitoring/tempo on a cluster created before apm-tracing; existing ones are left alone.
    envsubst < "$ROOT/infra/eksctl/cluster.yaml" | eksctl create iamserviceaccount -f - --approve
  else
    envsubst < "$ROOT/infra/eksctl/cluster.yaml" | eksctl create cluster -f -
  fi

  local sg
  sg=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
  aws ec2 create-tags --resources "$APP_PRIVATE_SUBNET_A_ID" "$APP_PRIVATE_SUBNET_C_ID" "$sg" \
    --tags "Key=karpenter.sh/discovery,Value=$EKS_CLUSTER_NAME"
}

post_cluster() {
  require AWS_REGION EKS_CLUSTER_NAME VPC_ID DB_PRIVATE_SUBNET_A_ID DB_PRIVATE_SUBNET_C_ID RDS_SECRET_NAME RDS_APP_SECRET_NAME RDS_BACKUP_SECRET_NAME RDS_DB_NAME RDS_PORT GRAFANA_ADMIN_SECRET_NAME ALERTMANAGER_WEBHOOK_SECRET_NAME
  local s
  for s in "$RDS_SECRET_NAME" "$RDS_APP_SECRET_NAME" "$RDS_BACKUP_SECRET_NAME" "$GRAFANA_ADMIN_SECRET_NAME" "$ALERTMANAGER_WEBHOOK_SECRET_NAME"; do
    case "$s" in
      petclinic/*) ;;
      *) echo "secret names must start with petclinic/ (ESO IAM scope): $s" >&2; exit 1 ;;
    esac
  done
  local db_id="${EKS_CLUSTER_NAME}-mysql" cluster_sg rds_sg password host

  echo "== RDS security group: 3306 from the EKS cluster security group only"
  cluster_sg=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
  rds_sg=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${db_id}-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$rds_sg" = "None" ]; then
    rds_sg=$(aws ec2 create-security-group --group-name "${db_id}-sg" --vpc-id "$VPC_ID" \
      --description "PetClinic RDS MySQL - 3306 from EKS only" --query GroupId --output text)
  fi
  tolerate InvalidPermission.Duplicate aws ec2 authorize-security-group-ingress --group-id "$rds_sg" \
    --protocol tcp --port "$RDS_PORT" --source-group "$cluster_sg"

  aws rds describe-db-subnet-groups --db-subnet-group-name "${db_id}-subnets" >/dev/null 2>&1 \
    || aws rds create-db-subnet-group --db-subnet-group-name "${db_id}-subnets" \
      --db-subnet-group-description "PetClinic DB private subnets" \
      --subnet-ids "$DB_PRIVATE_SUBNET_A_ID" "$DB_PRIVATE_SUBNET_C_ID" >/dev/null

  echo "== RDS parameter group: TLS required"
  aws rds describe-db-parameter-groups --db-parameter-group-name "${db_id}-params" >/dev/null 2>&1 \
    || aws rds create-db-parameter-group --db-parameter-group-name "${db_id}-params" \
      --db-parameter-group-family mysql8.0 --description "PetClinic MySQL - require TLS" >/dev/null
  aws rds modify-db-parameter-group --db-parameter-group-name "${db_id}-params" \
    --parameters "ParameterName=require_secure_transport,ParameterValue=ON,ApplyMethod=immediate" >/dev/null

  # The master password is stored before the instance exists, so a run that dies in between
  # never loses it: the next run reads it back from the secret.
  echo "== Secrets Manager: $RDS_SECRET_NAME (petclinic_admin)"
  upsert_db_secret "$RDS_SECRET_NAME" petclinic_admin ""
  password=$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_NAME" \
    --query SecretString --output text | jq -r .password)

  echo "== RDS MySQL 8.0 Multi-AZ (encrypted, private; an existing instance is reused as-is)"
  if ! aws rds describe-db-instances --db-instance-identifier "$db_id" >/dev/null 2>&1; then
    PW="$password" jq -n '{MasterUserPassword: env.PW}' | aws rds create-db-instance --cli-input-json file:///dev/stdin \
      --db-instance-identifier "$db_id" \
      --engine mysql --engine-version 8.0.39 \
      --db-instance-class db.t3.medium \
      --allocated-storage 20 --storage-type gp3 --storage-encrypted \
      --multi-az --no-publicly-accessible \
      --db-name "$RDS_DB_NAME" --port "$RDS_PORT" \
      --master-username petclinic_admin \
      --vpc-security-group-ids "$rds_sg" \
      --db-subnet-group-name "${db_id}-subnets" \
      --db-parameter-group-name "${db_id}-params" \
      --enable-cloudwatch-logs-exports '["error","slowquery"]' \
      --backup-retention-period 7 --copy-tags-to-snapshot --deletion-protection >/dev/null
  fi
  aws rds wait db-instance-available --db-instance-identifier "$db_id"
  host=$(aws rds describe-db-instances --db-instance-identifier "$db_id" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  echo "RDS endpoint: $host"

  # App/backup users are created in MySQL by the db-init Job from these secrets.
  echo "== Secrets Manager: DB secrets with endpoint $host"
  upsert_db_secret "$RDS_SECRET_NAME" petclinic_admin "$host"
  upsert_db_secret "$RDS_APP_SECRET_NAME" petclinic_app "$host"
  upsert_db_secret "$RDS_BACKUP_SECRET_NAME" petclinic_backup "$host"

  echo "== Secrets Manager: $GRAFANA_ADMIN_SECRET_NAME"
  if ! aws secretsmanager describe-secret --secret-id "$GRAFANA_ADMIN_SECRET_NAME" >/dev/null 2>&1; then
    password=$(random_password)
    PW="$password" jq -n '{username: "admin", password: env.PW}' \
      | aws secretsmanager create-secret --name "$GRAFANA_ADMIN_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
  fi

  # The URL comes from .env once and lives only in Secrets Manager; re-running with it set updates the secret.
  echo "== Secrets Manager: $ALERTMANAGER_WEBHOOK_SECRET_NAME"
  if [ -n "${ALERTMANAGER_WEBHOOK_URL:-}" ]; then
    case "$ALERTMANAGER_WEBHOOK_URL" in
      https://*) ;;
      *) echo "ALERTMANAGER_WEBHOOK_URL must be https:// (Alertmanager egress allows 443 only)" >&2; exit 1 ;;
    esac
    if aws secretsmanager describe-secret --secret-id "$ALERTMANAGER_WEBHOOK_SECRET_NAME" >/dev/null 2>&1; then
      jq -n '{url: env.ALERTMANAGER_WEBHOOK_URL}' | aws secretsmanager put-secret-value \
        --secret-id "$ALERTMANAGER_WEBHOOK_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
    else
      jq -n '{url: env.ALERTMANAGER_WEBHOOK_URL}' | aws secretsmanager create-secret \
        --name "$ALERTMANAGER_WEBHOOK_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
    fi
  elif ! aws secretsmanager describe-secret --secret-id "$ALERTMANAGER_WEBHOOK_SECRET_NAME" >/dev/null 2>&1; then
    echo "set ALERTMANAGER_WEBHOOK_URL to create $ALERTMANAGER_WEBHOOK_SECRET_NAME" >&2; exit 1
  fi
}

case "${1:-}" in
  pre-cluster) pre_cluster ;;
  cluster) cluster ;;
  post-cluster) post_cluster ;;
  *) echo "usage: $0 {pre-cluster|cluster|post-cluster}" >&2; exit 1 ;;
esac
