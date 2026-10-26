# AWS EKS 기반 Spring Framework PetClinic 클라우드 네이티브 아키텍처

전통적인 `spring-framework-petclinic`(Spring Framework 7.x / Jakarta EE 11 WAR 패키징)을 AWS 서울 리전(`ap-northeast-2`)의 **Amazon EKS (`1.36`)** 위에 **Multi-AZ 고가용성**, **Gateway API 기반 카나리(Canary) 배포**, **3-Tier 노드 격리(Karpenter + Managed NodeGroups)**, **최소 권한 보안(Zero Hardcoded Secrets & Least Privilege)**, **통합 관측성(Prometheus / Grafana / Alertmanager / CloudWatch Logs / OpenTelemetry + Tempo 분산 트레이싱)** 구조로 구축한 프로젝트입니다.

![AWS EKS 기반 Spring Framework PetClinic 아키텍처](./docs/architecture.drawio.svg)

> 편집 가능한 원본 다이어그램: [`docs/architecture.drawio`](./docs/architecture.drawio) · [`docs/architecture.drawio.svg`](./docs/architecture.drawio.svg) · [`docs/architecture.drawio.png`](./docs/architecture.drawio.png)

---

## 1. 핵심 아키텍처 하이라이트

- **Edge & L7 Gateway 보안 라우팅**:
  - **Route 53 + ACM + AWS WAFv2**(`CommonRuleSet`, `SQLiRuleSet`, `KnownBadInputsRuleSet`)로 인터넷 경계를 보호하고, **AWS Load Balancer Controller(LBC)** 가 생성한 ALB(`target-type: ip`, HTTPS 443 강제, 비정상 헤더 드롭)가 **NGINX Gateway Fabric(NGF)** Pod로 직접 라우팅합니다.
- **안전한 카나리 배포 게이팅 (Canary Traffic Gating)**:
  - `web`/`was-stable`(`STABLE_IMAGE_TAG`)과 `web-canary`/`was-canary`(`CANARY_IMAGE_TAG`)의 버전을 분리합니다.
  - 배포 시 먼저 `HTTPRoute` 가중치를 **`100:0`으로 고정(Gateway `Accepted` 확인)** 한 상태에서 카나리 Pod를 롤아웃하고, `X-Canary: always` 헤더로 동적 DB 조회 경로(`/owners?lastName=`)를 E2E 검증한 뒤에만 운영자가 정한 비율(`STABLE_WEIGHT`/`CANARY_WEIGHT`, 기본 **`90:10`**)로 개방합니다. 이후 비율 확대·롤백은 재배포 없이 `scripts/set-canary-weight.sh`로 합니다.
- **Web / WAS 2-Tier 분리 및 정교한 오토스케일링**:
  - **Web 계층 (`web`, Nginx 1.27)**: 정적 에셋(`/resources/*`, `/webjars/*`) 직접 서빙 및 보안 응답 헤더 부여, 동적 요청은 WAS(`:8080`)로 프록시. CPU 사용률(60%) 기준 **HPA**(`web` 2~10, `web-canary` 1~4)로 수평 확장.
  - **WAS 계층 (`was`, Tomcat 11 + Java 21)**: 사전 언패킹된 `webapps/ROOT` 구동 및 **JMX Exporter**(`:9404/metrics`) 내장. Prometheus가 수집한 초당 요청 수(`> 50 req/s`)를 기반으로 **KEDA `ScaledObject`**(`was-stable` 2~10 / `fallback: 4`, `was-canary` 1~3 / `fallback: 2`)가 수평 확장.
  - **DB 커넥션 풀 예산 관리**: Pod당 Tomcat JDBC Pool 상한(`maxActive=10`)을 적용하여 최대 스케일 아웃 및 롤링 업데이트 중에도 RDS `db.t3.medium`의 `max_connections` 고갈을 방지합니다.
