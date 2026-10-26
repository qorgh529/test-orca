## Review Round 1 — 2026-10-26 (대상 커밋: 954bb51)

### Critical
지적 사항 없음.

### High
지적 사항 없음. 변경 코드·문서(docs/daily 포함)에서 계정 ID·ARN·엔드포인트·개인 URL 실값 노출은 발견하지 못했다.

### Medium / Low
구현 코드의 추가 지적 사항 없음. 설계 문서의 Medium 1건은 아래 아키텍처 불일치 항목에 기재한다.

### 기존 아키텍처와의 불일치
- [x] (b78905c) `docs/features/graceful-shutdown/design.md:162`, `docs/features/graceful-shutdown/design.md:176`, `docs/features/graceful-shutdown/design.md:179` — Medium: WAS 종료 시간 산정과 종료 순서 설명이 실제 런타임과 다르다. 설계는 HikariCP와 `PetClinicApplication.registerShutdownHook()`을 전제로 하지만, architecture.md는 외부 Tomcat WAR와 Tomcat JDBC Pool을 명시하고 실제 `app/src/main/resources/spring/datasource-config.xml:30`도 `org.apache.tomcat.jdbc.pool.DataSource`이다. 부트스트랩은 `app/src/main/java/org/springframework/samples/petclinic/PetclinicInitializer.java:39`의 `AbstractDispatcherServletInitializer`이며 해당 Application 클래스·명시적 훅 등록은 없다. 외부 Tomcat의 웹 컨텍스트 종료 및 실제 JDBC Pool 정리 경로를 기준으로 설명을 정정하고, 요청 처리·풀 정리·OTel 플러시에 대한 30초 잔여 유예의 충분성은 실제 종료 로그/진행 중 요청 시험으로 확인할 것을 제안한다. 이 문서 오류만으로 현재 매니페스트의 종료 실패가 입증된 것은 아니다.
- `k8s/web/deployment.yaml:35`, `k8s/web/deployment.yaml:114`, `k8s/was/deployment-stable.yaml:36`, `k8s/was/deployment-canary.yaml:36` — 구현은 기능 설계대로 web 35초·was 45초 유예와 6개 컨테이너의 15초 네이티브 preStop sleep을 추가했다. 기존 2-Tier 서비스 경로, 이미지, app 노드 티어, stable/canary 분리, PDB·HPA·KEDA 구성과 어긋나는 추가 변경은 발견하지 못했다.

### 검증
- `git diff master...HEAD` 전체 47개 파일의 변경을 검토했다. 이전 RDS·대시보드·AZ 분산 및 운영 스크립트 변경도 비교 범위에 포함된다. 기존 리뷰에서 `[x]` 처리한 Connector/J 고정 버전 검사, VisitSummary 생성자 투영, matchLabelKeys 리스트 타입 검사 및 축소 시 AZ 편중 설명 수정은 실제 반영되어 있다. graceful-shutdown의 이전 review.md는 없어 첫 라운드로 작성했다.
- `bash scripts/validate-manifests.sh` 통과: YAML 43개·워크로드 6개, 일일 중지/기동 및 이미지 빌드 오프라인 회귀 테스트 통과.
- 실제 §11 검사를 YAML 메모리 사본으로 실행했다. baseline 통과, preStop 누락·grace period 누락·문자열 sleep·grace period 이상 sleep의 각 음성 시험에서 오류 검출을 확인했다. 소스·매니페스트 파일은 수정하지 않았다.
- `app/./mvnw -o -Dtest='ClinicService*Tests,WelcomeControllerTests' test` 통과: 44개(JDBC·JPA·Spring Data JPA 각 14개, 컨트롤러 2개), 실패·오류 0개.
- 서버 dry-run, 실클러스터 적용 및 설계 §6 Step 7~8의 반복 롤아웃/700건 이상 트래픽 검증은 수행하지 않았다. 로컬 검증만으로 무중단 성공률을 확정할 수 없으며 이 실환경 검증은 남아 있다. AWS 명령·push·머지는 실행하지 않았다.

### 총평
종료 매니페스트와 정적 검증은 설계와 일치하고 Critical·High 지적은 없다. Medium 설계 설명 보완과 실환경 무중단 검증이 남아 있다.

머지 가능 여부: Yes
