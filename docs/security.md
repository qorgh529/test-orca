# 보안 및 인프라 점검 결과 (`docs/security.md`)

## Security Round 1 — 2026-10-21 (대상 커밋: 3e68abb)

점검 범위: `git diff master...HEAD` 전체 및 `docs/design.md` 보안 요구사항 준수 여부.

### Critical
- [x] `k8s/was/deployment-stable.yaml:37`, `k8s/was/deployment-canary.yaml:37`, `docker/was/setenv.sh:7` — JMX Exporter(`-javaagent:/opt/jmx/jmx_prometheus_javaagent.jar=9404:/opt/jmx/config.yaml`)가 `0.0.0.0:9404`로 바인딩되며, Amazon VPC CNI에서 `enableNetworkPolicy: "true"`를 켜더라도 기본적으로 `strictMode`가 비활성(`false`)이므로 VPC 내 다른 서브넷/노드나 초기 CNI 정책 동기화 지연 시 무인증 `:9404/metrics` 엔드포인트에 접근할 수 있다. 또한 `k8s/web/deployment.yaml:60`의 `nginx-prometheus-exporter` 사이드카(`:9113`) 역시 별도 인증 없이 노출된다. / 해결책: `infra/eksctl/cluster.yaml:50`의 `vpc-cni` 애드온 `configurationValues`에 `"enableNetworkPolicy": "true"`와 함께 `"nodeAgent": {"enablePolicyEventLogs": "true"}` 등을 명시하고, `k8s/was/networkpolicy.yaml` 및 `k8s/web/networkpolicy.yaml`에 Default Deny Ingress/Egress 또는 Egress 제한 정책을 추가하여 `petclinic` 네임스페이스 Pod들의 불필요한 외부/동서(East-West) 통신을 차단할 것. → 8ca70ab (petclinic default-deny ingress/egress + policy event logs)