- **3-Tier 노드 역할 분리**:
  - `np-app` + `np-app-spot` (**Karpenter `NodePool`**): 애플리케이션(`NGF`, `web`, `was`) 전용. 기본 용량은 On-Demand(`np-app`, weight 100)에 보장하고 초과 부하만 Spot(`np-app-spot`)으로 확장.
  - `ng-critical` (**EKS 관리형 노드 그룹**, Taint `node-role=critical:NoSchedule`): 클러스터 핵심 컨트롤러(`CoreDNS`, `LBC`, `Metrics Server`, `Karpenter`, `KEDA`, `ESO`, `EBS CSI`, `OpenTelemetry Operator`) 및 DB 초기화 `Job` / 백업 `CronJob` 전용.
  - `ng-platform` (**EKS 관리형 노드 그룹**, Taint `node-role=platform:NoSchedule`): 모니터링 스택(`Prometheus` 2 Replicas Multi-AZ, `Grafana`, `Alertmanager`, `OTel Collector`, `Tempo`) 및 암호화 EBS `gp3` PVC(`WaitForFirstConsumer`) 전용.
- **분산 트레이싱 (APM, `docs/features/apm-tracing/design.md`)**:
  - **OpenTelemetry Operator**가 `was-stable`/`was-canary`에 Java agent를 init container로 주입합니다(이미지 재빌드 없음). 리소스 속성 `service.name=petclinic-was`, `service.version=stable|canary`로 카나리를 구분하고, 로그에는 MDC로 `trace_id`/`span_id`가 남습니다.
  - 헤드 샘플링은 agent(SDK)에서 `parentbased_traceidratio`(`OTEL_TRACES_SAMPLER_ARG`, 기본 `0.1`)로 하고, RED 메트릭(`http_server_request_duration_seconds`)은 샘플링 없이 100% 집계됩니다. exemplar는 샘플링된 트레이스에만 붙어 Grafana 패널에서 Tempo 트레이스로 바로 이동합니다.
  - 데이터 흐름과 포트:

    | 구간 | 포트 | 내용 |
    |---|---|---|
    | `was` → OTel Collector | `4317` gRPC / `4318` HTTP | OTLP 트레이스(10%) + 메트릭(100%, exemplar) |
    | Collector → Tempo | `4317` | OTLP gRPC (`memory_limiter` → `batch`) |
    | Prometheus → Collector | `8889` | OpenMetrics scrape (exemplar 포함) |
    | Grafana → Tempo | `3200` | TraceQL / trace 조회 |
    | Tempo → S3 | `443` | 전용 버킷 `TEMPO_S3_BUCKET_NAME` (SSE-KMS, 퍼블릭 차단, `TEMPO_RETENTION_DAYS` 만료), IRSA `monitoring/tempo` |
- **최소 권한 DB 계정 분리 및 시크릿 외부화**:
  - **RDS MySQL 8.4 LTS Multi-AZ**(Primary/Standby 동기 복제, `require_secure_transport=ON`)를 프라이빗 DB 서브넷에 격리합니다.
  - DB 계정을 역할별로 3분리하여 각각 **AWS Secrets Manager**와 **External Secrets Operator(ESO)** 로 동기화합니다:
    - `petclinic_admin` (`petclinic-rds-admin-secret`): `db-init` Job 전용 (스키마/데이터 적재 및 계정 관리)
    - `petclinic_app` (`petclinic-rds-secret`): `was-stable` / `was-canary` 전용 (`SELECT, INSERT, UPDATE, DELETE`만 허용)
    - `petclinic_backup` (`petclinic-rds-backup-secret`): `db-backup` CronJob 전용 (`mysqldump` 읽기 권한만 허용, S3 `SSE-KMS` 일일 백업)
- **컨테이너 및 네트워크 하드닝**:
  - 모든 워크로드 컨테이너는 비루트(`UID/GID 10001`), `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`로 실행됩니다.
  - `petclinic` 네임스페이스는 `default-deny-all` Ingress/Egress `NetworkPolicy`를 기본 적용하고 필수 통신만 허용하며, 모든 노드에 **IMDSv2 강제 및 Pod IMDS 차단**을 적용합니다.

---

## 2. 기술 스택 및 버전 명세

