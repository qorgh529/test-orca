## Review Round 1 — 2026-10-26 (대상 커밋: 8a198c3)

### Critical
- 지적 사항 없음.

### High
- [x] `infra/aws/provision-aws-resources.sh:194` — **기존 아키텍처 불일치: 소스·백업·트레이스 버킷 격리 검증 누락.** `CODEBUILD_S3_BUCKET_NAME`을 `BACKUP_S3_BUCKET_NAME` 또는 `TEMPO_S3_BUCKET_NAME`과 같게 설정해도 기존 버킷을 그대로 재사용하고 전체 객체에 적용되는 1일 만료 정책으로 기존 Lifecycle을 덮어쓴다. Tempo 데이터는 조기 삭제되고, 버전 관리 백업 버킷에서도 하루가 지난 현재 객체에 삭제 마커가 생겨 정상 백업 조회·복구 흐름이 깨진다. 암호화 설정 역시 AES256으로 바뀐다(`:192`). architecture.md §7의 버킷별 보존·암호화·권한 분리 및 design.md §5.1의 전용 소스 버킷 요구에 맞게, AWS 변경 전 세 버킷 이름이 서로 다른지 검증하고 동일 이름이면 중단해야 한다. (`68cec69`)

### Medium / Low
- [x] `scripts/build-and-push.sh:23` — **Medium: 문서에 안내한 단일 대상 환경변수 지정이 일반적인 .env 구성에서 무시된다.** 새 템플릿의 `.env.example:38`에 `BUILD_TARGET=`가 있으므로 이를 복사한 `.env`를 `lib.sh`가 로드하면 호출자가 지정한 `BUILD_TARGET=web`도 빈 값으로 덮어써지고 여기서 `all`이 된다. 결과적으로 WAS까지 빌드·푸시하거나 WAS의 기존 불변 태그 때문에 web 빌드가 중단된다. 호출 환경의 명시적 BUILD_TARGET을 .env 기본값보다 우선하도록 처리하고, 빈 BUILD_TARGET이 있는 .env에서 web/was 선택을 확인하는 오프라인 회귀 검증을 추가해야 한다. `BUILD_TARGET=web bash -c '. ./.env.example; ...'`로 로드 후 빈 값 및 유효 대상 all을 확인했다. 기존 IMAGE_TAG 우선순위 문제와 별개로 이번에 추가한 옵션의 문제다. (`68cec69`)
- [x] `scripts/build-and-push.sh:71` — **Medium: 같은 태그를 사용하는 빌드끼리 소스 아카이브를 덮어쓴다.** 서로 다른 작업 트리에서 같은 IMAGE_TAG로 web과 was를 각각 실행하거나, 첫 빌드가 큐에서 기다리는 동안 재시도하면 두 실행 모두 `source/<tag>.zip`에 업로드한다. 첫 빌드가 소스를 다운로드하기 전에 두 번째 업로드가 완료되면 첫 실행도 두 번째 작업 트리로 빌드된다. ECR 불변 태그 사전 검사로는 이를 막지 못하며, 성공해도 요청한 소스와 이미지가 달라진다. 실행별 UUID 또는 콘텐츠 해시를 소스 키에 포함하고 start-build에 동일한 고유 키를 넘겨야 한다. 설계 §3.2의 예시 키에도 같은 경합이 있으므로 설계 보완이 필요하다. (`68cec69`)

### 검증
- `./scripts/validate-manifests.sh` 통과: daily stop/start 오프라인 테스트, YAML 43개 및 워크로드 6개 검사.
- 변경 파일 전체와 추가 일일 기록에서 계정 ID·ARN·엔드포인트·개인 URL의 실값 노출 지적 사항 없음.
- 기존 review.md가 없어 첫 라운드로 작성했다. 실제 AWS 명령 및 이미지 빌드는 실행하지 않았다.
- 아키텍처 문서의 CodeBuild 미반영은 설계 §7과 워크플로 ⑦에서 갱신하기로 했으므로 별도 결함으로 보지 않는다.

### 총평
원격 빌드 흐름과 기존 Dockerfile·amd64·불변 태그 규칙은 설계대로 유지된다. 버킷 설정 충돌 시 기존 데이터 보존 정책을 변경하는 High 항목을 수정한 후 재리뷰가 필요하다.

머지 가능 여부: No

## Review Round 2 — 2026-10-26 (대상 커밋: a7d89e5)

### Critical
- 지적 사항 없음.

### High
- 지적 사항 없음.

### Medium / Low
- [ ] `scripts/validate-manifests.sh:346` — **Medium: buildspec 회귀 검사 두 개가 정상 실행에서 건너뛰어진다.** `post_build.on-failure == ABORT` 검사와 `pre_build` 태그 정규식 검사가 IAM 정책 파싱의 `except` 블록 안에 들여쓰기되어 있다. 정상적인 `codebuild-policy.json`에서는 두 검사가 실행되지 않으므로, buildspec에서 해당 보호 장치를 제거해도 검증이 통과한다. 두 검사를 buildspec을 처리하는 `else` 블록으로 옮기고 각각의 보호 장치를 제거했을 때 실패하는 음성 검증을 추가해야 한다. 실제 IAM 정책을 사용하는 해당 검사 블록에 `phases={'post_build': {}}`, `cmds=lambda p: ''`를 전달해 실행했으며 오류 목록이 빈 배열인 것을 확인했다. 현재 buildspec 자체에는 두 보호 장치가 있어 현재 빌드 동작을 막는 문제는 아니다.

### 기존 아키텍처와의 일치
- 신규 불일치 지적 사항 없음. 기존 Dockerfile, WAR 패키징, `linux/amd64`, ECR 불변 태그, 백업·Tempo 권한 및 버킷 분리 구조를 유지한다.
- R1 High의 버킷 충돌 문제는 `infra/aws/provision-aws-resources.sh:63`에서 모든 AWS 변경 전에 차단되도록 수정됐고, 빌드 진입점에도 검사가 추가됐다.
- CodeBuild의 architecture.md·다이어그램 반영은 설계 §7에 따라 머지 직전 ⑦ 단계의 후속 작업이다.

### 검증
- `git diff master...HEAD` 전체를 설계 및 아키텍처와 대조했다. 변경 코드·문서와 `docs/daily/2026-10-26.md`에서 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 지적 사항 없음.
- R1의 `[x]` 항목 3개를 실제 코드로 재확인했다. 명령줄 IMAGE_TAG·BUILD_TARGET 보존 및 실행별 UUID 소스 키가 반영됐으며, 오프라인 회귀 테스트도 통과했다.
- `./scripts/validate-manifests.sh` 통과: daily stop/start 및 CodeBuild 오프라인 테스트, YAML 43개·워크로드 6개 검사.
- AWS 명령 및 실제 이미지 빌드는 실행하지 않았다. 소스 코드 수정 없이 본 리뷰 파일만 추가 작성했다.

### 총평
이전 라운드의 차단 사유는 해결됐고, 현재 구현의 Critical·High 결함은 발견하지 못했다. 검증 누락 Medium 1건은 후속 보완을 권고하며, 실제 AWS 검증과 ⑦ 문서 현행화는 별도로 남아 있다.

머지 가능 여부: Yes
