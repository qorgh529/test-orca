# 보안 및 인프라 점검 결과 (`docs/features/staff-dashboard/security.md`)

## Security Round 1 — 2026-10-26 (대상 커밋: 9b98bc5)

점검 범위: `git diff master...HEAD` 전체, `docs/architecture.md` 보안 구조(§7), `docs/features/staff-dashboard/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env`는 `.gitignore`로 제외되어 미추적 상태 유지, 소스 코드 및 JSP/설정 파일 내 비밀번호나 토큰 하드코딩 없음).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md`, `README.md`, `design.md`, `review.md` 모두 확인 결과 12자리 AWS 계정 ID, 실존 ARN, 프라이빗/퍼블릭 엔드포인트 URL, 개인 URL 노출 없음).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 추가된 `countOwners`, `countPets`, `countVisits`, `findRecentVisits` 조회는 모두 `ClinicServiceImpl`에서 `@Transactional(readOnly = true)`로 격리되어 있으며, DML 4종 권한만 가진 `petclinic_app` 계정 범위 내에서 동작함. 신규 쓰기 권한이나 상위 DB/AWS 권한 요구 없음).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (신규 네트워크 포트 개방 없음, Web→WAS 및 WAS→RDS 통신 경로와 기존 NetworkPolicy 격리 구조 준수).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF, XSS)**: 이상 없음 (`WelcomeController`의 `GET /` 및 `/welcome`은 외부 파라미터 직접 수신 없이 고정 상한(`limit=5`)으로 조회 수행. JDBC는 NamedParameter 바인딩, JPA는 setMaxResults/PageRequest로 SQL Injection 원천 차단. `welcome.jsp` 렌더링 시 모든 동적 속성은 JSTL `<c:out value="..."/>`로 출력하고 링크는 `<spring:url ... htmlEscape="true"/>`를 적용하여 XSS 차단).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (신규 외부 의존성 추가 없음. 기존 MySQL 드라이버 `8.4.0` 고정 유지).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 이상 없음 (컨테이너 매니페스트 변경 없음. 기존 비루트 UID 10001, `readOnlyRootFilesystem: true`, capabilities ALL drop 샌드박스 정책 유지).
- **design.md 보안 요구사항 및 architecture.md 보안 구조 준수 여부**: `docs/features/staff-dashboard/design.md` §5 보안 요구사항(최소 권한, SQL Injection 방어, 상한 강제, XSS 방지) 및 `docs/architecture.md` §7 보안 구조 준수 확인.

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
- [ ] `app/src/main/java/org/springframework/samples/petclinic/repository/jpa/JpaVisitRepositoryImpl.java:74`, `app/src/main/java/org/springframework/samples/petclinic/repository/springdatajpa/SpringDataVisitRepository.java:44` — **JPA 프로필에서 Pet 엔티티의 EAGER visits 컬렉션 로딩으로 인한 잠재적 DB 부하 및 커넥션 점유 (CWE-400 / 리소스 고갈 방어).** 메인 화면(`/`)은 시스템에서 가장 빈번하게 호출되는 엔드포인트다. `findRecentVisits(limit)`는 반환 건수를 5건으로 제한(`limit = 5`)하고 있으나, 기존 `Pet.java:60`의 `visits` 컬렉션이 `FetchType.EAGER`로 매핑되어 있어 조회된 최대 5마리의 반려동물에 대해 각 반려동물의 전체 방문 이력을 가져오는 추가 N+1 SELECT 쿼리가 발생한다. 방문 이력이 대규모로 누적된 실환경에서 동시 요청이 급증할 경우, Tomcat DB 커넥션 풀(최대 10) 고갈 및 WAS 힙 메모리 급증 위험이 존재한다. 운영 환경(기본 `jpa` 프로필)의 가용성을 위해 대시보드 전용 DTO 프로젝션을 도입하거나 EntityGraph/FetchGraph를 적용하여 필요한 필드만 단일 쿼리로 조회하도록 개선을 권고한다.

### Low
- [ ] `app/src/main/java/org/springframework/samples/petclinic/web/WelcomeController.java:42` — **빈번히 호출되는 메인 대시보드의 정적 코드성 메타데이터(`findPetTypes`) 매 요청 DB 조회.** `findVets()`는 `@Cacheable(value = "vets")`가 적용되어 캐시를 활용하나, `findPetTypes()`는 매 요청마다 DB 조회를 수행한다. 동물 종류(PetType)는 변경 빈도가 극히 낮은 마스터 데이터이므로 캐시를 적용하거나 동물 종류 수(`countPetTypes`) 전용 카운트 쿼리를 분리하면 불필요한 엔티티 로딩 및 DB 라운드트립을 줄여 메인 화면의 응답 안정성을 높일 수 있다.

### 총평
스태프 운영 대시보드는 시크릿 노출, 권한 과다 부여, SQL 인젝션, XSS 등의 주요 보안 결함 없이 설계 보안 요구사항을 충실히 준수하여 구현되었다. 모든 JSP 출력에 JSTL `<c:out>` 및 URL HTML 이스케이프가 철저히 적용되어 있고, 컨트롤러와 서비스 계층의 읽기 전용 트랜잭션 분리와 조회 건수 상한(`limit=5`)이 정상 작동한다. JPA 프로필의 EAGER 컬렉션 N+1 로딩(Medium)과 PetType 캐싱 부재(Low)는 즉각적인 익스플로잇이나 보안 취약점이 아닌 대용량 트래픽 환경에서의 리소스/성능 방어 권고사항이므로, 현재 기능의 머지 및 카나리 배포를 차단할 수준은 아니다.

배포 가능 여부: Yes
