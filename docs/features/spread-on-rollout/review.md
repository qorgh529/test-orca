## Review Round 1 — 2026-10-26 (대상 커밋: f7d5c57)

### Critical
지적 사항 없음.

### High
지적 사항 없음. 변경 코드·문서(docs/daily 포함)에서 계정 ID·ARN·엔드포인트·개인 URL 실값 노출은 발견하지 못했다.

### Medium / Low
- [x] (acf5368) `docs/features/spread-on-rollout/design.md:225`, `docs/features/spread-on-rollout/design.md:228` — Medium: 스케일다운 시 ReplicaSet이 AZ 균형을 유지하며 matchLabelKeys가 완벽한 대칭성을 보장한다는 설명은 정확하지 않다. topologySpreadConstraints는 새 Pod 스케줄링 시 평가하며 ReplicaSet의 축소 대상 선택에 AZ 균형을 강제하지 않는다. 따라서 HPA/KEDA가 4개(2:2)를 2개로 줄인 뒤 2:0이 남을 수 있고, 새 Pod 생성 없이는 이 설정만으로 치유되지 않는다. 보장 범위를 두 AZ가 스케줄링 대상인 상태에서의 리비전별 신규 배치·롤아웃으로 한정하고, 축소 후 불균형 가능성과 운영 확인 방법을 명시할 것을 제안한다. 근거: [Kubernetes 공식 문서 — Known limitations](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/#known-limitations).
- [x] (5b4f35e) `scripts/validate-manifests.sh:393` — Low: 문자열에 대한 포함 검사도 허용하므로 `matchLabelKeys: pod-template-hash`처럼 API 스키마에 맞지 않는 스칼라가 검증을 통과한다. 설계 §6 Step 4의 리스트 형태 검증이 빠져 있다. `isinstance(value, list)`와 원소 포함 여부를 함께 검사할 것을 제안한다. 저장소를 수정하지 않고 실제 §10 코드를 메모리에서 실행해 baseline 통과, 키 제거·정책 변경 실패, 문자열 값 통과를 확인했다. 현재 네 Deployment의 실제 값은 올바른 리스트다.

### 기존 아키텍처와의 차이
- `k8s/web/deployment.yaml:26`, `k8s/web/deployment.yaml:97`, `k8s/was/deployment-stable.yaml:27`, `k8s/was/deployment-canary.yaml:27` — app/track별 AZ 분산 계산을 pod-template-hash별로 좁힌다. 기능 설계에서 명시한 변경이며 기존 app 노드 티어, stable 강제/canary 선호 정책, PDB·HPA·KEDA 구성과 어긋나는 구현은 발견하지 못했다. 신규 설정의 설명은 워크플로 ⑦에서 architecture.md에 반영할 수 있다.

### 검증
- `git diff master...HEAD` 전체 44개 파일을 검토했다. 비교 범위에는 이전 RDS·대시보드·운영 스크립트 변경도 포함된다. 기존 rds-mysql-84 리뷰의 고정 Connector/J 검사와 staff-dashboard 리뷰의 EAGER 추가 조회 문제는 각각 정확한 버전 비교와 VisitSummary 생성자 투영으로 실제 수정되어 있다. spread-on-rollout의 기존 review.md는 없어 이전 라운드 재확인 대상은 없다.
- `bash scripts/validate-manifests.sh` 통과: YAML 43개·워크로드 6개 및 일일 중지/기동·이미지 빌드 오프라인 회귀 테스트 통과.
- 새 §10 검사를 실제 YAML의 메모리 사본으로 실행했다. 키 누락과 stable 정책 변경을 각각 검출했으며, 위 Low의 스칼라 허용도 재현했다. 소스 파일은 수정하지 않았다.
- 실클러스터 적용·반복 롤아웃·HPA 축소 시험과 Maven 테스트는 실행하지 않았다. AWS 명령·push·머지도 실행하지 않았다. 설계 §6 Step 6~8의 실제 AZ 배치 검증은 별도 승인 단계로 남는다.

### 총평
네 Deployment의 리비전별 분산 설정은 설계와 일치하며 Critical·High 지적은 없다. Medium 문서 보장 범위와 Low 검증 타입 보완이 남아 있고 실클러스터 분산 효과는 아직 직접 검증하지 않았다.

머지 가능 여부: Yes
