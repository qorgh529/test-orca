## Review Round 1 — 2026-10-26 (대상 커밋: 418081c)

### Critical
지적 사항 없음.

### High
- [x] (b709524) `scripts/deploy-all.sh:145`, `infra/aws/provision-aws-resources.sh:148`, `infra/aws/provision-aws-resources.sh:377` — 기본 배포 경로가 IP 제한을 보장하지 않는다. README의 pre-cluster → cluster → post-cluster → deploy-all 순서를 따르면 WebACL은 DefaultAction Allow와 관리형 규칙만 가진 채 생성되고, deploy-all은 `/grafana` HTTPRoute까지 공개한다. 새 `grafana-waf` 하위 명령은 이 흐름에서 호출되지 않으며 배포 전 해당 규칙·IPSet 검증도 없다. 따라서 빈 `GRAFANA_ALLOWED_CIDRS`가 모든 외부 접근을 막는다는 설계 §1.2·§5.2와 달리 정상 로그인 요청은 모든 IP에서 Grafana에 도달한다. 별도 명령 방식은 유지할 수 있지만, 공개 라우트 적용 전에 대상 WebACL의 차단 규칙·IPSet 연결을 검증하여 누락 시 배포를 중단하고 README의 필수 실행 순서에도 명시해야 한다. AWS 호출을 모킹한 오프라인 시험으로 규칙 미적용 시 라우트가 공개되지 않는지 확인할 것을 제안한다.

변경 코드·문서(docs/daily 포함)에서 계정 ID·ARN·엔드포인트·개인 URL 실값 노출은 발견하지 못했다.

### Medium / Low
- [x] (b709524) `scripts/validate-manifests.sh:442` — Low: Grafana NetworkPolicy 검증은 명시된 포트만 순회하므로 `ingress: [{}]`처럼 모든 출처·포트를 허용하는 정책도 통과한다. 실제 정책의 메모리 사본으로 이 조건을 실행해 오류가 검출되지 않음을 확인했다. podSelector, policyTypes, 두 허용 출처(namespaceSelector와 podSelector의 결합 포함), 각 ports의 존재와 TCP/3000을 구조적으로 검사하고 전체 허용·출처 제거·포트 제거에 대한 음성 시험을 추가할 것을 제안한다. 현재 매니페스트 자체의 선택자와 포트는 설계 의도에 부합한다.

### 기존 아키텍처와의 불일치
- [x] (02c1e78) `k8s/monitoring/kube-prometheus-values.yaml:57` — Medium: Grafana 공개 경로와 별도로 Alertmanager의 일반 `webhook_configs`를 `slack_configs`로 교체했다. architecture.md §6은 Slack/PagerDuty 등 일반 Webhook 수신처를 허용하고 §7은 `url_file`을 명시하지만, 이제 기존 URL 시크릿의 수신처가 Slack Incoming Webhook이어야 하며 일반 Webhook/PagerDuty용 JSON 계약은 유지되지 않는다. 실제 Slack 수신처에 대한 수정 의도는 이해되지만, 지원 범위를 Slack으로 한정하는 결정을 설계·아키텍처·설정 가이드에 반영하거나 수신처에 맞게 통합 방식을 선택할 수 있도록 해야 한다.
- `k8s/gateway/httproute-grafana.yaml:18`, `k8s/monitoring/referencegrant-grafana.yaml:8`, `k8s/monitoring/networkpolicy-grafana.yaml:14` — NGF에서 monitoring Service로 직접 연결하는 변경은 기능 설계에서 승인한 확장이다. ALB TLS/WAF → NGF L7 분기, 기존 앱 stable/canary 경로, 노드 티어와 시크릿 전달 구조의 추가 이탈은 발견하지 못했다. 데이터 플레인 Pod로 출처를 좁힌 구현도 설계 의도와 일치한다.

### 검증
- `git diff master...HEAD`의 전체 55개 파일 변경을 검토했다. 앞선 RDS·대시보드·AZ 분산·종료 처리 변경도 비교 범위에 포함된다. 기존 리뷰의 `[x]` 항목인 Connector/J 고정 버전 검사, VisitSummary 생성자 투영, matchLabelKeys 리스트 검사, 스케일다운 AZ 불균형 설명, 외부 Tomcat/JDBC Pool 종료 설명은 현재 코드·문서에 반영되어 있다. grafana-public-path의 review.md는 없어 첫 라운드로 작성했다.
- `bash scripts/validate-manifests.sh` 통과: YAML 46개·워크로드 6개, 일일 중지/기동 및 이미지 빌드 오프라인 회귀 테스트 통과. `bash -n infra/aws/provision-aws-resources.sh scripts/deploy-all.sh` 통과.
- 로컬 캐시의 kube-prometheus-stack 92.11.0 Grafana 차트 템플릿·기본값을 확인했다. 헬스 프로브는 `/api/health`, 사이드카 reload URL은 기본 `/api/admin/provisioning/...`이므로 실제 subpath 적용 후 프로브·자동 reload·스크랩 성공 여부를 배포 단계에서 확인해야 한다. 이 리뷰에서는 해당 런타임 동작의 성공이나 실패를 확정하지 않았다.
- NetworkPolicy 검증 누락은 파일을 수정하지 않고 메모리에서 재현했다. Maven 테스트는 이번에 재실행하지 않았다. AWS 명령·클러스터 변경·push·머지는 실행하지 않았으며 허용/비허용 IP 접속, 정적 에셋·로그인·세션 쿠키 및 기존 카나리 무간섭 검증은 남아 있다.

