## Review Round 1 — 2026-10-26 (대상 커밋: 29605b5)

### Critical
지적 사항 없음.

### High
지적 사항 없음. 변경된 코드·문서(docs/daily 포함)에서 계정 ID·ARN·엔드포인트·개인 URL 실값 노출은 발견하지 못했다.

### Medium / Low
- [x] (c0bff3d) `app/src/main/java/org/springframework/samples/petclinic/repository/jpa/JpaVisitRepositoryImpl.java:74`, `app/src/main/java/org/springframework/samples/petclinic/repository/springdatajpa/SpringDataVisitRepository.java:44` — Medium: 최근 방문의 반환 건수만 제한되고 실제 엔티티 로딩량은 제한되지 않는다. 기존 `model/Pet.java:60`의 `visits`가 `FetchType.EAGER`이므로 fetch join으로 가져온 각 반려동물의 **전체 방문 이력**이 추가 조회된다. 두 프로필에서 최근 방문 2건 테스트를 SQL 출력으로 실행하면 상한 있는 본 쿼리 뒤에 `select ... from visits ... where pet_id=?`가 2회 실행되는 것을 확인했다. 메인 화면이 매 요청마다 이를 호출하므로 방문 이력이 누적되면 설계 §1.2·§2.1의 부하 제한 및 N+1 방지 의도가 깨진다. 대시보드 전용 DTO projection 또는 EAGER 컬렉션을 제외하는 fetch graph 등으로 필요한 필드만 조회하고, 새 영속성 컨텍스트에서 이력이 많은 반려동물을 조회해 SQL 수·로딩량이 상한에 맞는지 검증할 것을 제안한다. 페이지네이션 쿼리에 컬렉션 fetch join을 추가하면 메모리 페이지네이션 문제가 생길 수 있으므로 피한다.

### 기존 아키텍처와의 차이
- `app/src/main/java/org/springframework/samples/petclinic/web/WelcomeController.java:37`, `app/src/main/resources/spring/mvc-core-config.xml:35` — 정적 `/` 페이지를 서비스·저장소를 경유하는 동적 대시보드로 바꾸고 `/welcome` 별칭을 추가했다. 기능 설계에서 승인한 변경이며, 기존 Web→WAS→RDS 경로와 서비스 파사드·읽기 전용 트랜잭션 구조에서 벗어난 사항은 없다. 위 Medium은 기능 설계의 조회 부하 제한과 관련된 별도 지적이다.

### 검증
- `git diff master...HEAD` 전체 36개 파일을 검토했다. 비교 범위에 포함된 이전 rds-mysql-84 변경도 확인했으며, 해당 review.md·security.md에서 `[x]` 처리된 Connector/J 고정 버전 검사와 기존 파라미터 그룹 패밀리 검증은 실제 코드에 반영되어 있다. staff-dashboard의 기존 review.md는 없어 재확인할 이전 라운드는 없다.
- `app/./mvnw -o -Dtest='ClinicService*Tests,WelcomeControllerTests' test` — 44개 통과(JDBC·JPA·Spring Data JPA 각 14개, 컨트롤러 2개).
- 위 두 JPA 프로필의 `shouldFindRecentVisitsNewestFirstWithPetAndOwner`를 `-Djpa.showSql=true`로 재실행해 추가 SQL을 확인했다. 테스트 DB는 H2이며, 테스트 데이터만 출력했다.
- `bash scripts/validate-manifests.sh` — YAML 43개·워크로드 6개 및 일일 중지/기동·이미지 빌드 오프라인 회귀 테스트 통과.
- MockMvc 검증은 JSP를 실제 렌더링하지 않는다. 실제 Tomcat JSP 렌더링과 카나리 배포 검증은 수행하지 않았고, AWS 명령·push·머지는 실행하지 않았다.

### 총평
대시보드의 통계·최근 방문·검색·수의사 명단 연결은 설계와 일치하며 Critical·High 지적은 없다. Medium 조회 성능 보완이 남아 있으며 실제 JSP 렌더링은 배포 전 확인이 필요하다.

머지 가능 여부: Yes