### High
- [x] `infra/aws/provision-aws-resources.sh:91`, `scripts/deploy-all.sh:106` — Route 53 레코드 변경 시 `$DOMAIN_NAME`, `$alb`, `$alb_zone` 값을 문자열 보간(`"{\"Changes\":...\"Name\":\"$DOMAIN_NAME\"...}"`)으로 직접 JSON에 삽입하고 있어, 환경변수 값에 따옴표나 제어문자가 포함될 경우 JSON 구문 파괴 및 명령 인젝션 위험이 있다. / 해결책: `jq -n --arg domain "$DOMAIN_NAME" --arg alb "$alb" --arg zone "$alb_zone" ...` 형태로 안전하게 JSON 페이로드를 생성하여 전달할 것. → ae73c89
- [x] `infra/aws/provision-aws-resources.sh:137`, `infra/aws/provision-aws-resources.sh:154`, `infra/aws/provision-aws-resources.sh:161` — RDS 마스터 비밀번호 및 Secrets Manager 시크릿 생성 시 `<<<"{\"MasterUserPassword\":\"$password\"}"`와 같이 직접 문자열 결합으로 JSON을 구성하고 있으며, RDS 생성 시 `--kms-key-id` 및 Secrets Manager 생성 시 `--kms-key-id`가 누락되어 기본 키에 의존하거나 설계서 §5.3.2(KMS 암호화 저장) 명시가 불완전하다. 또한 `aws rds create-db-instance`에 `--no-auto-minor-version-upgrade` 방어나 로그 내보내기(`--enable-cloudwatch-logs-exports '["error","slowquery"]'`)가 없고 IAM DB 인증이나 SSL 강제 파라미터 그룹이 빠져 있다. / 해결책: `jq -n --arg pw "$password"`로 JSON을 안전하게 생성하고, `--storage-encrypted` 유지와 함께 CloudWatch 로그 내보내기(`error`, `slowquery`) 및 MySQL `require_secure_transport=ON` 파라미터 그룹(또는 동등한 TLS 강제 설정)을 추가할 것. → ae73c89 (KMS는 AWS 관리형 키 유지)
- [x] `infra/eksctl/cluster.yaml:65`, `infra/eksctl/cluster.yaml:78` — `ng-critical` 및 `ng-platform` 관리형 노드 그룹에 IMDSv2 강제 및 홉 제한(`disableIMDSv1: true`, `podIMDS: false` 또는 `metadataOptions: { httpTokens: required, httpPutResponseHopLimit: 1 }`)이 설정되어 있지 않다(`infra/karpenter/ec2nodeclass.yaml:18`에는 설정되어 있으나 관리형 노드 그룹 2곳에 누락됨). `ng-critical`과 `ng-platform`에서 실행되는 Pod가 노드 IAM Role 자격증명(IMDS)에 접근할 수 있어 최소 권한 원칙(§5.2.1)을 우회할 위험이 있다. / 해결책: `infra/eksctl/cluster.yaml`의 `ng-critical`, `ng-platform` 두 노드 그룹 모두에 `disableIMDSv1: true` (및 호환 설정)를 명시하여 IMDSv1을 차단하고 Pod의 노드 메타데이터 접근을 제한할 것. → 20de861
- [x] `app/pom.xml:590` — `PostgreSQL` 프로필에 `<jdbc.password>petclinic</jdbc.password>` 평문 패스워드가 하드코딩되어 있다. `scripts/validate-manifests.sh:81`에서 `MySQL` 프로필만 검사하여 누락되었으나, 설계서 §5.3.1("`pom.xml`, `data-access.properties`, `Dockerfile`, Kubernetes YAML 등 어떤 파일에도 실제 DB 비밀번호나 API 키를 넣지 않는다")을 위반한다. / 해결책: `app/pom.xml:590`의 `<jdbc.username>`과 `<jdbc.password>`를 빈 태그(`<jdbc.username/>`, `<jdbc.password/>`)로 비우고, `scripts/validate-manifests.sh`가 `pom.xml` 전체 프로필에서 하드코딩된 `<jdbc.password>`를 검사하도록 강화할 것. → 6e8fb37
- [x] `app/src/main/resources/spring/datasource-config.xml:36` — `<jdbc:initialize-database>`가 활성화되어 있어, `was` (Tomcat 11) Pod가 기동될 때마다(스케일 아웃 및 카나리 배포 포함) 매번 `schema.sql`과 `data.sql`을 RDS MySQL에 실행한다. 이미 `k8s/jobs/job-db-init.yaml`이 `ng-critical`에서 DB 초기화를 전담하도록 설계되어 있으므로(§3.2⑥, §6 Step 4), WAS 기동 시 중복 스크립트 실행은 경합 조건(Race Condition) 및 불필요한 DDL 권한 요구를 유발한다. / 해결책: `MySQL` 프로필 빌드 또는 운영 구동 시 `<jdbc:initialize-database enabled="${jdbc.initEnabled:false}">` 등으로 제어하여 `was` 컨테이너 기동 시에는 자동 DDL/DML 초기화가 실행되지 않고 `db-init` Job만 초기화를 수행하도록 분리할 것. → 52fe211

### Medium
- [x] `k8s/base/namespace.yaml:9` — `petclinic` 네임스페이스에만 Pod Security Standards(`pod-security.kubernetes.io/enforce: restricted`)가 적용되어 있고, `nginx-gateway`, `monitoring`, `external-secrets`, `keda`, `amazon-cloudwatch` 네임스페이스에는 PSS 레이블(`enforce` 또는 `warn`/`audit`)이 전혀 없다. / 해결책: 각 네임스페이스 특성에 맞게 `restricted` 또는 `baseline`(`amazon-cloudwatch` 등 호스트 경로 접근이 필요한 곳은 `privileged` 또는 `warn: baseline`) PSS 레이블을 명시할 것. → 2a9c21a
- [x] `k8s/was/deployment-stable.yaml:60`, `k8s/was/deployment-canary.yaml:60` — `web` 컨테이너와 `db-init`/`db-backup` Job에는 `readOnlyRootFilesystem: true`가 설정되어 있으나, `was` (Tomcat 11) 컨테이너의 `securityContext`에는 `readOnlyRootFilesystem: true`가 누락되어 있다. 컨테이너 침해 시 루트 파일시스템 변조 위험이 있다. / 해결책: `was` 컨테이너에도 `readOnlyRootFilesystem: true`를 설정하고, Tomcat 런타임 쓰기 경로(`webapps`, `work`, `temp`, `logs`, `conf/Catalina`)를 `emptyDir` 볼륨으로 마운트(또는 WAR 사전 압축 해제 후 필요한 디렉터리만 `emptyDir` 마운트)할 것. → 414d57f
- [x] `docker/web/nginx.conf:23`, `docker/web/nginx.conf:29`, `docker/web/nginx.conf:33` — Nginx 응답에 기본 보안 헤더(`X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`)가 누락되어 있으며, `location /resources/`와 `location /webjars/`에서 `add_header Cache-Control`을 사용할 때 상위 보안 헤더가 상속되지 않는 Nginx 특성을 고려해야 한다. / 해결책: `docker/web/nginx.conf`에 공통 보안 응답 헤더를 추가할 것. → fe2d698
- [x] `k8s/gateway/alb-ingress.yaml:7` — internet-facing ALB에 `alb.ingress.kubernetes.io/load-balancer-attributes: routing.http.drop_invalid_header_fields.enabled=true` 설정이 누락되어 있어 비표준/비정상 HTTP 헤더를 통한 HTTP Request Smuggling 방어가 약화될 수 있다. / 해결책: `k8s/gateway/alb-ingress.yaml`의 annotations에 `alb.ingress.kubernetes.io/load-balancer-attributes: routing.http.drop_invalid_header_fields.enabled=true`를 추가할 것. → e14535f

