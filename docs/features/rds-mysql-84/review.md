## Review Round 1 — 2026-10-26 (대상 커밋: 84c9f1b)

### Critical
지적 사항 없음.

### High
지적 사항 없음. 변경된 코드·문서 및 일일 기록에서 계정 ID·ARN·엔드포인트·개인 URL 실값 노출은 발견하지 못했다.

### Medium / Low
- [x] `scripts/validate-manifests.sh:370` — Low: Connector/J 검사가 설계 §6 4단계의 고정 버전 `8.4.0` 대신 모든 `8.4.x`를 허용한다. 실제로 존재하지 않는 `8.4.999`도 정규식을 통과하므로 드라이버 버전 오입력을 검출하지 못한다. `8.4.0`을 정확히 비교하고 오류 메시지도 고정 버전에 맞출 것을 제안한다. 현재 pom.xml의 실제 버전은 설계와 일치한다. (`a645975`)

### 기존 아키텍처와의 차이
- `infra/aws/provision-aws-resources.sh:297`, `infra/aws/provision-aws-resources.sh:311`, `k8s/jobs/job-db-init.yaml:35`, `k8s/jobs/cronjob-db-backup.yaml:40` — 기존 architecture.md의 MySQL 8.0/클라이언트 8.0.39와 달리 엔진·클라이언트를 8.4.11, 파라미터 그룹을 mysql8.4로 변경했다. 기능 설계 §2.1·§4.1에서 승인한 변경이며, Multi-AZ·프라이빗 DB·TLS 강제·역할별 계정·백업 흐름의 추가 이탈은 발견하지 못했다. 워크플로 ⑦에서 architecture.md와 다이어그램의 버전 표기를 현행화해야 한다.

### 검증
- `git diff master...HEAD` 전체 8개 파일 및 기능 설계를 검토했다. 기존 review.md가 없어 이전 라운드 재확인 대상은 없다.
- `bash scripts/validate-manifests.sh` 통과: YAML 43개, 워크로드 6개, 일일 중지·기동 및 이미지 빌드 오프라인 회귀 테스트 통과.
- Maven 테스트는 재실행하지 않았다. 구현 기록의 78개 테스트 통과는 실제 MySQL 8.4 TLS 인증·SQL·백업 검증을 대체하지 않으며, 설계 §6 7~10단계의 실환경 검증은 아직 미완료다. AWS 명령은 실행하지 않았다.
- `git diff master...HEAD --check`에는 design.md:114의 후행 공백 및 design.md:322의 EOF 빈 줄 경고가 있다.

### 총평
로컬 구현은 설계와 일치하며 Critical·High 지적은 없다. Low 검증 보완은 남아 있고, 배포 전에는 설계에 남겨 둔 실환경 DB 초기화·애플리케이션 연결·백업 검증이 필요하다.

머지 가능 여부: Yes