| 분류 | 구성 요소 | 버전 / 이미지 |
|---|---|---|
| **Application** | Spring Framework PetClinic | `7.0.3` (Spring `7.0.9`, Hibernate `7.4.11.Final`, Java 21 런타임) |
| **Web / WAS** | Nginx / Apache Tomcat 11 | `nginx:1.27.2-alpine`, `tomcat:11.0.2-jre21-temurin-noble`, `jmx_prometheus_javaagent:1.0.1` |
| **Kubernetes** | Amazon EKS / Worker AMI | EKS **`1.36`**, AL2023 **`al2023@v20260930`** |
| **Gateway / Ingress** | Gateway API / NGF / LBC | Gateway API CRDs **`v1.6.3`**, `nginx-gateway-fabric` **`2.8.0`**, `aws-load-balancer-controller` **`3.6.1`** |
| **Autoscaling** | Karpenter / KEDA / Metrics Server | Karpenter **`1.15.0`**, KEDA **`2.21.0`**, Metrics Server **`3.14.0`** |
| **Secrets / Storage** | ESO / EBS CSI Driver | `external-secrets` **`2.13.0`** (`v1` API), `aws-ebs-csi-driver` (`${EBS_CSI_ADDON_VERSION}`) |
| **Observability** | Prometheus Stack / Fluent Bit | `kube-prometheus-stack` **`92.11.0`** (Prometheus `v3.15.0`), `aws-for-fluent-bit` **`0.2.0`** (`3.2.1`) |
| **Tracing** | OTel Operator / Collector / Java agent / Tempo | `opentelemetry-operator` **`0.105.0`** (`0.144.0`), `opentelemetry-collector` **`0.116.0`** (`otel/opentelemetry-collector-contrib:0.120.0`), `autoinstrumentation-java:2.12.0`, `grafana-community/tempo` **`3.2.1`** (`grafana/tempo:3.1.1`) |
| **Database / Backup** | Amazon RDS for MySQL / S3 | MySQL **`8.4.11`** LTS (`db.t3.medium` Multi-AZ), `mysql:8.4.11`, `amazon/aws-cli:2.18.0` |

---

## 3. 사전 준비 사항 (Prerequisites)

1. **로컬 CLI 도구**:
   - `aws` (AWS CLI v2), `eksctl`, `kubectl`, `helm`, `docker`, `jq`, `envsubst` (`gettext`), `curl`
   - 오프라인 검증 및 테스트용: `python3` (`PyYAML` 패키지 포함), `promtool` (또는 Docker)
2. **AWS 네트워크 리소스 (입력값)**:
   - 서울 리전(`ap-northeast-2`)의 VPC 및 `ap-northeast-2a` / `ap-northeast-2c` 가용 영역별 서브넷 ID:
     - 퍼블릭 서브넷 2개 (`PUBLIC_SUBNET_A_ID`, `PUBLIC_SUBNET_C_ID`)
     - 앱 프라이빗 서브넷 2개 (`APP_PRIVATE_SUBNET_A_ID`, `APP_PRIVATE_SUBNET_C_ID`)
     - DB 프라이빗 서브넷 2개 (`DB_PRIVATE_SUBNET_A_ID`, `DB_PRIVATE_SUBNET_C_ID`)
   - Route 53 Hosted Zone ID (`ROUTE53_HOSTED_ZONE_ID`) 및 도메인 이름 (`DOMAIN_NAME`)

---

## 4. 빠른 시작 가이드 (Quickstart)

### Step 1. 환경변수 파일(`.env`) 구성
템플릿을 복사한 뒤 실제 AWS 계정·VPC 서브넷·도메인 정보를 입력합니다 (`.env` 파일은 `.gitignore`에 의해 커밋되지 않습니다).
```bash
cp .env.example .env
# .env 파일을 열어 AWS_ACCOUNT_ID, VPC_ID, 서브넷 ID, DOMAIN_NAME, EBS_CSI_ADDON_VERSION 등을 입력
```

