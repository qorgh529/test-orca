# 보안 및 인프라 점검 결과 (`docs/features/spread-on-rollout/security.md`)

## Security Round 1 — 2026-10-26 (대상 커밋: f5c8987)

점검 범위: `git diff master...HEAD` 전체(`docs/daily/2026-10-26.md`, `docs/features/spread-on-rollout/design.md`, `docs/features/spread-on-rollout/review.md`, `k8s/was/deployment-canary.yaml`, `k8s/was/deployment-stable.yaml`, `k8s/web/deployment.yaml`, `scripts/validate-manifests.sh` 및 이전 마스터 대비 변경분), `docs/architecture.md` 보안 구조(§7), `docs/features/spread-on-rollout/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 미추적 상태를 유지하고 있으며, 변경된 매니페스트 및 스크립트에 평문 비밀번호, AWS 액세스 키, 토큰 등 민감 자격증명 하드코딩 없음).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md`, `design.md`, `review.md` 모두 점검 결과 12자리 AWS 계정 ID, 실존 ARN, 프라이빗/퍼블릭 엔드포인트 URL, 개인 URL 노출 없음).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (Kubernetes 스케줄링 옵션 `matchLabelKeys` 추가는 RBAC 권한 상승이나 신규 IAM 권한을 요구하지 않음. Pod Security Context의 `automountServiceAccountToken: false`가 유지되어 클러스터 API 토큰의 불필요한 노출 차단).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (신규 네트워크 포트 개방 없음. VPC 보안 그룹 및 네임스페이스 격리 NetworkPolicy 체계가 온전히 유지됨).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 이상 없음 (`scripts/validate-manifests.sh`에 추가된 §10 토폴로지 분산 검증 로직은 안전한 PyYAML 파싱 및 딕셔너리 순회를 기반으로 동작하여 외부 입력 인젝션 위험 없음).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (신규 외부 라이브러리나 의존성 추가 없음. EKS 1.36 클러스터의 내장 스케줄러 GA 기능 `matchLabelKeys` 활용).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 이상 없음 (컨테이너 매니페스트 `web`, `web-canary`, `was-stable`, `was-canary` 모두 `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities: drop: ["ALL"]`, `seccompProfile: RuntimeDefault` 비루트 샌드박싱 정책 불변).
- **design.md 보안 요구사항 및 architecture.md 보안 구조 준수 여부**: `docs/features/spread-on-rollout/design.md` §5 보안 요구사항(Pod Security Standards, 최소 권한, 시크릿 격리 유지) 및 `docs/architecture.md` §7 보안 구조를 충실히 준수함. 가용영역(AZ) 간 Pod 균등 분산을 보장함으로써 단일 가용영역 장애 시 서비스 단절 위험을 완화하여 인프라 가용성/복원력 향상 확인.

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
지적 사항 없음.

### Low
- [x] (5b4f35e) `scripts/validate-manifests.sh:393` — **`matchLabelKeys` 정적 검증 시 스칼라 타입 허용 (리스트 타입 검증 부재).** `scripts/validate-manifests.sh:393`의 `"pod-template-hash" not in (c.get("matchLabelKeys") or [])` 조건문은 Python에서 문자열에 대한 부분 문자열 검사(`"pod-template-hash" in "pod-template-hash"`)로도 참이 되어, `matchLabelKeys: "pod-template-hash"`와 같은 잘못된 스칼라 설정이 들어와도 정적 검증을 통과할 수 있다. Kubernetes API 스키마상 `matchLabelKeys`는 `[]string` 리스트 타입이어야 하므로, `isinstance(c.get("matchLabelKeys"), list)` 및 원소 포함 여부를 함께 검사하도록 보완을 권고한다. (현재 `web`, `web-canary`, `was-stable`, `was-canary` 4개 매니페스트는 올바른 리스트 `[pod-template-hash]`로 작성되어 있어 실제 런타임 오류는 발생하지 않음).
- [x] (acf5368) `docs/features/spread-on-rollout/design.md:225-228` — **스케일다운(Scale-Down) 시 AZ 균등 유지 한계에 대한 가용성/인프라 설명 보완 권고.** 설계서 §3.3에는 `matchLabelKeys`가 HPA/KEDA 축소 시에도 완벽한 대칭성을 보장한다고 기술되어 있으나, Kubernetes `topologySpreadConstraints`는 신규 Pod의 스케줄링 시점에만 평가되며 ReplicaSet 컨트롤러의 축소 대상 Pod 선택 시에는 AZ 균등을 강제하지 않는다(Kubernetes 알려진 한계). 따라서 급격한 HPA 스케일다운 후 2개 Pod가 단일 AZ(예: 2:0)에 남게 될 가능성이 존재하므로, 재해 복구(DR) 및 고가용성 관점에서 축소 후 불균형 모니터링 방안이나 롤링 재시작을 통한 치유 가이드를 문서에 명시할 것을 권고한다.

### 총평
롤링 업데이트 중 가용영역(AZ) 간 Pod 편중을 방지하기 위한 `matchLabelKeys: [pod-template-hash]` 도입은 기존 컨테이너 보안 샌드박스(`runAsNonRoot: true`, `readOnlyRootFilesystem: true`, capabilities drop), 최소 권한 IRSA, 네트워크 격리 정책을 손상시키지 않으면서 인프라의 장애 복원력과 고가용성을 크게 강화한다. 시크릿 유출, 식별자 노출, 권한 과다 부여 등의 보안 결함은 전혀 없으며, 정적 검증 타입 체크 보완 및 스케일다운 시 동작 명시(Low)는 배포를 차단할 사안이 아니므로 안전하게 배포 가능하다.

배포 가능 여부: Yes
