## Review Round 1 — 2026-10-22 (대상 커밋: adc0e70)

리뷰 범위: `git diff master...HEAD` 전체. 기준 문서: `docs/architecture.md`, `docs/design.md`(Step 8–12 및 Q1–Q6 포함). 기능별 설계서가 없어 사용자가 승인한 기존 설계서를 사용했다. 이 기능 경로의 첫 라운드이며, 기존 `docs/review.md` Round 1–2는 보존하고 완료 항목을 재확인했다. 이번 사용자 지시에 따라 쓰기 범위는 이 리뷰 파일로 한정했다.

### Critical

지적 사항 없음.

### High

- [x] `scripts/deploy-all.sh:105` — 기존 카나리 트래픽을 차단하기 전에 새 WAS/Web Deployment를 적용한다. 이전 배포의 90/10 라우팅이 살아 있는 재배포에서는 새 카나리 Pod가 일반 요청을 받을 수 있으며, 이어지는 Web 적용이나 Gateway 적용이 실패하면 `set -e`로 종료되어 기존 10% 가중치가 그대로 남는다. 이는 설계 Step 10의 “먼저 100/0으로 고정한 뒤 Canary 롤아웃”과 어긋난다. 워크로드 변경보다 먼저 100/0 라우팅을 적용하고 Gateway가 해당 변경을 수용한 것을 확인한 뒤 롤아웃할 것. 기존 90/10 상태에서 후속 apply 실패를 주입해도 일반 트래픽이 카나리로 가지 않는 회귀 검증이 필요하다. → 108bd15 (워크로드 적용 전 100:0 HTTPRoute 적용 후 Accepted·현재 generation 확인, 실패 시 워크로드 미변경 종료. 90:10 상태에서 web 적용 실패를 주입한 스텁 회귀로 최종 100:0 확인)

### Medium / Low