### Step 2. AWS 주변 인프라 및 EKS 클러스터 프로비저닝
각 단계는 멱등(Idempotent)하게 동작하므로 중간에 중단되더라도 안전하게 재실행할 수 있습니다.
```bash
# 1) IAM Policy/Role, ECR 리포지토리, CloudWatch Log Group, 백업용·Tempo용 S3 버킷, CodeBuild(소스 버킷·서비스 역할·프로젝트), WAFv2 WebACL, ACM 인증서 생성
./infra/aws/provision-aws-resources.sh pre-cluster
# 출력된 ECR_*_REPOSITORY_URI, WAF_WEB_ACL_ARN, ACM_CERTIFICATE_ARN을 .env에 반영

# 2) eksctl 기반 EKS 1.36 클러스터(ng-critical, ng-platform) 생성 및 Karpenter discovery 태그 부여
./infra/aws/provision-aws-resources.sh cluster

# 3) RDS MySQL 8.4 LTS Multi-AZ(TLS 강제) 및 Secrets Manager 시크릿(admin/app/backup, Grafana, Alertmanager) 생성
./infra/aws/provision-aws-resources.sh post-cluster

# 4) /grafana 접근 허용 IP: .env 의 GRAFANA_ALLOWED_CIDRS(예: 203.0.113.7/32)로 WAF IP set과 차단 규칙(우선순위 0) 적용.
#    필수 — 이 규칙이 없으면 deploy-all.sh 가 시작 전에 멈춥니다. 허용 IP가 바뀌면 이것만 다시 실행합니다.
./infra/aws/provision-aws-resources.sh grafana-waf
```
> Grafana는 `https://<DOMAIN_NAME>/grafana/` 에서 열리며, 허용 IP 밖에서는 WAF가 403을 돌려줍니다. 관리자 계정은 Secrets Manager의 `GRAFANA_ADMIN_SECRET_NAME` 입니다.

### Step 3. `web` / `was` 컨테이너 이미지 빌드 및 ECR 푸시
```bash
IMAGE_TAG=v1.0.0 ./scripts/build-and-push.sh
```
> 이미지는 AWS CodeBuild에서 빌드됩니다. 스크립트가 작업 트리(커밋 안 된 변경 포함, `.gitignore` 대상과 `.env*`·키 파일 제외)를 zip으로 묶어 CodeBuild 소스 버킷(1일 후 자동 삭제)에 올리고, `buildspec.yml` 로 `linux/amd64` 빌드 → ECR 푸시까지 진행 상황을 따라갑니다. 같은 태그가 이미 ECR에 있으면 빌드 전에 멈춥니다. 한 이미지만 빌드하려면 `BUILD_TARGET=web` 또는 `was`, 로컬 Docker로 빌드하려면 `--local` 을 붙입니다. 실패하면 출력된 CloudWatch Logs 그룹(`/aws/codebuild/<프로젝트명>`)에서 원인을 확인합니다.

### Step 4. 클러스터 애드온·워크로드 전체 배포 및 카나리 검증
```bash
STABLE_IMAGE_TAG=v1.0.0 CANARY_IMAGE_TAG=v1.0.0 ./scripts/deploy-all.sh
```
> `deploy-all.sh`는 매니페스트 정적 검증(`validate-manifests.sh`) → 네임스페이스/StorageClass/Gateway API CRD 설치 → 클러스터 컨트롤러(LBC, Metrics Server, Karpenter, ESO) 설치 → Karpenter `np-app` 및 NGF 배포 → ESO 시크릿 동기화 대기 → 모니터링(Prometheus/Grafana/Alertmanager)·트레이싱(Tempo/OTel Collector, Operator는 컨트롤러 단계) 및 KEDA/Fluent Bit 설치 → `db-init` Job 및 `db-backup` CronJob 배포 → `HTTPRoute` `100:0` 격리 후 `was`/`web` 롤아웃 → Route 53 연결 → `X-Canary: always` 동적 경로 검증 → 통과 시 `STABLE_WEIGHT:CANARY_WEIGHT`(기본 `90:10`) 개방까지 순서대로 수행합니다.

---

## 5. 운영 및 검증 런북 (Day-2 Operations)

### 1) 오프라인 매니페스트 및 보안 정책 정적 검증
클러스터 연결 없이 YAML 문법, 이미지 태그 고정(`:latest` 금지), 평문 시크릿 부재, 3-Tier 노드 배치(`nodeSelector`/`tolerations`), 비루트 `securityContext`, 역할별 DB 시크릿 분리, 커넥션 풀 상한(`maxActive <= 10`), KEDA `fallback`, Prometheus Multi-AZ HA, PDB 등을 일괄 검사합니다.
```bash
./scripts/validate-manifests.sh
```

### 2) Prometheus 알림 규칙 단위 테스트
`PetClinicDBBackupFailed`(첫 성공 없음 / 26시간 초과 / 복구 시 해제), `PetClinicKedaMetricsError`, `PetClinicHttp5xxRateHigh` 알림 규칙을 `promtool`로 검증합니다.
```bash
./scripts/test-prometheus-rules.sh
```