### Low
- [-] `docker/web/Dockerfile:8` — `docker/was/Dockerfile:14`에서는 외부 아티팩트(`jmx_prometheus_javaagent.jar`)에 대해 SHA256 체크섬 검증을 수행하지만, `docker/web/Dockerfile` 및 `infra/eksctl/cluster.yaml:52`(`kube-proxy`, `vpc-cni`, `coredns` 애드온)에는 버전이 고정되어 있지 않다(`aws-ebs-csi-driver`만 버전 명시됨). / 해결책: `infra/eksctl/cluster.yaml:48-56`의 `vpc-cni`, `kube-proxy`, `coredns` 애드온에도 EKS 1.31 호환 고정 버전(또는 명시적 관리 정책)을 지정하거나 검증 스크립트에서 확인할 것. → 정확한 1.31용 eksbuild 버전을 이 환경에서 검증할 수 없어 고정하지 않음; 버전 생략 시 eksctl이 클러스터 버전의 기본 애드온 버전을 설치함
- [x] `app/src/main/resources/spring/data-access.properties:11` — `jpa.showSql=true`가 기본 활성화되어 있어 운영 환경에서 모든 SQL 쿼리가 컨테이너 표준 출력(Fluent Bit → CloudWatch Logs)에 기록되며, 민감한 개인정보(Owner 이름, 주소, 전화번호 등)가 로그에 과다 노출될 수 있다. / 해결책: `jpa.showSql=${jpa.showSql:false}` 또는 `MySQL` 운영 프로필에서 `false`가 되도록 변경할 것. → 0b98cd5

배포 가능 여부: No

## Security Round 2 — 2026-10-22 (대상 커밋: b6d77ac)

점검 범위: `git diff master...HEAD` 전체, Security Round 1 조치 내역 재검증 및 `docs/design.md` 보안 요구사항(§5.1~§5.4) 준수 여부.

### Critical
지적 사항 없음. (Round 1의 `k8s/base/networkpolicy-petclinic.yaml` Default Deny Ingress/Egress 정책 및 `infra/eksctl/cluster.yaml:51` VPC CNI 정책 이벤트 로깅 반영 확인 완료)

### High
지적 사항 없음. (Round 1의 `jq -n` 기반 안전한 JSON 생성, RDS `require_secure_transport=ON` 및 CloudWatch 로그 내보내기, `ng-critical`/`ng-platform`의 `disableIMDSv1: true`·`disablePodIMDS: true` 설정, `app/pom.xml` 전 프로필 평문 패스워드 제거 및 검증 스크립트 강화, `MySQL` 프로필 기동 시 자동 DB 초기화 비활성화 모두 반영 확인 완료)

### Medium
지적 사항 없음. (Round 1의 전 네임스페이스 PSS 레이블 적용, `was` 컨테이너 `readOnlyRootFilesystem: true` 및 `emptyDir` 마운트, `docker/web/nginx.conf` 보안 응답 헤더 추가, `k8s/gateway/alb-ingress.yaml`의 `drop_invalid_header_fields.enabled=true` 설정 모두 반영 확인 완료)

### Low
지적 사항 없음. (Round 1의 `app/src/main/resources/spring/data-access.properties:13` `jpa.showSql=false` 기본값 반영 확인 완료)