- [x] `scripts/rotate-db-secrets.sh:23` — Medium: ExternalSecret 갱신 확인 루프가 30회 모두 실패해도 오류 없이 끝난다. ESO가 지연되거나 중지되어 `refreshTime`은 과거이고 기존 `Ready=True`가 남아 있으면 다음 `kubectl wait`도 즉시 성공해, 옛 비밀번호로 DB 초기화·WAS 재시작을 수행하고 회전 성공을 출력할 수 있다. 각 시크릿에 대해 갱신 성공 여부를 검사하고 제한 시간 내 갱신되지 않으면 DB Job 실행 전에 실패 종료할 것. 현재 루프를 그대로 추출해 `refreshTime=2000-01-01T00:00:00Z`를 반환하도록 모의 실행했을 때 종료 코드 0으로 다음 Ready 대기 단계에 도달했다. → 5bf035f (시크릿별 갱신 미확인 시 db-init 전 exit 1. refreshTime=2000-01-01 스텁에서 exit 1·db-init 미실행 확인)
- [x] `k8s/monitoring/prometheusrule-petclinic.yaml:13` — Medium: 백업이 한 번도 성공하지 않은 경우 `PetClinicDBBackupFailed`가 발화하지 않는다. kube-state-metrics는 `LastSuccessfulTime`이 없으면 해당 시계열 자체를 내보내지 않으므로, 최초 배포부터 백업이 계속 실패하거나 실행되지 않아도 이 식의 결과는 빈 벡터다. 마지막 성공 시각이 없는 CronJob에 대해서는 생성 시각/스케줄 시각을 기준으로 유예 기간을 적용하는 조건을 추가할 것. “첫 성공 없음”, “마지막 성공 후 26시간 초과”, “다음 성공 후 해제”를 Prometheus 규칙 테스트로 검증할 것. 근거: [kube-state-metrics CronJob 메트릭 생성 코드](https://raw.githubusercontent.com/kubernetes/kube-state-metrics/v2.13.0/internal/store/cronjob.go). → 0c343d5 (성공 이력 없으면 kube_cronjob_created 기준 26h. tests/monitoring + scripts/test-prometheus-rules.sh로 첫 성공 없음/26h 초과/다음 성공 후 해제를 promtool 2.54.1로 검증, 기존 식은 실패)

### 기존 아키텍처와의 불일치

- [x] `docs/architecture.md:158` — Medium: 아키텍처의 EKS 1.31/AL2023 20241024, Karpenter 1.0.6/KEDA 2.15.2/ESO 0.10.4 및 EBS CSI 고정 버전 표기가 현재 구현과 다르다. `infra/eksctl/cluster.yaml:9`는 EKS 1.36이고, `infra/karpenter/ec2nodeclass.yaml:9`는 AMI 20260930이며, `scripts/deploy-all.sh:51` 이후는 Karpenter 1.15.0/KEDA 2.21.0/ESO 2.13.0을 설치한다. EBS CSI 버전도 고정되어 있지 않다. 이는 설계 Q4/Q6에서 승인·설명한 변경이므로 이전 버전으로 되돌릴 결함은 아니지만, 머지 전 아키텍처 갱신에서 버전 표와 개요·디렉터리 설명을 함께 맞춰야 한다. 새 클러스터 생성 기준이라는 제한도 기록할 것. → a7a4c15, 67aca10 (버전 표·개요·디렉터리 설명·새 클러스터 기준 제한 반영, 다이어그램 drawio/svg 표기 1.36. PNG는 재생성하지 않음)
- [x] `docs/architecture.md:142` — Medium: DB Job과 WAS가 동일한 시크릿을 사용한다는 설명이 설계 Step 9의 Admin/App/Backup 분리 및 `k8s/secrets/externalsecret-rds.yaml:5` 이후 세 ExternalSecret과 어긋난다. 또한 `docs/architecture.md:181` 이후의 환경변수 표에는 필수 `STABLE_IMAGE_TAG`, `CANARY_IMAGE_TAG`, `RDS_APP_SECRET_NAME`, `RDS_BACKUP_SECRET_NAME`, `ALERTMANAGER_WEBHOOK_URL`이 빠져 있다. 운영자가 기존 문서대로 준비하면 배포의 필수 변수 검사에서 중단된다. 머지 전 아키텍처 갱신에서 계정별 소비자와 환경변수·회전 절차를 반영할 것. 이 변경들도 설계 Step 9–11에 명시된 의도적인 확장이다. → a7a4c15 (계정별 시크릿 소비자·권한, 회전 절차, 누락 환경변수 반영)

### 이전 라운드 완료 항목 재확인 및 정정

- `app/pom.xml:591`, `.env.example:33`, `scripts/deploy-all.sh:48` — MySQL JDBC 좌표, 인용된 JAVA_OPTS, Metrics Server 설치 수정은 유지되어 있다. 기존 빌드·배포·검증·AWS 프로비저닝 진입점의 Git 실행 비트도 확인했다.
- `app/src/main/webapp/WEB-INF/jsp/pets/createOrUpdatePetForm.jsp:12`, `app/src/main/webapp/WEB-INF/jsp/pets/createOrUpdateVisitForm.jsp:13` — 날짜 선택기의 `Y/m/d` 설정과 `app/src/test/java/org/springframework/samples/petclinic/web/VisitControllerTests.java:60`의 날짜 입력 회귀 테스트가 추가되어 있다. 설계 Q3에서 UI 설정 변경도 허용했다.
- 이전 날짜 지적의 “ISO 날짜가 반드시 바인딩 오류로 거절된다”는 판단은 정정한다. 이 저장소의 Spring 7.0.9는 지정 패턴 파싱 실패 시 기본 ISO 파싱으로 폴백한다. 형식 통일 패치는 확인했지만, 이전 High의 서버 거절 단정은 근거가 부족했으며 미해결 결함으로 유지하지 않는다. 근거: [Spring 7.0.9 TemporalAccessorParser](https://raw.githubusercontent.com/spring-projects/spring-framework/v7.0.9/spring-context/src/main/java/org/springframework/format/datetime/standard/TemporalAccessorParser.java).
- `infra/karpenter/nodepool-app.yaml:9` — On-Demand 전용 풀의 weight 100/16 vCPU 한도와 별도 Spot 풀을 확인했다. 기존 혼합 목록 지적은 수정되었다.
- `scripts/deploy-all.sh:110` — 두 카나리 Deployment의 rollout 대기와 헤더 기반 동적 경로 검사가 추가되어 기존 완료 검사 누락은 수정되었다. 이번 High는 별개의 재배포 순서 결함이다.
- `scripts/deploy-all.sh:75`, `k8s/gateway/pdb-nginx-gateway.yaml:8` — NGF replica 2, AZ 분산 및 PDB는 유지되어 있다. 완료 표시된 기존 항목 중 원래 수정 자체가 누락되어 재등록할 항목은 없다. 기존 리뷰의 총평은 당시 기록으로 보존하며 현재 머지 판단은 아래 총평을 따른다.

### 검증 기록

- 동일 대상 커밋 `adc0e70`에서 Git Bash + Python/PyYAML로 `PYTHON=python scripts/validate-manifests.sh` 실행: `OK: 34 YAML files, 6 workloads checked`.
- `scripts/*.sh`, `infra/aws/*.sh`의 `bash -n` 구문 검사 통과.
- 시크릿 갱신 루프 모의 실행: kubectl은 과거 갱신 시각을 반환하고 sleep은 대체했으며, AWS/Kubernetes 상태 변경 없이 제한 횟수 소진 후 계속 진행하는 경로를 재현했다.
- Java/Maven/Docker/Helm이 PATH에 없어 앱 테스트·이미지 빌드·Helm 렌더링은 실행하지 못했다. 실제 클러스터 배포, 카나리 장애 주입, Prometheus 규칙 실행 및 브라우저 통합 검증은 수행하지 않았다. 매니페스트 검증기의 통과는 위 런타임 동작의 검증을 의미하지 않는다.

### 총평

기존 리뷰 수정과 운영 강화 설계는 대체로 반영됐지만, 카나리 재배포 순서 및 회전·백업 실패 감지 보완이 필요하다. 머지 가능 여부: **No (Critical 없음, High 1건, Medium 4건 — 아키텍처 문서 불일치 2건 포함)**.