### 3) 카나리 배포 / 승격 / 롤백
```bash
# 새 후보 버전(v1.1.0) 빌드 및 푸시
IMAGE_TAG=v1.1.0 ./scripts/build-and-push.sh

# Stable(v1.0.0)은 유지하고 Canary(v1.1.0)를 0%에서 검증 후 개방 (위험한 변경이면 5%처럼 작게)
STABLE_IMAGE_TAG=v1.0.0 CANARY_IMAGE_TAG=v1.1.0 STABLE_WEIGHT=95 CANARY_WEIGHT=5 ./scripts/deploy-all.sh

# 지표를 보며 재배포 없이 확대
./scripts/set-canary-weight.sh 25

# 카나리 이상 징후 발생 시 즉시 0%로 차단(롤백)
./scripts/set-canary-weight.sh 0

# 승격: 카나리 태그를 Stable로 재배포
STABLE_IMAGE_TAG=v1.1.0 CANARY_IMAGE_TAG=v1.1.0 ./scripts/deploy-all.sh
```

### 4) DB 비밀번호 무중단 회전 (Secret Rotation)
AWS Secrets Manager에서 `petclinic_app` 또는 `petclinic_backup` 비밀번호를 변경한 뒤 아래 스크립트를 실행하면, ESO 강제 동기화(`refreshTime` 갱신 확인) → `db-init` Job 재실행(`ALTER USER`) → `was-stable`/`was-canary` 롤링 재시작을 자동으로 수행합니다.
```bash
./scripts/rotate-db-secrets.sh
```

---

## 6. 디렉터리 구조 및 문서 안내

```text
.
├── .env.example                          # 환경변수 템플릿 (시크릿 평문 미포함)
├── ORCA_WORKFLOW.md                      # 3-에이전트 역할 분담 및 협업 워크플로
├── docs/
│   ├── architecture.md                   # 시스템 전체 아키텍처 상세 문서 (현재 기준)
│   ├── architecture.drawio{.svg,.png}    # 공식 AWS 아이콘 기반 아키텍처 다이어그램
│   ├── design.md                         # 초기 구축 아키텍처·환경 설계서
│   ├── review.md                         # 초기 구축 코드 리뷰 기록
│   ├── security.md                       # 초기 구축 보안·인프라 점검 기록
│   ├── daily/                            # 일일 작업 기록 (YYYY-MM-DD.md, TEMPLATE.md)
│   └── features/
│       └── production-hardening/         # 운영·보안·고가용성 강화 기능 문서
│           ├── design.md                 # 기능 설계서
│           ├── review.md                 # 기능 코드 리뷰 기록
│           └── security.md               # 기능 보안·인프라 점검 기록
├── app/                                  # spring-framework-petclinic 소스 코드 (WAR 빌드)
├── docker/                               # web (Nginx 1.27) 및 was (Tomcat 11 + JMX Exporter) Dockerfile
├── infra/                                # AWS 프로비저닝 스크립트, IAM 최소 권한 정책, eksctl, Karpenter
├── k8s/                                  # Kubernetes 매니페스트 (base, secrets, jobs, web, was, gateway, monitoring, logging, tracing)
├── tests/                                # PrometheusRule 단위 테스트 (promtool)
└── scripts/                              # 빌드·배포·시크릿 회전·정적 검증 자동화 스크립트
```

### 상세 문서 바로가기
- **시스템 아키텍처 명세**: [`docs/architecture.md`](./docs/architecture.md)
- **초기 설계 및 보안 감사**: [`docs/design.md`](./docs/design.md) · [`docs/security.md`](./docs/security.md) · [`docs/review.md`](./docs/review.md)
- **운영·보안 강화(`production-hardening`) 설계 및 감사**: [`docs/features/production-hardening/design.md`](./docs/features/production-hardening/design.md) · [`docs/features/production-hardening/security.md`](./docs/features/production-hardening/security.md) · [`docs/features/production-hardening/review.md`](./docs/features/production-hardening/review.md)
- **멀티 에이전트 워크플로**: [`ORCA_WORKFLOW.md`](./ORCA_WORKFLOW.md) (`Antigravity` 설계·보안 점검 / `Claude` 구현 / `Codex` 코드 리뷰)
- **일일 작업 기록**: [`docs/daily/`](docs/daily/)
