# 보안 및 인프라 점검 결과 (`docs/features/daily-stop-start/security.md`)

## Security Round 1 — 2026-10-23 (대상 커밋: aaf3dd9)

점검 범위: `git diff master...HEAD` 전체(`.env.example`, `.gitignore`, `scripts/daily-stop.sh`, `scripts/daily-start.sh`, `scripts/validate-manifests.sh`, `docs/features/daily-stop-start/design.md`, `docs/daily/2026-10-23.md`), `docs/architecture.md` 보안 구조(§7), `docs/features/daily-stop-start/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 및 `.daily-nodegroup-state.json`은 `.gitignore`에 등록되어 추적되지 않으며, 신규 스크립트는 DB 비밀번호나 K8s Secret 데이터를 읽거나 출력하지 않음).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-23.md`, `docs/features/daily-stop-start/design.md`, `docs/features/daily-stop-start/review.md` 모두 플레이스홀더 사용 확인).
- **네트워크 노출 / 의존성 / Dockerfile·IaC**: 기존 보안 설정 변경 없음 (`k8s/`, `infra/`, `docker/`, `app/` 무변경).
- **권한 검증·입력 검증·설계 보안 요구사항 준수 여부**: 아래 High 1건, Medium 3건, Low 1건 확인.

### Critical
지적 사항 없음.

### High
- [x] (`3917898`) `scripts/daily-stop.sh:32`, `scripts/daily-start.sh:31`, `scripts/daily-start.sh:41` — `kubectl get` 실행 시 발생하는 모든 오류(`Forbidden` 권한 부족, 인증 만료 `Unauthorized`, API 서버 연결 실패 등)를 `2>/dev/null`로 숨기고 리소스 부재(`not found`)로 간주해 종료 코드 `0`을 반환한다. 이로 인해 중지 시(`daily-stop.sh`) 실행 주체의 RBAC 권한 누락이나 일시적 인증 오류로 `NodePool` 한도 `0` 패치 또는 `cronjob/db-backup` 일시 중지가 실패해도 이를 건너뛴 채 `ng-critical`(Karpenter 컨트롤러 실행 노드) 축소로 진행하여 앱 EC2 인스턴스(`np-app`, `np-app-spot`)가 종료되지 않고 방치될 수 있으며(`design.md` §3.2 순서 제약 위반), 기동 시(`daily-start.sh`) 핵심 보안·운영 컨트롤러(`external-secrets`, `karpenter`, `aws-load-balancer-controller`, `keda-operator`, `coredns`)나 `was`/`web` Deployment 조회가 거부되어도 모두 `skip` 처리한 뒤 최종 `Restored`를 출력하여 시크릿 동기화(ESO) 및 워크로드가 복원되지 않은 상태를 정상으로 오인하게 만든다. / 해결책: `kubectl get`의 실패 원인을 확인하여 실제 리소스 부재(`NotFound`)와 권한·인증·네트워크 오류를 구분하고, 조회 오류 발생 시 표준 에러를 보존하여 즉시 비정상 종료(`exit 1`)할 것. 또한 `daily-start.sh`에서 필수 컨트롤러 및 애플리케이션 Deployment가 존재하지 않는 경우에도 `skip`하지 않고 복원 실패(`exit 1`)로 처리할 것.

