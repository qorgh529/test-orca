## Review Round 1 — 2026-10-23 (대상 커밋: 6c6aebd)

### Critical
- [x] `k8s/tracing/tempo-values.yaml:52` — `tempo.receivers.jaeger: null`로 덮어쓰면 고정 차트 `grafana/tempo` 1.24.4의 `_ports.tpl`이 `.Values.tempo.receivers.jaeger.protocols.thrift_compact` 등을 참조할 때 Helm 템플릿 렌더링이 실패한다. `scripts/deploy-all.sh`의 Tempo 설치가 중단되므로, Jaeger 값을 null로 만들지 말고 차트가 참조하는 `protocols` 구조를 유지한 채 수신을 비활성화하거나 차트 렌더링 결과로 검증하라. 근거: [차트 포트 템플릿](https://github.com/grafana/helm-charts/blob/tempo-1.24.4/charts/tempo/templates/_ports.tpl). — `277762e`

### High
- [x] `k8s/tracing/tempo-values.yaml:31` — Tempo 컨테이너 제한을 1Gi로 설정했지만 같은 차트의 기본 `tempo.memBallastSizeMbs`는 1024다. 차트가 `-mem-ballast-size-mbs=1024`를 전달하므로 애플리케이션 메모리까지 더하면 OOM 재시작 위험이 크다. ballast 크기를 줄이거나 비활성화하고 그에 맞춰 메모리 요청·제한을 다시 정하라. 근거: [차트 기본값](https://github.com/grafana/helm-charts/blob/tempo-1.24.4/charts/tempo/values.yaml), [StatefulSet 템플릿](https://github.com/grafana/helm-charts/blob/tempo-1.24.4/charts/tempo/templates/statefulset.yaml). — `277762e`

### Medium / Low
- [x] `k8s/tracing/tempo-values.yaml:39` — Tempo 보존 기간은 336h로 고정인데 S3 Lifecycle은 `TEMPO_RETENTION_DAYS` 값으로 바뀐다. 운영자가 환경변수만 조정하면 Tempo 보존 기간과 실제 객체 만료 시점이 달라져 조회 실패 또는 기대보다 긴 보관이 발생한다. 두 값을 같은 변수에서 렌더링하거나 배포 전에 일치 여부를 검증하라. — `277762e` `ddd37a6`

### 기존 아키텍처 일치
기존 `docs/architecture.md`의 노드 티어와 관측성 흐름에 반하는 변경은 확인하지 못했다. APM 구성은 해당 티어에 추가되며 아키텍처 문서 반영은 `ORCA_WORKFLOW.md`의 후속 단계로 예정되어 있다.

### 총평
Tempo 차트 렌더링 실패와 메모리 설정 문제를 수정하고 `helm template`로 실제 차트 출력을 검증해야 한다. 공개 저장소에 노출된 계정 ID·ARN·개인 엔드포인트 실값은 확인하지 못했다.

머지 가능 여부: No

## Review Round 2 — 2026-10-23 (대상 커밋: eee4869)

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium / Low
지적 사항 없음.

### 기존 아키텍처 일치
`k8s/tracing/otel-operator-values.yaml:4`, `k8s/tracing/otel-collector-values.yaml:14`, `k8s/tracing/tempo-values.yaml:4`의 노드 배치는 `docs/architecture.md`의 `ng-critical` 컨트롤러·`ng-platform` 관측성 티어와 일치한다. 기존 아키텍처와 어긋나는 변경은 확인하지 못했다.

### 총평
1차 리뷰의 세 항목은 `k8s/tracing/tempo-values.yaml:30`, `k8s/tracing/tempo-values.yaml:42`, `k8s/tracing/tempo-values.yaml:55` 및 `scripts/deploy-all.sh:20`에서 수정된 것을 확인했다. `git diff --check master...HEAD`는 통과했으며, Helm 렌더링과 실클러스터 동작은 이번 리뷰 환경에서 재실행하지 않았다.

머지 가능 여부: Yes
