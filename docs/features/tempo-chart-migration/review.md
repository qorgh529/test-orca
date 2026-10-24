## Review Round 1 — 2026-10-24 (대상 커밋: a652799)

### Critical
지적 사항 없음.

### High
지적 사항 없음. 변경분의 코드·문서(`docs/daily` 포함)에서 계정 ID·ARN·개인 엔드포인트·개인 URL 실값 노출은 발견하지 못했다.

### Medium / Low
- [ ] **Medium — 기존 아키텍처·설계와 실제 WAL 경로 불일치:** `docs/features/tempo-chart-migration/design.md:31` — 기존 `/var/tempo/wal`을 Live-Store가 그대로 사용한다는 설명과 `docs/features/tempo-chart-migration/design.md:126`의 데이터 흐름은 실제 설정과 다르다. 차트 3.2.1 렌더에는 `live_store`가 없고, Tempo 3.1.1의 `live_store.wal.path` 기본값은 `/var/tempo/live-store/traces`다([업스트림 기본값](https://github.com/grafana/tempo/blob/v3.1.1/modules/livestore/config.go#L122-L124)). `k8s/tracing/tempo-values.yaml:51`의 `storage.trace.wal.path`만으로 새 Live-Store WAL 경로가 지정되지는 않는다. 실제 경로도 `/var/tempo` PVC 안이므로 이 차이 자체가 읽기 전용 루트 기동 실패를 뜻하지는 않지만, 기존 WAL을 그대로 재사용·복구한다고 오인할 수 있다. 설계의 경로·다이어그램·§5.4 쓰기 경로 설명을 실제 기본값에 맞추고, 기존 배포를 업그레이드할 경우 미완성 WAL의 처리/사전 flush 조건을 별도로 명시할 것을 제안한다. 현재 아키텍처의 단일 바이너리·전용 S3/IRSA·10Gi PVC·ng-platform 배치·외부 인터페이스는 유지된다.

### 검증
- `git diff master...HEAD` 전체 6개 파일과 architecture.md·design.md 대조. 기존 review.md가 없어 이전 라운드 재검증 대상 없음.
- `./scripts/validate-manifests.sh`: 통과(42 YAML, 6 workloads, daily stop/start 오프라인 회귀 포함).
- `./scripts/test-prometheus-rules.sh`: 통과.
- 차트 3.2.1 로컬 `helm template`: 정상 렌더, 이미지 3.1.1·IRSA SA·보안 설정·포트·레이블·PVC 유지, ballast 인자 없음. 기본값과 구별되는 `168h`로 scheduler/worker 양쪽 retention 반영 확인.
- 구 차트 1.24.4와 StatefulSet `selector`·`serviceName`·`volumeClaimTemplates` 동일 확인. 이는 Kubernetes 불변 필드 비교이며 Tempo 데이터/WAL 호환성 검증은 아니다.
- 실제 AWS 명령·배포·push·머지는 실행하지 않았다. 컨테이너 기동·S3 쓰기·E2E 트레이싱은 미검증이며 설계 Step 3의 후속 검증 대상이다.

### 총평
구현 변경은 설계의 차트·이미지 전환 범위에 부합하고 Critical/High 문제는 발견하지 못했다. WAL 경로 설명은 실제 동작에 맞춰 보완할 필요가 있으며, 실배포 검증은 별도 단계로 남는다.

머지 가능 여부: Yes