### Medium
- [x] (`3917898`) `scripts/daily-start.sh:50`, `scripts/daily-stop.sh:89`, `scripts/daily-start.sh:43` — 로컬 상태 파일(`.daily-nodegroup-state.json`) 및 클러스터·AWS CLI 응답 값에 대한 무결성·입력값 검증이 불완전하여 `design.md` §5.5(손상된 상태 파일이나 잘못된 값 검증)를 충족하지 못한다. `daily-start.sh:50`은 상태 파일이 손상된 JSON이거나 유효하지 않은 값(`desiredSize <= 0` 등)을 포함할 때 에러로 중단하지 않고 `2>/dev/null`로 무시한 뒤 기본값(`2 2 4`)으로 대체하며, `daily-stop.sh:89`의 `min`/`desired`/`max`와 `daily-start.sh:43`의 `cur`(`{.spec.replicas}`가 비어 있거나 비정상 문자열일 수 있음)는 정규식(`^[0-9]+$`) 검증 없이 Bash 산술 평가(`(( ... ))`)에 직접 사용되어 구문 오류나 예기치 않은 산술 식 평가 위험이 있다. / 해결책: `.daily-nodegroup-state.json` 파일이 존재할 경우 JSON 유효성 및 저장된 `minSize`/`desiredSize`/`maxSize`의 정수·범위(`desiredSize >= 1`, `minSize <= desiredSize <= maxSize`) 검증 실패 시 기본값으로 폴백하지 않고 즉시 `exit 1`로 중단할 것. 또한 `daily-stop.sh:89`의 `min`/`desired`/`max` 및 `daily-start.sh:43`의 `cur` 값도 산술 비교 전에 정수 형식(`^[0-9]+$`)을 검증할 것.
- [x] (`82d3c8f`) `docs/features/daily-stop-start/design.md:234`, `scripts/daily-start.sh:107` — `design.md` §5.3의 최소 권한 Kubernetes RBAC 명세에는 `petclinic`·`nginx-gateway` 네임스페이스 리소스와 클러스터 범위 Karpenter CRD만 기재되어 있으나, 실제 `scripts/daily-start.sh:107-110`은 `kube-system`(`coredns`, `karpenter`, `aws-load-balancer-controller`), `external-secrets`(`external-secrets`), `keda`(`keda-operator`) 네임스페이스의 `deployments`에 대해 `get` 및 `rollout status`를 호출한다. 설계서대로 최소 권한 RBAC을 구성하면 컨트롤러 Ready 확인 단계에서 권한 거부(`Forbidden`)가 발생한다. / 해결책: `docs/features/daily-stop-start/design.md:234`의 Kubernetes RBAC 권한 범위에 `kube-system`, `external-secrets`, `keda` 네임스페이스의 `deployments` 조회(`get`, `list`, `watch`) 권한을 명시하여 설계와 구현의 최소 권한 범위를 일치시킬 것.
- [x] (`3917898`) `scripts/daily-start.sh:80`, `scripts/daily-start.sh:95` — RDS가 `stopping` 상태일 때 기동 스크립트를 실행하면 시작 요청을 생략한 채 노드그룹을 먼저 기동한 뒤 113행의 `db-instance-available` 대기에서 실패하며, `daily-start.sh:95-98`에서 관리형 노드그룹의 현재 스케일 비교 시 `maxSize`를 누락하여 `maxSize`만 축소된 경우 원래 상한(`4`)을 복원하지 못한다(가용성 저하). / 해결책: `daily-start.sh`에서 RDS 상태가 `stopping`이면 `db-instance-stopped`까지 대기한 후 `start-db-instance`를 호출(또는 노드그룹 복원 전 명확한 안내와 함께 중단)하고, 노드그룹 스케일 비교 시 `minSize`, `desiredSize`, `maxSize` 세 값을 모두 확인하여 복원할 것.

### Low
- [x] (`3917898`) `scripts/daily-stop.sh:98` — 로컬 상태 파일(`.daily-nodegroup-state.json.tmp` → `.daily-nodegroup-state.json`) 생성 시 파일 권한을 제한하지 않아 기본 `umask`에 따라 동일 호스트의 다른 로컬 사용자가 스케일 상태 파일을 읽을 수 있으며, 기존 상태 파일이 손상된 경우 `jq` 실행이 실패한다. / 해결책: 상태 파일 작성 시 `umask 077`(또는 `chmod 600`)을 적용하여 파일 접근 권한을 소유자로 제한하고, 기존 상태 파일 파싱 실패 시 명확한 오류 메시지를 출력할 것.

배포 가능 여부: No

## Security Round 2 — 2026-10-23 (대상 커밋: 4c7375f)

