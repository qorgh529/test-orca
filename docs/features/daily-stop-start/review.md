# daily-stop-start 코드 리뷰

## Review Round 1 — 2026-10-23 (대상 커밋: 7a04058)

리뷰 범위: `git diff master...HEAD` 전체. 기준: `docs/architecture.md`, `docs/features/daily-stop-start/design.md`, `ORCA_WORKFLOW.md`. 첫 라운드이므로 이전 완료 항목은 없음.

### Critical
- 지적 사항 없음.

### High
- [x] (`3917898`) **H1 — 조회 오류를 부재로 간주하여 필수 중지·복원 단계를 성공 처리함.** `scripts/daily-start.sh:31`, `scripts/daily-start.sh:41`, `scripts/daily-stop.sh:32` — `kubectl get`의 모든 실패(Forbidden, 인증 만료, 연결 오류 포함)를 `not found`로 출력하고 0을 반환한다. 기동 시 필수 컨트롤러의 Ready 확인과 WAS 스케일 업·rollout을 건너뛴 채 마지막 `Restored`까지 도달할 수 있다. 중지 시 NodePool 조회만 실패하면 신규 노드 생성 차단 없이 NodeClaim 삭제와 관리형 노드 축소를 진행할 수 있어, 설계 §3.2의 앱 노드 종료 보장도 깨진다. 실제 NotFound와 조회 실패를 구분하고, 조회 실패는 원인을 보존하여 즉시 중단해야 한다. 기동에 필요한 컨트롤러·Deployment의 부재 역시 성공이 아니라 복원 불가 오류로 처리한다. 오프라인 함수 모의 검증에서 `kubectl`이 오류 코드 1을 반환해도 컨트롤러 대기와 `scale_min` 모두 종료 코드 0을 반환함을 확인했다.

### Medium / Low
- [x] (`3917898`) **M1 (Medium) — RDS 중지 진행 중에 기동하면 시작 요청 없이 대기함.** `scripts/daily-start.sh:80` — 중지 스크립트는 RDS가 `stopped`가 될 때까지 기다리지 않으므로, 중지 직후 복원하거나 부분 실패를 복구할 때 `stopping`을 만날 수 있다. 이 상태에서는 시작 요청을 생략하고 노드그룹을 복원한 뒤 112행에서 `available`을 기다리지만, RDS가 `stopped`로 전환되어도 시작 요청을 다시 보내지 않는다. 결과적으로 서비스 복원이 실패하고 노드 비용만 발생한다. `stopping`이면 중지 완료를 기다린 후 시작하거나, 노드그룹 변경 전에 재시도 가능한 오류로 종료한다. 해당 전이 경로를 모의 테스트로 검증한다.
- [x] (`3917898`) **M2 (Medium) — 손상된 상태 파일을 정상적인 미저장 상태로 처리함.** `scripts/daily-start.sh:50` — JSON 파싱 오류, 읽기 오류 및 유효하지 않은 `desiredSize`로 조회가 실패하면 모두 환경변수/기본값으로 대체된다. 예를 들어 저장 파일이 손상된 경우 원래 용량을 알 수 없는데도 `2/2/4`로 변경하여 원래의 가용 용량을 잃을 수 있다. 이는 설계 §5.5의 손상된 상태 파일 검증 요구와 어긋난다. 파일 없음/노드그룹 항목 없음과 파일 손상/잘못된 값은 구분하고, 후자는 AWS 변경 전에 실패시킨다. 모의 `jq` 파싱 오류 코드 4를 주입했을 때 `target_size`가 `2 2 4`를 반환하는 것을 확인했다.
- [x] (`3917898`, design `82d3c8f`) **M3 (Medium) — maxSize만 다른 경우 저장된 설정을 복원하지 않음.** `scripts/daily-start.sh:95` — 현재 설정 조회와 일치 판단에 `maxSize`가 빠져 있다. 저장된 목표가 `2/2/4`이고 현재 설정이 `2/2/2`이면 `already 2/2`로 건너뛰어 자동 확장의 상한이 2에 남는다. 설계 §1.1의 세 가지 scalingConfig 값 복원 목표 및 `infra/eksctl/cluster.yaml`의 기본 상한 4와 달라진다. 현재 `maxSize`도 조회해 세 값을 모두 비교한다. 상세 설계 §3.3에도 같은 누락이 있으므로 구현과 함께 설계를 정정한다.
- [x] (`83672f5`, `aa34ebc`) **M4 (Medium) — 실제 상태 분기와 실패 전파를 검증하는 테스트가 없음.** `scripts/validate-manifests.sh:17` — 신규 검증은 고정된 가정값을 사용하는 dry-run의 종료 코드와 안내 문구만 확인하므로 H1~M3 같은 오류를 탐지하지 못한다. AWS/Kubernetes 접근 없이 명령 모의를 사용해 중지 재실행 시 저장값 보존, 저장값 복원, RDS `stopping` 전이, 조회 오류 전파, 손상 파일 거부, maxSize만 다른 경우를 검증하는 회귀 테스트를 추가한다. 실제 클라우드 실행은 필요하지 않다.

### 기존 아키텍처와의 불일치
- **필수 구성 요소 복원 보장:** `scripts/daily-start.sh:31` 및 `scripts/daily-start.sh:41`의 오류 무시는 `docs/architecture.md` §2의 핵심 컨트롤러·WAS가 실제로 준비되지 않아도 복원 성공을 허용한다. H1의 별도 아키텍처 영향이며 같은 수정으로 해결해야 한다.
- **관리형 노드그룹 용량:** `scripts/daily-start.sh:95`의 maxSize 비교 누락은 기존 관리형 노드그룹의 확장 상한을 복원하지 않을 수 있다(M3). 일일 중지를 위한 일시적 0 축소 자체는 기능 설계에 명시된 의도된 동작이다.
- 앱·컨테이너·기존 Kubernetes 매니페스트의 변경은 없으며, 그 밖의 구조적 불일치는 발견하지 못했다.

### 검증 및 공개 저장소 노출 점검
- Git Bash로 두 신규 스크립트의 `bash -n`, 각각의 `--dry-run`, `scripts/validate-manifests.sh` 실행 성공: `OK: 36 YAML files, 6 workloads checked`.
- `git diff --check master...HEAD` 통과. 신규 함수 정의만 메모리에 로드하고 명령을 모의하여 H1 및 M2의 오류 처리 재현. 테스트 파일이나 소스 파일은 수정하지 않았다.
- 변경된 코드·문서(`docs/daily/2026-10-23.md` 포함)에서 실제 계정 ID·ARN·엔드포인트·개인 URL 노출은 발견하지 못했다.
- AWS 및 실제 Kubernetes 명령은 실행하지 않았다. 위 정적/모의 검증만으로 실제 클러스터의 중지·기동 성공을 확인한 것은 아니다.

### 총평
중지·복원 순서와 오프라인 dry-run은 설계에 대체로 부합하지만, 조회 실패를 숨기는 High 항목 때문에 필수 복원 조건을 보장하지 못한다. H1을 수정하고 상태 전이·복원 설정에 대한 회귀 검증을 보강한 뒤 재리뷰가 필요하다.

머지 가능 여부: No
