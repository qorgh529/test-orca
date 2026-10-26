# 보안 및 인프라 점검 결과 (`docs/features/graceful-shutdown/security.md`)

## Security Round 1 — 2026-10-26 (대상 커밋: 09ade7b)

점검 범위: `git diff master...HEAD` 전체(`docs/daily/2026-10-26.md`, `docs/features/graceful-shutdown/design.md`, `docs/features/graceful-shutdown/review.md`, `k8s/was/deployment-canary.yaml`, `k8s/was/deployment-stable.yaml`, `k8s/web/deployment.yaml`, `scripts/validate-manifests.sh` 및 이전 마스터 대비 변경분), `docs/architecture.md` 보안 아키텍처(§7), `docs/features/graceful-shutdown/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 안전하게 제외되어 있으며, 변경된 매니페스트 및 문서 내 데이터베이스 비밀번호, AWS 키, API 토큰 등 민감 자격증명 하드코딩 일체 없음).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md`, `design.md`, `review.md` 모두 전수 점검 결과 12자리 AWS 계정 ID, 실존 IAM ARN, 퍼블릭/프라이빗 실존 도메인 및 개인 URL 노출 없음).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (Kubernetes 수명주기 훅 `lifecycle.preStop.sleep`과 `terminationGracePeriodSeconds` 추가는 IAM 역할/권한 및 클러스터 RBAC의 변경을 전혀 요구하지 않음. Pod Security Context의 `automountServiceAccountToken: false`가 유지되어 ServiceAccount 토큰의 불필요한 노출이 차단됨).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (신규 네트워크 포트 개방 없음. Ingress 및 Service 정의 불변, 네임스페이스 간 NetworkPolicy 격리 및 VPC 보안 그룹 체계 온전히 유지).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 이상 없음 (`lifecycle.preStop.sleep`은 K8s v1.32+ GA 네이티브 선언형 정수 액션으로, 컨테이너 내부 쉘 프로세스 포크(`exec`) 없이 kubelet 타이머로 직접 실행되므로 커맨드 인젝션 및 임의 코드 실행 위험이 원천 차단됨. `scripts/validate-manifests.sh` §11 정적 검증 로직 역시 안전한 PyYAML 파싱과 정수형 타입/범위 검증으로 구현되어 외부 입력 취약점 없음).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (신규 외부 종속성 또는 라이브러리 추가 없음. `nginx:1.27.2-alpine`, `nginx-prometheus-exporter:1.3.0`, `tomcat:11.0.2-jre21-temurin-noble` 등 이미지 버전 고정 유지).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 이상 없음 (`web`, `web-canary`, `was-stable`, `was-canary` 4개 Deployment 모두 `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: drop: ["ALL"]`, `seccompProfile: RuntimeDefault` 비루트 샌드박싱 정책이 유지됨. 특히 네이티브 `sleep` 훅은 파일시스템 쓰기 권한이 불필요하므로 `readOnlyRootFilesystem: true` 정책과 완벽히 호환됨).
- **design.md 보안 요구사항 및 architecture.md 보안 구조 준수 여부**: `docs/features/graceful-shutdown/design.md` §5 보안 요구사항(Pod Security Standards Restricted 불변성, 서비스 거부/노드 리소스 고갈 방지 상한 설정, 시크릿 격리) 및 `docs/architecture.md` §7 보안 구조를 엄격히 준수함. `terminationGracePeriodSeconds` 상한(web 35초, was 45초)을 통해 비정상 종료 루프나 장기 연결 유지로 인한 클러스터 노드 리소스 점유 및 DoS 공격 가능성을 효과적으로 제한함.

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
지적 사항 없음.

### Low
- [ ] `docs/features/graceful-shutdown/design.md:162`, `docs/features/graceful-shutdown/design.md:176-180` — **설계 문서 내 WAS 런타임 종료 수명주기 설명의 아키텍처 정합성 보완 권고.** 설계서 §3.4 및 §1.2는 Spring Boot의 `PetClinicApplication.registerShutdownHook()` 및 HikariCP 커넥션 풀 반환을 전제로 기술되어 있으나, 본 프로젝트의 WAS 아키텍처(`docs/architecture.md` §3, `app/pom.xml`, `datasource-config.xml`)는 외부 톰캣(Tomcat 11 WAR 배포) 및 `org.apache.tomcat.jdbc.pool.DataSource`를 사용한다. 컨테이너 종료 시 실제 동작은 `catalina.sh`가 수신한 `SIGTERM`에 의해 Tomcat의 `StandardServer`/`StandardContext`가 정지되면서 서블릿 컨텍스트 파괴 및 Tomcat JDBC DataSource 풀이 닫히는 경로로 진행된다. `terminationGracePeriodSeconds: 45`는 이 정리 과정을 포괄하기에 충분하여 런타임 보안이나 서비스 가용성에 결함은 없으나, 운영 중 장애 분석 및 보안 인시던트 대응 혼선을 방지하기 위해 설계 문서의 종료 메커니즘 설명을 실제 런타임 스펙과 일치하도록 보완할 것을 권고한다.

### 총평
HTTP 502/504 방지를 위해 도입된 `lifecycle.preStop.sleep: 15s`와 적정 `terminationGracePeriodSeconds`(web 35초, was 45초) 설정은 기존 컨테이너 보안 샌드박스(`runAsNonRoot: true`, `readOnlyRootFilesystem: true`, capabilities ALL drop), 최소 권한 IRSA, 네트워크 격리 정책을 손상시키지 않으면서 서비스의 고가용성과 클러스터 자원 회수 예측 가능성을 안정적으로 보장한다. 네이티브 `preStop.sleep` 채택으로 쉘 의존성 및 커맨드 인젝션 위험을 원천 배제하였고, 시크릿 유출·식별자 노출·권한 과다 부여 등의 보안 결함은 전혀 없으므로 즉시 배포 가능하다.

배포 가능 여부: Yes