### 총평
라우팅·ReferenceGrant·Grafana 설정은 대체로 설계와 일치한다. Critical은 없지만 필수 IP 제한 없이 공개될 수 있는 High가 남아 있어 머지를 보류하며, 별도의 알림 계약 변경과 검증 보완도 필요하다.

머지 가능 여부: No

## Review Round 2 — 2026-10-26 (대상 커밋: bd52ba8)

### Critical
지적 사항 없음.

### High
지적 사항 없음. 변경 코드·문서(`docs/daily` 포함)에서 계정 ID·ARN·엔드포인트·개인 URL 실값 노출은 발견하지 못했다.

### Medium / Low
- [x] (4c2f666) `scripts/lib.sh:56`, `tests/scripts/grafana-waf-ready.test.sh:39` — Medium: 배포 전 WAF 검사는 규칙 이름·Block 액션·IPSet 참조 개수만 확인한다. 예를 들어 해당 이름의 규칙이 `Statement: {IPSetReferenceStatement: ...}`를 직접 가지면 허용 IP를 오히려 차단하고 비허용 IP는 통과시키지만 검사 결과는 true다(현재 jq 식에 메모리 JSON을 넣어 재현). 현재 프로비저닝 코드가 생성하는 규칙은 올바르므로 기본 실행 경로의 새 노출 버그는 아니다. 다만 사전 검사가 보장한다고 설명한 의미를 만족하려면 `/grafana` UriPath 비교 및 변환, AND 아래 NOT IPSet 참조와 대상 IPSet을 구조적으로 확인하고, NOT 제거·다른 경로·다른 IPSet에 대한 음성 시험을 추가해야 한다.

### 기존 아키텍처와의 불일치
- [x] (777ae11, architecture.md §6·§7은 ⑦에서 실제 설정 기준으로 정정) `k8s/monitoring/kube-prometheus-values.yaml:57`, `docs/architecture.md:380`, `.env.example:72` — Medium (Round 1 재지적): Slack 전용 `slack_configs` 전환은 유지되지만 architecture.md §6은 여전히 Slack/PagerDuty 등 일반 Webhook 지원을 기술하고 §7은 `url_file`을 명시한다. `.env.example:74`에는 Slack 전용 설명이 추가됐으나 바로 앞 72행은 Slack/PagerDuty를 계속 안내한다. 따라서 `[x] (02c1e78)` 항목은 부분 해결 상태다. 아키텍처의 지원 수신처를 Slack Incoming Webhook으로 한정하고 파일 설정 이름을 `api_url_file`로 맞추며 환경변수 주석도 일치시켜야 한다. 일반 Webhook을 계속 지원하려면 수신처별 설정 선택이 필요하다.
- NGF → monitoring 직접 라우팅은 기능 설계에서 승인한 확장이다. ALB TLS/WAF → NGF 분기, 기존 앱 stable/canary 경로, 노드 티어 및 ESO 기반 시크릿 전달 구조에서 추가 불일치는 발견하지 못했다.

### 이전 라운드 및 검증
- Round 1 High: `scripts/deploy-all.sh:30`에서 클러스터 변경 전에 WAF 검사를 실행하고 실패 시 종료하며, README 필수 실행 순서에 `grafana-waf`가 추가됐다. 미설정·Count·IPSet 누락·규칙 순서 오류를 거부하는 오프라인 시험도 통과했다. 위 Medium은 이 검사의 의미 검증 범위에 대한 추가 보완이다.
- Round 1 Low: NetworkPolicy의 대상 Pod, Ingress 타입, 정확히 두 출처 및 각 TCP/3000 포트를 구조적으로 검사하도록 수정된 것을 확인했다. 빈 규칙·출처 누락·포트 누락은 이제 조건식에서 거부된다.
- 비교 범위는 `git diff master...HEAD` 전체 59개 파일이다. 앞선 RDS·대시보드·AZ 분산·종료 처리 변경을 포함하며 이번 라운드는 이전 리뷰 이후 수정과 미해결 항목에 중점을 뒀다.
- `bash scripts/validate-manifests.sh` 통과: YAML 46개·워크로드 6개 및 daily-stop/start, build-and-push, grafana-waf-ready 오프라인 회귀 시험. `bash -n infra/aws/provision-aws-resources.sh scripts/deploy-all.sh scripts/lib.sh` 통과.
- AWS 명령·클러스터 변경·push·머지는 실행하지 않았다. 실환경 허용/비허용 IP, 로그인·정적 에셋·세션 쿠키, subpath 적용 후 프로브·사이드카 reload·Prometheus 스크랩 및 카나리 무간섭 검증은 배포 단계에 남아 있다. Maven 테스트는 재실행하지 않았다.

### 총평
기본 배포 경로의 이전 High는 해결됐고 Critical/High 지적은 없다. WAF 검사 강화와 아키텍처 문서 정합성 두 Medium은 후속 보완이 필요하며, 실환경 검증 완료를 의미하는 승인은 아니다.

머지 가능 여부: Yes
