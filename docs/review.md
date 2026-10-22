## Review Round 1 — 2026-10-21 (대상 커밋: 3e68abb)

리뷰 범위: `git diff master...HEAD` 전체. 기준 문서: `docs/design.md` (Q1의 90/10 분할 및 Q2의 TriggerAuthentication 생략 합의 포함). 기존 리뷰 파일이 없어 이전 라운드의 완료 항목은 없다.

### Critical

지적 사항 없음.

### High

- [x] `app/pom.xml:575` — MySQL 프로필이 존재하지 않는 `mysql:mysql-connector-java:8.1.0` 좌표를 사용한다. 구 좌표의 relocation 제공은 8.0.33까지이며, 8.1.0은 `com.mysql:mysql-connector-j`를 사용해야 한다. `docker/was/Dockerfile:10`에서 이 프로필로 빌드하므로 운영 WAR 이미지 생성이 의존성 해석 단계에서 막힌다. 좌표를 수정하고 MySQL 프로필의 실제 패키징을 검증할 것. 근거: [MySQL 개발팀 설명](https://bugs.mysql.com/bug.php?id=109628), [공식 Maven 설치 안내](https://dev.mysql.com/doc/connector-j/en/connector-j-installing-maven.html). → c94f454 (MySQL WAR 패키징 확인: mysql-connector-j-8.1.0.jar 포함)
- [x] `.env.example:30` — 공백이 있는 `JAVA_OPTS=-Xms512m -Xmx1024m` 값에 따옴표가 없다. 안내대로 `.env`로 복사하면 `scripts/lib.sh:3` 및 `infra/aws/provision-aws-resources.sh:12`의 source 단계에서 `-Xmx1024m`을 실행하려고 하며, `set -e` 때문에 빌드·프로비저닝·배포가 모두 중단된다. `bash -c 'set -e; source .env.example'`에서 `line 30: -Xmx1024m: command not found`를 재현했다. 값 전체를 따옴표로 묶고 템플릿 source 검증을 추가할 것. → 540b8eb
- [x] `scripts/deploy-all.sh:12` — 직접 실행하는 `scripts/validate-manifests.sh`가 Git에 실행 권한 없는 `100644`로 저장되어 있다. Linux의 새 checkout에서는 `bash scripts/deploy-all.sh`로 시작해도 이 줄에서 `Permission denied`로 종료된다. `git ls-files --stage`로 확인했으며 다른 진입점 셸 스크립트도 같은 상태여서 문서의 `./infra/aws/provision-aws-resources.sh` 실행 역시 실패한다. 직접 실행할 파일은 실행 비트를 커밋하거나 호출부를 명시적인 `bash` 실행으로 통일하고 Linux checkout에서 검증할 것. → 11a989a
- [x] `k8s/web/hpa.yaml:14` — CPU Resource metric을 사용하는 HPA를 만들지만 `infra/eksctl/cluster.yaml:47`의 애드온 목록과 `scripts/deploy-all.sh` 어디에도 Kubernetes Metrics Server 설치가 없다. 새 EKS 클러스터에는 기본 배포되지 않으므로 CPU 사용률을 조회하지 못해 web 자동 확장이 동작하지 않는다. Prometheus, kube-state-metrics, KEDA의 external metrics 서버는 이 Resource Metrics API를 대신하지 않는다. Metrics Server를 노드 배치 조건과 함께 설치하고 `metrics.k8s.io` 가용성 및 HPA CPU 조회를 확인할 것. 근거: [AWS Metrics Server 안내](https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html). → 9bca8b1
- [x] `app/src/main/webapp/WEB-INF/jsp/pets/createOrUpdatePetForm.jsp:12` — 날짜 선택기가 기본 `Y-m-d` 형식(예: `2026-10-21`)을 보내지만 `app/src/main/java/org/springframework/samples/petclinic/model/Pet.java:49`는 `yyyy/MM/dd`만 받는다. `createOrUpdateVisitForm.jsp:13`과 `model/Visit.java:41`에도 같은 불일치가 있어 달력으로 날짜를 선택한 정상 등록/수정 요청이 날짜 바인딩 오류로 거절된다. 양쪽 형식을 일치시키고 실제 선택기가 생성하는 날짜로 등록/수정을 검증할 것. 현재 `PetControllerTests.java:71`은 슬래시 날짜를 직접 주입하여 이 문제를 놓친다. 근거: [flatpickr 4.6.13 기본 옵션](https://raw.githubusercontent.com/flatpickr/flatpickr/v4.6.13/src/types/options.ts). → 보류: 설계 §1.3(UI 수정 금지)과 충돌, design.md Q3 결정 대기 → 3eb014a (참고: Spring 7.0.9는 패턴 실패 시 ISO로 폴백해 `2026-10-21`도 바인딩됨. 형식 통일로 처리)

### Medium / Low

- [x] `scripts/deploy-all.sh:63` — NGF 설치에 replica 수와 AZ 분산 설정이 없어 1.5.1 차트 기본값인 단일 replica로 동작한다. ALB 이후 모든 요청이 이 한 Pod를 통과하므로 해당 노드/AZ 장애나 교체 시 web/was 및 RDS를 다중화해도 전체 서비스 경로가 끊긴다. 설계 §1.1의 Multi-AZ 고가용성을 충족하도록 `nginxGateway.replicaCount`를 2 이상으로 설정하고 AZ 분산 및 자발적 중단 보호를 함께 구성할 것. 근거: [고정 버전 NGF 차트 기본값](https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v1.5.1/charts/nginx-gateway-fabric/values.yaml). → 9bca8b1 (replica 2 + zone spread + PDB)

### 검증 기록

- Git Bash + Python/PyYAML로 기존 `scripts/validate-manifests.sh` 실행: `OK: 29 YAML files, 6 workloads checked`. 이 검사는 위 환경변수 실행 오류, 실행 비트, Maven 좌표, Helm 기본값 및 날짜 UI 연동을 검증하지 않는다.
- `scripts/*.sh`, `infra/aws/*.sh`의 `bash -n` 구문 검사 통과. `.env.example` source 검사는 위 오류로 실패했다.
- `git diff --check master...HEAD`는 가져온 앱 파일의 trailing whitespace/EOF 공백을 보고했다. 기능 결함과 구분하여 별도 지적으로 올리지 않았다.
- Java/Maven/Docker/Helm 실행 도구가 PATH에 없어 앱 테스트·이미지 빌드·Helm 렌더링은 실행하지 못했다. 실제 AWS/EKS 배포 및 브라우저 통합 검증도 수행하지 않았으며, 관련 판단은 저장소 코드와 명시된 버전의 공식 자료를 교차 확인한 결과다.

### 총평

계층 분리와 합의된 카나리 구성은 설계 방향에 부합하지만, 빌드·배포를 막는 문제와 자동 확장 및 날짜 입력 결함을 먼저 해결해야 한다. 머지 가능 여부: **No (High 5건 미해결, Critical 없음)**.

## Review Round 2 — 2026-10-22 (대상 커밋: c63793f)

리뷰 범위: `git diff master...HEAD` 전체. 기준 문서: `docs/design.md` 및 Q1/Q2 합의, Q3 미결 상태. 소스 코드 변경 없이 리뷰만 추가했다.

### Critical

지적 사항 없음.

### High

- [x] `app/src/main/webapp/WEB-INF/jsp/pets/createOrUpdatePetForm.jsp:12` — Round 1의 날짜 형식 불일치가 여전히 남아 있다. flatpickr 기본값은 `Y-m-d`인데 `app/src/main/java/org/springframework/samples/petclinic/model/Pet.java:49`는 `yyyy/MM/dd`를 요구한다. `app/src/main/webapp/WEB-INF/jsp/pets/createOrUpdateVisitForm.jsp:13`과 `app/src/main/java/org/springframework/samples/petclinic/model/Visit.java:41`도 동일하다. 달력에서 선택한 날짜로 Pet/Visit 등록 또는 Pet 수정을 제출하면 바인딩 오류가 발생한다. 설계 Q3의 예외 허용 여부를 결정한 뒤 날짜 형식을 맞추고, 실제 선택기가 생성하는 입력으로 회귀 검증할 것. 보류 사유는 확인했으나 기능 결함이 해결된 것은 아니다. 근거: [flatpickr 4.6.13 기본 옵션](https://raw.githubusercontent.com/flatpickr/flatpickr/v4.6.13/src/types/options.ts). → 보류: design.md Q3(§1.3 예외 허용 여부) 사용자 결정 대기 → 3eb014a (참고: Spring 7.0.9는 패턴 실패 시 ISO로 폴백해 `2026-10-21`도 바인딩됨. 형식 통일로 처리)

### Medium / Low

- [x] `infra/karpenter/nodepool-app.yaml:18` — Medium: `on-demand`와 `spot`을 함께 허용하는 목록은 우선순위나 기본 On-Demand 용량을 보장하지 않는다. Karpenter는 이 구성에서 Spot을 우선하므로 NGF/web/was가 모두 Spot에 배치될 수 있으며, 설계 §4.2의 “On-Demand 기본 + Spot 확장”과 다르다. 기본 용량을 On-Demand에 배치하는 노드풀 및 워크로드 제약을 명시하고 Spot 확장 정책을 분리하거나, 설계를 실제 Spot 우선 정책과 일치시키는 합의를 남길 것. 근거: [Karpenter v1.0 Capacity Type](https://karpenter.sh/v1.0/concepts/nodepools/#capacity-type). → 239a6b2
- [x] `scripts/deploy-all.sh:102` — Medium: 배포 완료 검사가 `was-stable`과 `web`만 기다린다. 앞서 적용한 `k8s/gateway/httproute-canary.yaml:24`는 이미 카나리에 10%를 배분하므로, `was-canary` 또는 `web-canary`가 Pending/CrashLoop 상태여도 스크립트는 성공과 접속 URL을 출력할 수 있다. 특히 web의 `/healthz`는 WAS를 조회하지 않아 stable web 준비 상태로 카나리 장애를 검출할 수 없다. 두 카나리 Deployment의 rollout도 확인하고, `X-Canary: always`를 사용한 동적 경로 확인을 배포 검증에 포함할 것. 카나리 실패를 주입했을 때 배포 검사가 실패하는지도 검증할 것. → aacf300 (실클러스터 장애 주입 검증은 미수행)

### 이전 라운드 완료 항목 재확인

- `app/pom.xml:591` — MySQL 좌표가 `com.mysql:mysql-connector-j`로 수정되어 있다. 이번 라운드에서는 WAR 패키징을 재실행하지 않았다.
- `.env.example:30` — `JAVA_OPTS` 전체가 인용되어 있으며, 이를 source하는 기존 검증 스크립트가 통과했다.
- `scripts/deploy-all.sh:12` — 직접 실행하는 검증 스크립트와 빌드·배포·프로비저닝 진입점의 Git 모드가 `100755`인 것을 확인했다.
- `scripts/deploy-all.sh:47` — Metrics Server 설치와 critical 배치 설정이 추가되어 있다. 실제 Resource Metrics API 가용성은 클러스터에서 별도 확인해야 한다.
- `scripts/deploy-all.sh:73` — NGF replica 2, AZ 분산 설정 및 `k8s/gateway/pdb-nginx-gateway.yaml:8`의 PDB를 확인했다. [NGF 1.5.1 Deployment 템플릿](https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v1.5.1/charts/nginx-gateway-fabric/templates/deployment.yaml)이 해당 replica/topologySpreadConstraints 값을 사용하는 것도 확인했다. 완료 처리된 항목 중 코드상 미수정으로 재등록할 항목은 없다.

### 검증 기록

- Git Bash + Python/PyYAML로 `PYTHON=python scripts/validate-manifests.sh` 실행: `OK: 31 YAML files, 6 workloads checked`.
- `scripts/*.sh`, `infra/aws/*.sh`의 `bash -n` 구문 검사 통과. Git 실행 비트도 별도 확인했다.
- Java/Maven/Docker/Helm이 PATH에 없어 앱 테스트, 이미지 빌드 및 Helm 렌더링은 실행하지 못했다. 실제 AWS/EKS 배포, 장애 주입 및 브라우저 통합 검증도 수행하지 않았다. 위 추가 지적은 코드·설계 및 고정 버전 공식 자료를 대조한 정적 리뷰 결과이며, 기존 매니페스트 검증기의 통과가 이 동작들을 검증한다는 뜻은 아니다.

### 총평

이전 완료 항목의 수정은 코드에 반영됐지만 날짜 입력 결함과 용량 정책·배포 완료 검증의 보완 사항이 남아 있다. 머지 가능 여부: **No (High 1건, Medium 2건 미해결; Critical 없음)**.