배포 가능 여부: Yes

## Security Round 3 — 2026-10-22 (대상 커밋: 9f7953e)

점검 범위: `git diff master...HEAD` 전체, `docs/design.md` 보완 요구사항(Step 8~12) 및 운영·보안·고가용성 심층 점검.

### Critical
지적 사항 없음.

### High
- [x] `infra/aws/provision-aws-resources.sh:148`, `infra/aws/provision-aws-resources.sh:159`, `k8s/was/deployment-stable.yaml:41`, `k8s/jobs/cronjob-db-backup.yaml:55` — RDS 마스터 계정(`petclinic_admin`) 하나만 생성하여 `was-stable`/`was-canary`(애플리케이션), `db-init`(초기화), `db-backup`(백업)이 모두 동일한 마스터 권한 자격증명을 공유한다. 애플리케이션 침해 시 테이블 삭제(`DROP`)/권한 변경(`GRANT`) 등 과도한 DB 권한이 노출되어 최소 권한 원칙(§5.3.2)을 위반하며, ESO가 시크릿을 갱신해도 실행 중인 Pod 환경변수가 자동 갱신되지 않는다. / 해결책: `RDS_SECRET_NAME`(`petclinic_admin`: `db-init` 전용), `RDS_APP_SECRET_NAME`(`petclinic_app`: `SELECT, INSERT, UPDATE, DELETE`만 허용, `was` 전용), `RDS_BACKUP_SECRET_NAME`(`petclinic_backup`: `SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, PROCESS`만 허용, `db-backup` 전용)으로 시크릿과 DB 계정을 분리하고, 시크릿 회전 시 롤링 재시작 절차를 반영할 것. → 15c6180, d4d5a7f (회전 절차: `scripts/rotate-db-secrets.sh`)
- [x] `app/src/main/resources/spring/datasource-config.xml:30`, `k8s/was/keda-scaledobject.yaml:11` — Tomcat JDBC Connection Pool에 `maxActive`, `maxIdle`, `maxWait` 상한이 설정되어 있지 않아 기본값(`maxActive=100`)이 적용된다. `was-stable`(최대 10개) + `was-canary` + 롤링 업데이트 시 최대 1,100개 이상의 연결을 요청하여 RDS `db.t3.medium`의 `max_connections` 한도를 고갈시킬 수 있다(가용성 침해/DoS 위험). / 해결책: `datasource-config.xml`(및 `data-access.properties`)에 `maxActive=10`, `maxIdle=5`, `minIdle=2`, `initialSize=2`, `maxWait=5000`, `testOnBorrow=true`, `validationQuery="SELECT 1"`을 명시하여 최대 확장 시에도 RDS 연결 예산 내로 제한할 것. → 15c6180
- [x] `k8s/was/deployment-stable.yaml:34`, `k8s/was/deployment-canary.yaml:34`, `k8s/web/deployment.yaml:35`, `k8s/web/deployment.yaml:105`, `scripts/deploy-all.sh:99` — Stable과 Canary Deployment가 모두 동일한 `${IMAGE_TAG}`를 참조하여 새 버전 배포 시 Stable과 Canary가 동시에 덮어써지며, `deploy-all.sh`에서 `httproute-canary.yaml`(10% 카나리)을 먼저 적용한 뒤 Canary rollout 및 검증을 수행하여 실패 시에도 사용자 트래픽 10%가 장애 버전으로 유입된다. / 해결책: `STABLE_IMAGE_TAG`와 `CANARY_IMAGE_TAG`(및 `STABLE_WEIGHT`/`CANARY_WEIGHT`)를 분리하고, `deploy-all.sh`에서 카나리 가중치 `0%`(`100/0`) 상태로 Canary를 먼저 롤아웃 및 `X-Canary: always` 동적 경로 검증 후 통과 시에만 `90/10`으로 개방(실패 시 `100/0` 유지·롤백)하도록 수정할 것. → 1f31c91
- [x] `k8s/monitoring/kube-prometheus-values.yaml:13`, `k8s/was/keda-scaledobject.yaml:14`, `k8s/web/deployment.yaml:22`, `k8s/was/deployment-stable.yaml:22` — Prometheus가 단일 레플리카(기본값 1) 및 단일 AZ 귀속 EBS `gp3` PVC로 동작하며, KEDA `ScaledObject`에 `fallback` 설정이 없어 해당 AZ 장애 시 모니터링과 `was` 오토스케일링이 동시에 마비된다. 또한 `web`과 `was`에 `PodDisruptionBudget`(PDB)이 없고 `whenUnsatisfiable: ScheduleAnyway`로 되어 있어 노드 교체/장애 시 가용성이 저하될 수 있다. / 해결책: `kube-prometheus-values.yaml`에 Prometheus `replicas: 2` 및 AZ 분산 설정을 추가하고, `keda-scaledobject.yaml`에 `fallback: { failureThreshold: 3, replicas: 4 }`를 설정하며, `web`/`was`용 PDB(`k8s/web/pdb.yaml`, `k8s/was/pdb.yaml`)와 `DoNotSchedule` AZ 분산을 구성할 것. → 48b9705
- [ ] `infra/eksctl/cluster.yaml:9`, `infra/eksctl/cluster.yaml:58`, `infra/karpenter/ec2nodeclass.yaml:10` — 2026-10 기준 확장 지원 종료가 임박한 EKS `1.31`과 구버전 AMI(`al2023@v20241024`)가 고정되어 있어 보안 패치 수명주기 및 신규 구축 기준에 부합하지 않는다. / 해결책: 표준 지원 버전인 EKS `1.33`과 호환되는 AL2023 AMI 고정 릴리스(`al2023@v20260923` 등) 및 `aws-ebs-csi-driver`(`v1.37.0-eksbuild.1` 이상) 호환 버전 세트로 상향할 것. → 보류: 1.33은 2026-07-29부터 확장 지원 구간이고 Karpenter 1.0.6과 호환되지 않음. design.md Q4 결정 대기

