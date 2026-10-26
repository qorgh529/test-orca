# 보안 및 인프라 점검 결과 (`docs/features/rds-mysql-84/security.md`)

## Security Round 1 — 2026-10-26 (대상 커밋: 8e8dda0)

점검 범위: `git diff master...HEAD` 전체(`README.md`, `app/pom.xml`, `docs/daily/2026-10-26.md`, `docs/features/rds-mysql-84/design.md`, `docs/features/rds-mysql-84/review.md`, `infra/aws/provision-aws-resources.sh`, `k8s/jobs/cronjob-db-backup.yaml`, `k8s/jobs/job-db-init.yaml`, `scripts/validate-manifests.sh`), `docs/architecture.md` 보안 구조(§7), `docs/features/rds-mysql-84/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env`는 `.gitignore`로 보호되어 미추적 상태이며, 소스 코드 및 K8s 매니페스트 내 평문 패스워드 없음. AWS CLI 호출 시 표준 입력(`file:///dev/stdin`)으로 자격증명을 전달하여 프로세스 `argv` 노출 방지 확인).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md`, `README.md`, `design.md`, `review.md` 모두 플레이스홀더 사용 준수, 계정 ID·실존 ARN·엔드포인트·개인 URL 노출 없음).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (DB 계정 3분리 유지: `petclinic_admin`은 관리 전용, `petclinic_app`은 DML 4종으로 제한 및 DDL 차단, `petclinic_backup`은 읽기 전용 덤프 권한만 부여. `job-db-init`의 K8s 토큰 마운트 비활성화(`automountServiceAccountToken: false`), `cronjob-db-backup` IRSA의 S3 버킷 특정 접두어 쓰기 제한 유지).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (RDS `--no-publicly-accessible` 퍼블릭 차단 유지, DB 전용 프라이빗 서브넷 격리 유지, 파라미터 그룹 `require_secure_transport=ON` 및 사용자 계정 `REQUIRE SSL`, 클라이언트 `--ssl-mode=REQUIRED`/`sslMode=REQUIRED`로 전 구간 TLS 강제).
- **입력 검증 / 인젝션 / 경로 조작**: 이상 없음 (`job-db-init.yaml:43-45`에서 사용자명, 비밀번호, DB명에 대해 `[A-Za-z0-9_]` 정규식 검증을 수행하여 동적 SQL 조합 시 인젝션 위험 차단).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (RDS 엔진 버전 `8.4.11`, `job-db-init` 및 `cronjob-db-backup` 클라이언트 이미지 `mysql:8.4.11`, `app/pom.xml` 드라이버 `com.mysql:mysql-connector-j:8.4.0`으로 공식 LTS 버전 정확히 고정, `latest` 태그 미사용. `caching_sha2_password` 기본 인증 규격화 확인).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 이상 없음 (Job 컨테이너 모두 `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `drop: ["ALL"]`, `seccompProfile: RuntimeDefault` 적용. RDS EBS 볼륨 KMS 암호화(`--storage-encrypted`), Multi-AZ, S3 백업 SSE-KMS(`--sse aws:kms`) 암호화 유지).
- **보안 요구사항 및 아키텍처 보안 구조 준수 여부**: `docs/features/rds-mysql-84/design.md` §5 보안 요구사항 및 `docs/architecture.md` §7 보안 구조의 TLS Everywhere, 네트워크 격리, 최소 권한 원칙 준수 확인.

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
지적 사항 없음.

### Low
- [ ] `scripts/validate-manifests.sh:370` — **Connector/J 정적 버전 검증 정규식 느슨함 (`8.4.x` 전체 허용).** 설계서 §6 4단계 체크리스트에서는 Connector/J 버전을 `8.4.0`으로 검증하도록 규정하고 있으나, `scripts/validate-manifests.sh:370`에서는 `<mysql-driver\.version>8\.4\.\d+</mysql-driver\.version>` 정규식을 사용하여 미검증된 상위 버전(예: `8.4.999`)도 통과할 수 있다. 현재 `app/pom.xml`의 실제 설정값은 `8.4.0`으로 정상이지만, CI 정적 검증의 엄격성을 위해 `r"<mysql-driver\.version>8\.4\.0</mysql-driver\.version>"`으로 일치시키는 것을 권고한다.
- [ ] `infra/aws/provision-aws-resources.sh:294-296` — **기존 파라미터 그룹 존재 시 패밀리(`mysql8.4`) 불일치 검증 방어 로직 권고.** `provision-aws-resources.sh`의 `post_cluster()`는 `aws rds describe-db-parameter-groups --db-parameter-group-name "${db_id}-params"`의 존재 여부만 확인하고 기존 파라미터 그룹이 이미 존재할 경우 생성을 건너뛴다. 만약 이전 테스트나 프로비저닝 시도에서 `mysql8.0` 패밀리로 생성된 동명의 파라미터 그룹이 AWS 계정에 잔존해 있다면, 이후 `aws rds create-db-instance` 호출 시 `mysql8.0` 파라미터 그룹을 `8.4.11` 엔진에 바인딩하려다 AWS API 오류가 발생할 수 있다. 신규(Greenfield) 클러스터에서는 발생하지 않으나, 방어적 관점에서 describe 결과의 `DBParameterGroupFamily`가 `mysql8.4`인지 확인하거나 불일치 시 경고/재생성하는 방어 로직을 권고한다.

### 총평
MySQL 8.0 표준 지원 종료 및 신규 생성 불가 문제에 대응하여 8.4 LTS(`8.4.11`)로의 전환이 설계에 맞게 충실히 구현되었다. 전 구간 TLS 강제(`require_secure_transport=ON`, `REQUIRE SSL`), DB 3계층 역할 권한 분리, K8s 비루트 샌드박싱, 시크릿 외부화, 스토리지 KMS 암호화 등 기존 아키텍처의 강력한 보안 통제가 온전히 유지되고 있으며, 자격증명이나 실인프라 식별자 노출도 전혀 발견되지 않았다. 정적 검증 정규식 및 파라미터 그룹 패밀리 방어 로직(Low)은 배포를 차단할 수준의 결함이 아니므로 즉시 머지 및 배포가 가능하다.

배포 가능 여부: Yes
