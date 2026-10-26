# 보안 및 인프라 점검 결과 (`docs/features/codebuild-image-build/security.md`)

## Security Round 1 — 2026-10-26 (대상 커밋: b2699e8)

점검 범위: `git diff master...HEAD` 전체(`.env.example`, `README.md`, `buildspec.yml`, `docs/daily/2026-10-26.md`, `docs/features/codebuild-image-build/design.md`, `docs/features/codebuild-image-build/review.md`, `infra/aws/iam-policies/codebuild-policy.json`, `infra/aws/iam-policies/codebuild-trust.json`, `infra/aws/provision-aws-resources.sh`, `scripts/build-and-push.sh`, `scripts/lib.sh`, `scripts/validate-manifests.sh`), `docs/architecture.md` 보안 구조(§7), `docs/features/codebuild-image-build/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env`는 `.gitignore`로 보호되어 미추적 상태이며, `.env.example` 및 `buildspec.yml`에 민감 정보 없음. 소스 zip 패키징 시 `.env*` 및 `*.secret` 배제 로직 확인).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md`, `docs/features/codebuild-image-build/design.md`, `docs/features/codebuild-image-build/review.md`, `README.md` 모두 `<DOMAIN>`, `<IAM_USER>`, `<USER_ARN>`, `${AWS_ACCOUNT_ID}` 등의 플레이스홀더 사용 확인).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 양호 (`infra/aws/iam-policies/codebuild-policy.json`은 `petclinic-web`, `petclinic-was` 2개 ECR 리포지토리 푸시/풀, `${CODEBUILD_S3_BUCKET_NAME}` 소스 읽기, 전용 로그 그룹 쓰기로 엄격히 제한됨. `codebuild-trust.json`에 `aws:SourceAccount` 조건 적용으로 혼동된 대리인(Confused Deputy) 방지). 단, 버킷 이름 충돌 시 권한 월경(백업 읽기) 위험은 아래 High 항목 참조.
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (`CODEBUILD_S3_BUCKET_NAME` 생성 시 퍼블릭 액세스 차단 4종 모두 활성화. CodeBuild는 인바운드 포트를 열지 않는 아웃바운드 빌드 환경으로 동작).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (`buildspec.yml` 및 `provision-aws-resources.sh`에서 `amazonlinux2-x86_64-standard:5.0` 환경 이미지 명시적 태그 사용, Dockerfile 내 `maven:3.9.9-eclipse-temurin-21`, `nginx:1.27.2-alpine`, `tomcat:11.0.2-jre21-temurin-noble` 고정 및 JMX Exporter JAR SHA256 체크섬 고정 검증 유지).
- **입력 검증 / 동시성 경합 / 인프라 격리**: 아래 High 1건, Medium 3건, Low 2건 확인.

### Critical
지적 사항 없음.

### High
- [x] `infra/aws/provision-aws-resources.sh:176` — **소스·백업·트레이스 S3 버킷 격리 검증 누락 및 수명주기(Lifecycle)·암호화 덮어쓰기 위험.** `provision-aws-resources.sh`의 `pre_cluster()`에서는 `TEMPO_S3_BUCKET_NAME != BACKUP_S3_BUCKET_NAME`만 검증하고 신규 추가된 `CODEBUILD_S3_BUCKET_NAME`에 대해서는 기존 버킷과의 동일 여부를 검증하지 않는다. 만약 `CODEBUILD_S3_BUCKET_NAME`이 `BACKUP_S3_BUCKET_NAME` 또는 `TEMPO_S3_BUCKET_NAME`과 동일하게 설정되면: (1) `put-bucket-lifecycle-configuration`이 버킷 전체 대상 1일 만료(`Expiration: Days: 1`) 정책으로 덮어써서 DB 백업이 1일 후 삭제되거나(삭제 마커 생성), Tempo 트레이스 블록이 1일 만에 강제 삭제된다. (2) `put-bucket-encryption`이 기존 SSE-KMS 설정을 SSE-S3(`AES256`)로 다운그레이드 덮어쓴다 (`docs/architecture.md` §7.1 "Tempo → S3 구간도 HTTPS와 SSE-KMS 암호화를 강제한다" 위반). (3) CodeBuild 서비스 역할(`codebuild-policy.json`)에 `arn:aws:s3:::${CODEBUILD_S3_BUCKET_NAME}/*`에 대한 `s3:GetObject` 권한이 부여되므로, 소스 버킷이 백업 버킷과 일치할 경우 빌드 러너가 DB 백업 덤프 전체를 조회할 수 있는 심각한 최소 권한/데이터 격리 위반이 발생한다. / 해결책: `infra/aws/provision-aws-resources.sh:61` 및 `codebuild()` 함수 초입(그리고 `scripts/build-and-push.sh:41`)에서 `CODEBUILD_S3_BUCKET_NAME`이 `BACKUP_S3_BUCKET_NAME` 및 `TEMPO_S3_BUCKET_NAME`과 상이한지(`[ "$CODEBUILD_S3_BUCKET_NAME" != "$BACKUP_S3_BUCKET_NAME" ] && [ "$CODEBUILD_S3_BUCKET_NAME" != "$TEMPO_S3_BUCKET_NAME" ]`) 명시적으로 검증하고 중단(`exit 1`)하도록 추가할 것. 또한 `scripts/validate-manifests.sh`에도 버킷 격리 검증 로직을 포함할 것. (`68cec69`)

### Medium
- [x] `scripts/build-and-push.sh:71` — **고정된 S3 소스 아카이브 키(`source/${IMAGE_TAG}.zip`) 사용으로 인한 경합(Race Condition) 및 빌드 소스 변조(TOCTOU) 위험.** `scripts/build-and-push.sh:71`에서 소스 아카이브의 S3 객체 키를 `key="source/${IMAGE_TAG}.zip"`으로 고정하고 있다. 동일한 `IMAGE_TAG`로 서로 다른 작업 트리에서 빌드를 실행하거나, `BUILD_TARGET=web`과 `BUILD_TARGET=was`를 순차/병렬 실행할 때 첫 번째 빌드가 CodeBuild의 `DOWNLOAD_SOURCE` 단계에 도달하기 전 두 번째 실행이 동일 키를 덮어쓰면, 첫 번째 빌드가 두 번째 작업 트리의 코드를 내려받아 빌드·푸시하게 되는 동시성 경합 및 빌드 무결성 훼손이 발생한다. ECR 불변 태그 사전 검사만으로는 S3 소스 업로드 시점의 동시성 경합을 방지하지 못한다. / 해결책: 소스 아카이브 키에 빌드 실행별 고유 식별자(UUID 또는 타임스탬프+PID/랜덤 해시: e.g. `source/${IMAGE_TAG}-$(date +%s)-$$.zip` 또는 `uuidgen`)를 포함하고, `aws codebuild start-build --source-location-override`에 해당 고유 키를 전달하도록 개선할 것. (`68cec69`)
- [x] `scripts/build-and-push.sh:22`, `buildspec.yml:14-16` — **`IMAGE_TAG` 입력값 형식(정규식) 검증 누락으로 인한 인젝션 및 경로 조작 위험.** `scripts/build-and-push.sh:22` 및 `buildspec.yml:15`는 `[ "$IMAGE_TAG" != "latest" ]`만 검사하고, 태그 문자열에 대한 정규식 형식 검증이 누락되어 있다. 만약 `IMAGE_TAG`에 공백, 세미콜론, 역따옴표, 셸 메타문자나 경로 조작 문자(`../`)가 포함될 경우 S3 업로드 경로(`source/${IMAGE_TAG}.zip`) 조작이나 CodeBuild 환경변수 오버라이드 및 빌드 셸 명령어(`docker build ... -t "...:${IMAGE_TAG}"`) 파싱 시 예기치 않은 오류 또는 인젝션 위험이 있다. / 해결책: Docker/ECR 표준 태그 규격에 맞춰 `[[ "$IMAGE_TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]` 형식 검증을 `scripts/build-and-push.sh` 및 `buildspec.yml`의 `pre_build` 단계에 추가하여 규격에 맞지 않는 태그 입력 시 즉시 `exit 1`로 차단할 것. (`68cec69`)
- [x] `scripts/build-and-push.sh:23`, `.env.example:38`, `scripts/lib.sh:3` — **`.env` 로드로 인한 `BUILD_TARGET` 환경변수 덮어쓰기 및 의도치 않은 전체 이미지 빌드/푸시.** `.env.example:38`에 `BUILD_TARGET=`가 기본 템플릿으로 추가되었으나, `scripts/build-and-push.sh`는 `lib.sh`를 소싱하며 `lib.sh:3`에서 `.env`를 `set -a; . "$ROOT/.env"; set +a`로 무조건 읽는다. 이로 인해 사용자가 `BUILD_TARGET=web ./scripts/build-and-push.sh`로 특정 단일 타깃만 빌드하려 해도, `.env`의 빈 `BUILD_TARGET=`에 의해 값이 `""`로 덮어써진 후 `scripts/build-and-push.sh:23`의 `${BUILD_TARGET:-all}`에 의해 `all`로 강제 변경된다. 결과적으로 WAS 이미지까지 의도치 않게 빌드·푸시되거나, WAS의 기존 불변 태그 충돌로 전체 배포 파이프라인이 중단되는 운영 안전성 결함이 발생한다. / 해결책: 호출 시점에 이미 설정된 환경변수(`BUILD_TARGET` 및 `IMAGE_TAG`)가 `.env`의 빈 값으로 덮어써지지 않도록 `lib.sh` 또는 `scripts/build-and-push.sh`에서 호출자의 인자를 보존하도록 처리하거나, `.env.example`에서 단일 실행용 인자인 `BUILD_TARGET=`를 주석 처리할 것. (`68cec69`)

### Low
- [x] `buildspec.yml:34-42` — **`post_build` 단계 실패 시 에러 전파 및 fail-fast 보장 미흡.** `buildspec.yml`의 `post_build` 단계에는 `on-failure: ABORT`가 지정되어 있지 않고, `docker push`가 두 블록(`was`, `web`)으로 나뉘어 있다. 만약 `was` 푸시가 실패하더라도 `web` 푸시 블록 및 마지막 echo 명령(`== Build and push completed`)까지 계속 실행될 수 있어, 부분 배포 불일치(was 실패, web 성공) 상태가 유발될 수 있다. / 해결책: `buildspec.yml`의 `post_build`에도 `on-failure: ABORT`를 추가하거나 스크립트 블록에 `set -euo pipefail`을 적용하여 단일 푸시 실패 시 즉시 중단되도록 보장할 것. (`68cec69`)
- [x] `scripts/build-and-push.sh:58-70` — **아카이빙 시 민감 키 파일(`*.pem`, `*.key`, `id_*`) 제외 보강 권고.** `scripts/build-and-push.sh`의 Python zip 패키징 로직은 `base.startswith(".env")` 및 `base.endswith(".secret")`만 필터링한다. `.gitignore`가 1차 방어선 역할을 하지만, 만약 개발자가 임시로 생성한 개인키(`*.pem`, `*.key`, `id_rsa` 등)나 토큰 파일이 부주의로 untracked 상태로 존재할 경우 소스 zip에 포함되어 S3 소스 버킷으로 업로드될 위험이 있다. / 해결책: 패키징 필터에 민감 파일 확장자(`*.pem`, `*.key`, `id_*`, `*.pfx`, `*.p12`) 패턴 제외를 방어적 심층 방어(defense-in-depth) 차원에서 추가할 것. (`68cec69`)

배포 가능 여부: No

## Security Round 2 — 2026-10-26 (대상 커밋: 92354ba)

점검 범위: `git diff master...HEAD` 전체(`.env.example`, `README.md`, `buildspec.yml`, `docs/daily/2026-10-26.md`, `docs/features/codebuild-image-build/design.md`, `docs/features/codebuild-image-build/review.md`, `docs/features/codebuild-image-build/security.md`, `infra/aws/iam-policies/codebuild-policy.json`, `infra/aws/iam-policies/codebuild-trust.json`, `infra/aws/provision-aws-resources.sh`, `scripts/build-and-push.sh`, `scripts/lib.sh`, `scripts/validate-manifests.sh`, `tests/scripts/build-and-push.test.sh`), `docs/architecture.md` 보안 구조(§7), `docs/features/codebuild-image-build/design.md` 보안 요구사항(§5) 준수 여부 및 Round 1 조치 결과(`68cec69`) 검증.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 미추적 상태 유지, 소스 zip 패키징 시 `.env*` 및 `id_*`, `*.pem`, `*.key`, `*.pfx`, `*.p12`, `*.secret` 등 민감 키·인증서 파일 일체 배제 로직 적용 확인).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md` 포함 전 파일에서 `<DOMAIN>`, `<IAM_USER>`, `<USER_ARN>`, `${AWS_ACCOUNT_ID}` 플레이스홀더 사용 준수).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (`codebuild-policy.json`은 `petclinic-web`, `petclinic-was` 2개 ECR 대상 푸시/풀, `${CODEBUILD_S3_BUCKET_NAME}` 소스 읽기, 전용 로그 그룹 쓰기로 엄격히 제한됨. `codebuild-trust.json`의 `aws:SourceAccount` 조건 유지).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (`CODEBUILD_S3_BUCKET_NAME` 퍼블릭 액세스 차단 4종 활성화, SSE-S3 암호화 및 1일 수명주기 만료 정책 적용).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (`amazonlinux2-x86_64-standard:5.0` 환경 이미지 명시적 태그 사용, Dockerfile 베이스 이미지 및 JMX Exporter JAR 체크섬 고정 유지).
- **입력 검증 및 동시성 격리**: 양호 (`IMAGE_TAG` Docker 태그 정규식 검증이 `scripts/build-and-push.sh` 및 `buildspec.yml`에 일관되게 적용됨. `key="source/${IMAGE_TAG}-<UTC>-<UUID>.zip"` 고유 키 생성으로 S3 소스 덮어쓰기 경합 방지. 호출자의 명령줄 `IMAGE_TAG`/`BUILD_TARGET` 보존 처리 완료).
- **Dockerfile/IaC 보안**: 이상 없음 (컨테이너 `USER 10001` 비루트 실행, `latest` 태그 차단, S3 암호화 유지).
- **인프라 격리 (R1 High 해결 확인)**: `infra/aws/provision-aws-resources.sh:63` 및 `scripts/build-and-push.sh:48`에서 `CODEBUILD_S3_BUCKET_NAME`이 `BACKUP_S3_BUCKET_NAME` 및 `TEMPO_S3_BUCKET_NAME`과 상이한지 사전 검증하여 기존 백업 수명주기/암호화 정책 파괴 위험 완벽 차단.

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
- [x] `scripts/validate-manifests.sh:346-349` — **CI 보안 회귀 검증 스크립트 들여쓰기 오류로 인한 buildspec 보안 규칙(ABORT, 태그 정규식) 검사 누락.** `scripts/validate-manifests.sh:346-349`에서 `buildspec.yml`의 `post_build.on-failure == ABORT` 설정 여부 및 `pre_build` 단계의 `IMAGE_TAG` 정규식 검사 로직이 `codebuild-policy.json` 파싱의 `except (OSError, ValueError, KeyError) as e:` 블록 내부로 들여쓰기되어 있다. 이로 인해 정책 파일이 정상적인 JSON인 일반 실행 환경에서는 두 가지 검사가 전혀 실행되지 않고 통과(silent bypass)된다. 향후 `buildspec.yml`에서 fail-fast나 태그 검증 로직이 누락되더라도 CI에서 감지하지 못하므로, 해당 검사 구문을 `except` 블록 밖(`try-except` 이후 또는 정상 검사 흐름)으로 이동시켜 상시 검증되도록 수정해야 한다. (`b58b01d`)

### Low
지적 사항 없음.

### 총평
Round 1의 High 1건, Medium 3건, Low 2건 지적 사항이 모두 충실히 보완되어 인프라 파괴, 동시성 소스 변조, 시크릿 누출 위험이 차단되었다. 새로 발견된 CI 검증 스크립트 들여쓰기 누락 1건(Medium)은 런타임 배포를 가로막는 보안 결함은 아니므로 후속 정리 대상으로 권고한다.

배포 가능 여부: Yes
