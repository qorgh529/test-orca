## Review Round 1 — 2026-10-26 (대상 커밋: 8a198c3)

### Critical
- 지적 사항 없음.

### High
- [ ] `infra/aws/provision-aws-resources.sh:194` — **기존 아키텍처 불일치: 소스·백업·트레이스 버킷 격리 검증 누락.** `CODEBUILD_S3_BUCKET_NAME`을 `BACKUP_S3_BUCKET_NAME` 또는 `TEMPO_S3_BUCKET_NAME`과 같게 설정해도 기존 버킷을 그대로 재사용하고 전체 객체에 적용되는 1일 만료 정책으로 기존 Lifecycle을 덮어쓴다. Tempo 데이터는 조기 삭제되고, 버전 관리 백업 버킷에서도 하루가 지난 현재 객체에 삭제 마커가 생겨 정상 백업 조회·복구 흐름이 깨진다. 암호화 설정 역시 AES256으로 바뀐다(`:192`). architecture.md §7의 버킷별 보존·암호화·권한 분리 및 design.md §5.1의 전용 소스 버킷 요구에 맞게, AWS 변경 전 세 버킷 이름이 서로 다른지 검증하고 동일 이름이면 중단해야 한다.

### Medium / Low
- [ ] `scripts/build-and-push.sh:23` — **Medium: 문서에 안내한 단일 대상 환경변수 지정이 일반적인 .env 구성에서 무시된다.** 새 템플릿의 `.env.example:38`에 `BUILD_TARGET=`가 있으므로 이를 복사한 `.env`를 `lib.sh`가 로드하면 호출자가 지정한 `BUILD_TARGET=web`도 빈 값으로 덮어써지고 여기서 `all`이 된다. 결과적으로 WAS까지 빌드·푸시하거나 WAS의 기존 불변 태그 때문에 web 빌드가 중단된다. 호출 환경의 명시적 BUILD_TARGET을 .env 기본값보다 우선하도록 처리하고, 빈 BUILD_TARGET이 있는 .env에서 web/was 선택을 확인하는 오프라인 회귀 검증을 추가해야 한다. `BUILD_TARGET=web bash -c '. ./.env.example; ...'`로 로드 후 빈 값 및 유효 대상 all을 확인했다. 기존 IMAGE_TAG 우선순위 문제와 별개로 이번에 추가한 옵션의 문제다.
- [ ] `scripts/build-and-push.sh:71` — **Medium: 같은 태그를 사용하는 빌드끼리 소스 아카이브를 덮어쓴다.** 서로 다른 작업 트리에서 같은 IMAGE_TAG로 web과 was를 각각 실행하거나, 첫 빌드가 큐에서 기다리는 동안 재시도하면 두 실행 모두 `source/<tag>.zip`에 업로드한다. 첫 빌드가 소스를 다운로드하기 전에 두 번째 업로드가 완료되면 첫 실행도 두 번째 작업 트리로 빌드된다. ECR 불변 태그 사전 검사로는 이를 막지 못하며, 성공해도 요청한 소스와 이미지가 달라진다. 실행별 UUID 또는 콘텐츠 해시를 소스 키에 포함하고 start-build에 동일한 고유 키를 넘겨야 한다. 설계 §3.2의 예시 키에도 같은 경합이 있으므로 설계 보완이 필요하다.

### 검증
- `./scripts/validate-manifests.sh` 통과: daily stop/start 오프라인 테스트, YAML 43개 및 워크로드 6개 검사.
- 변경 파일 전체와 추가 일일 기록에서 계정 ID·ARN·엔드포인트·개인 URL의 실값 노출 지적 사항 없음.
- 기존 review.md가 없어 첫 라운드로 작성했다. 실제 AWS 명령 및 이미지 빌드는 실행하지 않았다.
- 아키텍처 문서의 CodeBuild 미반영은 설계 §7과 워크플로 ⑦에서 갱신하기로 했으므로 별도 결함으로 보지 않는다.

### 총평
원격 빌드 흐름과 기존 Dockerfile·amd64·불변 태그 규칙은 설계대로 유지된다. 버킷 설정 충돌 시 기존 데이터 보존 정책을 변경하는 High 항목을 수정한 후 재리뷰가 필요하다.

머지 가능 여부: No
