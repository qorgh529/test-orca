# 보안 및 인프라 점검 결과 (`docs/features/tempo-chart-migration/security.md`)

## Security Round 1 — 2026-10-24 (대상 커밋: f460db3)

점검 범위: `git diff master...HEAD` 전체, `docs/architecture.md` 보안 구조(§7), `docs/features/tempo-chart-migration/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 미추적, `k8s/tracing/tempo-values.yaml` 내 `access_key`/`secret_key` 등 정적 AWS 자격증명 미사용 및 `serviceAccount: { create: false, name: tempo }` 기반 IRSA 전용 구성 유지, `scripts/validate-manifests.sh`로 정적 키 부재 검증 확인).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-24.md`, `docs/features/tempo-chart-migration/design.md`, `docs/features/tempo-chart-migration/review.md`, `README.md` 모두 플레이스홀더 사용 확인).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (기존 `infra/aws/iam-policies/tempo-policy.json` 및 `infra/eksctl/cluster.yaml`의 `monitoring/tempo` IRSA 최소 권한 구성이 변경 없이 유지됨).
- **네트워크 노출 (열린 포트, `0.0.0.0/0`, 공개 버킷)**: 이상 없음 (`grafana-community/tempo` `3.2.1` 차트가 렌더링하는 `StatefulSet/tempo`, `Service/tempo`, `Service/tempo-headless` 모두 `app.kubernetes.io/name: tempo` 레이블 및 ClusterIP/Headless로 생성되며, `k8s/tracing/networkpolicy-tracing.yaml:40-76`에 의해 Ingress는 `otel-collector`→`:4317`/`:4318`과 `grafana`→`:3200`만 허용되고 Egress는 DNS(`:53`) 및 외부 HTTPS(`:443`, IMDS `169.254.169.254/32` 제외)만 허용됨. `tempo.reportingEnabled: false`로 외부 사용량 리포팅 차단 및 S3 `insecure: false` 유지 확인).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 이상 없음 (`scripts/deploy-all.sh`의 `TEMPO_RETENTION_DAYS` 양의 정수 검증 및 `TEMPO_RETENTION_HOURS` 파생 치환 유지, `grafana-community/tempo` `3.2.1` 차트 템플릿에서 `backend_scheduler`와 `backend_worker` 양쪽의 `block_retention`에 동일하게 반영됨을 `helm template`으로 확인).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (deprecated 차트 `grafana/tempo` `1.24.4`에서 업스트림 지원 차트 `grafana-community/tempo` `3.2.1` 및 `grafana/tempo:3.1.1`로 명시적 고정 완료, `scripts/validate-manifests.sh:275-286`에서 `tempo.repository`/`tempo.tag` 고정 여부, deprecated 저장소/차트 참조 금지, `--version` 핀 고정을 정적 검증하도록 보강됨).
- **Dockerfile/IaC 및 `design.md` · `architecture.md` 보안 구조 준수 여부**: 이상 없음 (Pod `runAsNonRoot: true`, `runAsUser/Group/fsGroup: 10001`, `seccompProfile: RuntimeDefault`, 컨테이너 `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `gp3` `10Gi` PVC `/var/tempo` 마운트 및 Tempo 3.0에서 제거된 `memBallastSizeMbs` 정리 확인).

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
지적 사항 없음.

### Low
지적 사항 없음.

배포 가능 여부: Yes
