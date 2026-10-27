# 보안 및 인프라 점검 결과 (`docs/features/alert-5xx-accuracy/security.md`)

## Security Round 1 — 2026-10-27 (대상 커밋: c728872)

점검 범위: `git diff master...HEAD` 전체(`docs/daily/2026-10-27.md`, `docs/features/alert-5xx-accuracy/design.md`, `docs/features/alert-5xx-accuracy/review.md`, `k8s/monitoring/prometheusrule-petclinic.yaml`, `tests/monitoring/petclinic-rules.test.yaml`), `docs/architecture.md` 보안 구조(§7), `docs/features/alert-5xx-accuracy/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 미추적 상태를 유지하고 있으며, 변경된 매니페스트, 테스트 파일, 일일 기록 문서 내 AWS 자격증명, 토큰, DB 암호, 웹훅 URL 등 민감 자격증명 하드코딩 부재 확인).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-27.md`, `design.md`, `review.md` 점검 결과 12자리 AWS 계정 ID, 실존 ARN, 개인 URL 실값 노출 없음. `<DOMAIN>`, `<VPC_ID>`, `<grafana-svc>`, `${DOMAIN_NAME}` 등 플레이스홀더를 일관되게 사용함).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (IAM Policy, Role 및 K8s RBAC 권한 상승이나 변경 없음. `PrometheusRule` 리소스 정의 내의 PromQL 집계 수식 수정에 한정됨).
- **네트워크 노출 (열린 포트, `0.0.0.0/0`, 공개 버킷)**: 이상 없음 (신규 네트워크 포트 노출, Security Group, Ingress, NetworkPolicy 변경 없음. OTel Collector와 Prometheus 간 스크래핑 경로는 기존 `monitoring` 네임스페이스 내부 네트워크 격리 정책을 온전히 유지).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 이상 없음 (수정된 `PetClinicHttp5xxRateHigh` 알림 수식은 정적 PromQL 표현식으로 외부 입력 주입 위험이 없으며, 트래픽 미발생 시 0/0은 NaN 및 빈 결과로 처리되어 비정상 평가나 메모리 고갈 유발 위험 없음).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (외부 신규 패키지나 의존성 추가 없음).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 이상 없음 (Dockerfile 및 인프라 IaC 템플릿 변경 없음).
- **design.md 보안 요구사항 및 architecture.md 보안 구조 준수 여부**: `docs/features/alert-5xx-accuracy/design.md` §5 보안 요구사항(RBAC 접근 제어, 네트워크 격리, Slack Webhook 시크릿 격리, OTel Collector 메모리 보호 및 라벨 카디널리티 제어)과 `docs/architecture.md` §7 보안 구조를 충실히 준수함.

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
지적 사항 없음.

### Low
지적 사항 없음.

### 총평
Tomcat `errorCount` 지표에서 OpenTelemetry RED 메트릭(`http_server_request_duration_seconds_count`의 `5..` 상태 코드 필터링)으로의 전환은 4xx 클라이언트 오류로 인한 오경보를 효과적으로 방지하면서도 실제 5xx 서비스 장애 탐지 기능을 정상 유지한다. 검토 대상 커밋 전체에서 자격증명 유출, 클라우드 리소스 식별자 실값 노출, 권한 과다 부여, 네트워크 무단 노출 등의 보안 결함은 전혀 발견되지 않았다.

배포 가능 여부: Yes
