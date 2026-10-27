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

## Review Round 2 — 2026-10-27 (대상 커밋: ca90d5e)

### Critical
- 지적 사항 없음.

### High
- [ ] `docs/features/landing-page/design.md:593` — 롤백 명령은 이미지만 이전 버전으로 바꾸지만 Deployment의 startup/readiness probe는 `/was/`로 남는다. 이전 WAS는 ROOT 컨텍스트만 제공하므로 새 롤백 Pod가 준비 상태가 되지 못해 복구가 멈춘다. 이전 Deployment 전체를 복원하는 절차와 순서를 명시하고 실제 롤백을 검증한다.
- [ ] `scripts/deploy-all.sh:155` — stable과 canary web을 함께 적용한 뒤 stable과 canary WAS를 함께 적용하므로, 설계의 카나리 사전 검증 전에 stable이 이미 신규 버전으로 전환된다. 신규 버전의 오류가 카나리 검사에서 발견되어도 stable 사용자에게 노출되고, web 롤아웃 후 기존 WAS를 향하는 `/was/` 요청은 WAS 전환이 끝날 때까지 404가 된다. 트랙을 분리해 카나리 검증 후 stable을 전환하고 버전 혼재 구간의 호환성도 확보한다.
- [ ] `scripts/lib.sh:64` — 게이트는 직원 차단 규칙이 존재하는 규칙 중 최저 우선순위인지만 확인하고 Priority 0인지 확인하지 않는다. 예를 들어 우선순위 1인 규칙만 있을 때 검증에 통과하므로 이후 우선순위 0에 Allow 규칙이 추가되면 보호 경로가 우회될 수 있다. 명시적으로 `.Priority == 0`을 검사하고 회귀 사례를 추가한다.

### Medium / Low
- 지적 사항 없음.

### 기존 아키텍처와의 차이
- [ ] `docker/was/Dockerfile:32` — WAS 컨텍스트가 기존 아키텍처의 `webapps/ROOT`에서 `webapps/was`로 변경되고 web 루트가 정적 페이지로 바뀐다. 의도된 변경이므로 머지 전 아키텍처 문서의 WAS·요청 흐름과 WAF 규칙 설명을 실제 구현에 맞게 갱신한다.

### 총평
이전 라운드의 도메인 제거, web 우선 적용 및 WAF 변환 순서 검증은 확인했다. 롤백 복구와 카나리 격리, WAF 우선순위 게이트를 보완해야 한다.

머지 가능 여부: No
