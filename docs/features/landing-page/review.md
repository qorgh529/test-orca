## Review Round 1 — 2026-10-27 (대상 커밋: 17a2618)

### Critical
- 지적 사항 없음.

### High
- [x] (4237983) `docs/features/landing-page/design.md:12` — 실제 서비스 도메인이 공개 저장소에 기록되어 있다. `${DOMAIN_NAME}` 같은 플레이스홀더로 바꾸고 변경된 문서 전반에서 실값 노출을 제거한다.
- [x] (4237983) `scripts/deploy-all.sh:154` — 기존 환경 재배포 시 WAS Deployment를 web보다 먼저 적용하고 두 롤아웃을 동시에 진행한다. 새 WAS가 먼저 준비되면 기존 web의 `/` 요청이 `/was`만 존재하는 Tomcat으로 전달되어 404가 발생한다. 사용자 승인된 순서대로 stable web 롤아웃 완료를 기다린 뒤 stable WAS를 적용하고, 이 순서를 검증하는 테스트를 추가한다.

### Medium / Low
- [x] (4237983) `scripts/lib.sh:62` — 배포 전 WAF 게이트는 변환의 종류만 확인하여 `LOWERCASE` 누락이나 변환 우선순위가 뒤바뀐 규칙도 통과시킨다. 설계의 세 변환과 순서를 정확히 검증하고 해당 실패 사례를 오프라인 테스트에 추가한다.

### 기존 아키텍처와의 차이
- [-] (⑦ 단계에서 Antigravity가 architecture.md 를 갱신, 구현 단계 범위 밖) `docker/was/Dockerfile:32` — WAS 컨텍스트가 기존 아키텍처의 `webapps/ROOT` 및 `/` 대시보드에서 `webapps/was`와 `/was/`로 변경되며, web 루트도 정적 페이지가 된다. 설계에서 의도한 변경이므로 머지 전 아키텍처 문서의 WAS·요청 흐름과 WAF 규칙 설명을 실제 구현에 맞게 갱신한다.

### 총평
공개 도메인 실값과 배포 순서 문제를 해결해야 한다. WAF 게이트 검증과 아키텍처 문서도 보완이 필요하다.

머지 가능 여부: No