### Medium
- [x] `k8s/was/deployment-canary.yaml:9`, `k8s/web/deployment.yaml:80` — Canary Deployment(`was-canary`, `web-canary`)가 `replicas: 1`로 고정되어 있고 오토스케일러가 없어 전체 트래픽이 증가할 때 10%를 받는 Canary가 먼저 포화(병목/5xx 유발)될 수 있다. / 해결책: `k8s/web/hpa.yaml`에 `web-canary` HPA(`minReplicas: 1`, `maxReplicas: 4`)를 추가하고, `k8s/was/keda-scaledobject.yaml`에 `was-canary`용 `ScaledObject`(`minReplicaCount: 1`, `maxReplicaCount: 3`)를 추가할 것. → 1f31c91
- [x] `k8s/monitoring/kube-prometheus-values.yaml:28` — Alertmanager가 기본 `null` receiver 상태로 배포되며 핵심 장애(DB 백업 실패, KEDA 지표 조회 실패, HTTP 5xx 급증)에 대한 `PrometheusRule`이 정의되어 있지 않아 보안·운영 사고 발생 시 알림이 전달되지 않는다. / 해결책: `kube-prometheus-values.yaml`에 `${ALERTMANAGER_WEBHOOK_URL}` 수신처를 구성하고, `k8s/monitoring/prometheusrule-petclinic.yaml`에 백업 실패·KEDA 오류·5xx 급증 알림 규칙을 추가할 것. → 48b9705 (5xx 알림은 Tomcat errorCount 기반이라 4xx 포함)
- [x] `infra/aws/provision-aws-resources.sh:8`, `scripts/validate-manifests.sh:109`, `docs/review.md:65` — `provision-aws-resources.sh`가 재실행 불가(non-idempotent) 구조여서 일부 리소스 생성 후 중단 시 복구가 어렵고, `validate-manifests.sh`가 신규 운영·보안 요구사항(DB 계정 분리, 커넥션 풀 상한, KEDA fallback, PDB, Prometheus HA)을 검사하지 않으며, `docs/review.md`의 마지막 총평이 이전 미해결 상태(`No`)로 남아 있다. / 해결책: `provision-aws-resources.sh`의 각 생성 단계에 존재 여부 확인(멱등성) 로직을 추가하고, `validate-manifests.sh` 검증 규칙을 확장하며, 리뷰 문서 상태를 최신화할 것. → 5f8703a (review.md 총평은 리뷰어 작성 내용이라 수정하지 않음, design.md Q5)

### Low
지적 사항 없음.

배포 가능 여부: No