점검 범위: `git diff master...HEAD` 전체(`.env.example`, `.gitignore`, `scripts/daily-stop.sh`, `scripts/daily-start.sh`, `scripts/validate-manifests.sh`, `tests/scripts/daily-stop-start.test.sh`, `docs/features/daily-stop-start/design.md`, `docs/features/daily-stop-start/review.md`, `docs/daily/2026-10-23.md`), `docs/architecture.md` 보안 구조(§7), `docs/features/daily-stop-start/design.md` 보안 요구사항(§5) 준수 여부 및 Round 1 `[x]` 항목 수정 검증.

### 점검 항목별 요약 및 Round 1 수정 확인
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`scripts/validate-manifests.sh` 통과, `.env` 및 `.daily-nodegroup-state.json`은 `.gitignore`로 추적 제외, 신규 스크립트 및 테스트 코드 내 시크릿 접촉 없음).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-23.md`의 Round 1~2 기록을 포함한 모든 문서에서 플레이스홀더 사용 확인).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (`82d3c8f`에서 `docs/features/daily-stop-start/design.md:235`에 `kube-system`, `external-secrets`, `keda` 네임스페이스 `deployments` 조회 권한(`get`, `list`, `watch`)이 반영되어 실제 스크립트 동작과 최소 권한 명세가 일치함).
- **네트워크 노출 / 의존성 / Dockerfile·IaC**: 기존 보안 설정 변경 없음 (`k8s/`, `infra/`, `docker/`, `app/` 무변경).
- **입력 검증 및 오류 전파 (Round 1 `[x]` 항목 재검증)**:
  - Round 1 High (`3917898`): `scripts/daily-stop.sh:30-38`에서 `NotFound`만 건너뛰고 권한 거부(`Forbidden`)·인증 만료 등 조회 오류 발생 시 관리형 노드그룹 축소 전에 즉시 중단(`exit 1`)하며, `scripts/daily-start.sh:28-37`에서 필수 리소스 조회·복원 실패 시 건너뛰지 않고 즉시 중단함을 코드 및 오프라인 회귀 테스트(`tests/scripts/daily-stop-start.test.sh` 15/15 통과)로 확인.
  - Round 1 Medium (`3917898`, `83672f5`, `aa34ebc`): 상태 파일 JSON 파싱 실패 및 범위(`desiredSize >= 1`, `minSize <= desiredSize <= maxSize`) 검증 실패 시 기본값 폴백 없이 중단, `scalingConfig` 및 `replicas` 산술 비교 전 정수 정규식(`^[0-9]+$`) 검증, RDS `stopping` 대기 후 기동, `minSize`/`desiredSize`/`maxSize` 3개 값 모두 비교 복원 확인.
  - Round 1 Low (`3917898`): `scripts/daily-stop.sh:101-106`에서 `umask 077`로 `.daily-nodegroup-state.json.tmp` 권한을 소유자로 제한하고 손상된 기존 상태 파일 덮어쓰기 거부 확인.

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
지적 사항 없음.

### Low
- [ ] `scripts/daily-start.sh:65`, `scripts/daily-start.sh:86` — 로컬 상태 파일(`.daily-nodegroup-state.json`) 및 `NG_*` 환경변수의 파싱·범위 검증(`target_size`)이 Step 2(86~91행)에서 수행되어, RDS가 `stopped` 상태일 때 손상된 상태 파일이나 잘못된 `NG_*` 값으로 실행하면 Step 1(78행)의 `aws rds start-db-instance` 호출이 먼저 실행된 뒤에 중단된다(`design.md` §3.3의 "변경 전에 중단" 원칙 대비 사전 검증 순서 미흡). / 해결책: Step 1의 RDS 시작 요청 전에 `ng-critical`, `ng-platform`의 `target_size` 파싱 및 정수·범위 검증을 먼저 수행하여 입력·상태 파일 오류 시 AWS 리소스 상태 변경 없이 즉시 중단할 것.

배포 가능 여부: Yes
