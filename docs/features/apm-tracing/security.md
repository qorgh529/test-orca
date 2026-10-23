# 보안 및 인프라 점검 결과 (`docs/features/apm-tracing/security.md`)

## Security Round 1 — 2026-10-23 (대상 커밋: 976f2fe)

점검 범위: `git diff master...HEAD` 전체, `docs/architecture.md` 보안 구조(§7), `docs/features/apm-tracing/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 미추적, `.env.example`에 민감값 없음, `k8s/tracing/tempo-values.yaml` 내 `access_key`/`secret_key` 등 정적 AWS 자격증명 미사용 및 IRSA `monitoring/tempo` 전용 구성 확인).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-23.md`, `docs/features/apm-tracing/design.md`, `docs/features/apm-tracing/review.md`, `README.md` 모두 플레이스홀더 사용 확인).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (`infra/aws/iam-policies/tempo-policy.json`은 `${TEMPO_S3_BUCKET_NAME}` 버킷의 `s3:ListBucket` 및 `${TEMPO_S3_BUCKET_NAME}/*` 객체의 `Put/Get/Delete/Tagging` 권한만 부여하며 기존 `BACKUP_S3_BUCKET_NAME`과 완전히 분리됨. `infra/aws/provision-aws-resources.sh:60`에서 두 버킷 이름 충돌 시 즉시 실패 처리).
- **네트워크 노출 (열린 포트, `0.0.0.0/0`, 공개 버킷)**: 이상 없음 (`infra/aws/provision-aws-resources.sh:124-127`에서 Tempo S3 버킷 퍼블릭 액세스 4종 완전 차단 및 `SSE-KMS` 암호화 적용, `k8s/base/networkpolicy-petclinic.yaml:77-93` 및 `k8s/tracing/networkpolicy-tracing.yaml:1-76`에서 `was`→`otel-collector`(`:4317`, `:4318`), `prometheus`→`otel-collector`(`:8889`), `otel-collector`→`tempo`(`:4317`), `grafana`→`tempo`(`:3200`), `tempo`→외부 HTTPS(`:443`, IMDS `169.254.169.254/32` 제외)만 최소 개방).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (`opentelemetry-operator` chart `0.105.0`/image `0.144.0`, `autoinstrumentation-java:2.12.0`, `opentelemetry-collector` chart `0.116.0`/image `0.120.0`, `tempo` chart `1.24.4`/image `2.9.0`, `kube-rbac-proxy:v0.20.0` 모두 명시적 태그 고정 및 `:latest` 미사용).
- **IaC / 컨테이너 하드닝 / 입력 검증 / 가용성**: 아래 Critical 1건, High 1건, Medium 2건, Low 1건 확인.

### Critical
- [ ] `k8s/tracing/tempo-values.yaml:52` — `tempo.receivers.jaeger: null`(및 `opencensus: null`)로 설정되어 있어 고정 버전 차트인 `grafana/tempo` `1.24.4`의 `templates/_ports.tpl`이 `.Values.tempo.receivers.jaeger.protocols.thrift_compact` 등 하위 맵을 참조할 때 `nil pointer evaluating interface {}.protocols` 오류로 Helm 템플릿 렌더링 자체가 실패한다. 이로 인해 `scripts/deploy-all.sh:109`에서 Tempo 배포 및 후속 워크로드 배포가 전면 중단된다. / 해결책: `k8s/tracing/tempo-values.yaml`에서 `jaeger: null` 및 `opencensus: null`을 제거하거나 차트 `_ports.tpl`이 기대하는 맵 구조(`otlp` 수신기만 정의하고 불필요한 수신기 null 덮어쓰기 제거)를 유지할 것(Tempo Pod 인그레스는 이미 `k8s/tracing/networkpolicy-tracing.yaml:50-61`에 의해 `:4317`, `:4318`, `:3200`으로만 제한됨).

### High
- [ ] `k8s/tracing/tempo-values.yaml:31` — Tempo 컨테이너의 메모리 Limits가 `1Gi`(`1024Mi`)로 설정되어 있으나, `grafana/tempo` `1.24.4` 차트의 기본값 `tempo.memBallastSizeMbs: 1024`가 그대로 적용되어 컨테이너 기동 인자로 `-mem-ballast-size-mbs=1024`가 전달된다. 메모리 밸러스트(1024MiB)만으로도 컨테이너 cgroup 메모리 한도(`1Gi`) 전체를 점유하므로 실제 트레이스 수신·버퍼링 시 즉각적인 `OOMKilled`(`Exit Code 137`)와 트레이싱 백엔드 불능(가용성 침해)을 유발한다. / 해결책: `k8s/tracing/tempo-values.yaml`의 `tempo:` 하위에 `memBallastSizeMbs: 0`(또는 `limits.memory: 1Gi` 내에서 충분한 여유를 남기는 값)을 명시적으로 설정할 것.

### Medium
- [ ] `k8s/tracing/tempo-values.yaml:32`, `scripts/validate-manifests.sh:247` — `k8s/tracing/otel-collector-values.yaml:33` 및 기존 애플리케이션·잡 워크로드에는 모두 `readOnlyRootFilesystem: true`가 설정되어 있으나(`docs/architecture.md` §7.5, `README.md:45`), `k8s/tracing/tempo-values.yaml:32-35`의 `tempo.securityContext`에는 `readOnlyRootFilesystem: true`가 누락되어 있어 컨테이너 침해 시 루트 파일시스템 변조가 가능하다. 또한 `scripts/validate-manifests.sh:245-255`에서 신규 트레이싱 Helm values(`otel-operator-values.yaml`, `otel-collector-values.yaml`, `tempo-values.yaml`)의 비루트 실행 및 컨테이너 `securityContext` 하드닝 설정 여부를 검증하지 않는다. / 해결책: `k8s/tracing/tempo-values.yaml:32`의 `tempo.securityContext`에 `readOnlyRootFilesystem: true`를 추가하고(WAL 및 블록 스토리지는 이미 `/var/tempo` PVC에 마운트됨), `scripts/validate-manifests.sh`에서 트레이싱 Helm values 3종의 `securityContext`(`runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ALL`, `readOnlyRootFilesystem: true`)를 정적 검증할 것.
- [ ] `scripts/deploy-all.sh:12`, `k8s/was/instrumentation.yaml:16`, `k8s/was/deployment-stable.yaml:45`, `k8s/was/deployment-canary.yaml:45` — `scripts/deploy-all.sh:12`에서 `OTEL_TRACES_SAMPLER_ARG`와 `OTEL_DEPLOYMENT_ENVIRONMENT` 환경변수를 형식·범위 검증 없이 `envsubst`로 매니페스트에 직접 치환한다(`STABLE_WEIGHT`/`CANARY_WEIGHT`는 `check_weights`로, `TEMPO_RETENTION_DAYS`는 `provision-aws-resources.sh:63`에서 정규식으로 검증하는 것과 대비됨). `OTEL_TRACES_SAMPLER_ARG`에 `0.0~1.0` 범위를 벗어난 값이나 비숫자 문자열이 들어가면 OpenTelemetry Operator Webhook 거부 또는 의도치 않은 100% 샘플링 부하가 발생할 수 있고, `OTEL_DEPLOYMENT_ENVIRONMENT`에 쉼표(`,`)·공백·제어문자가 포함되면 `OTEL_RESOURCE_ATTRIBUTES` 키-값 구문이 오염되거나 YAML 인젝션이 발생할 수 있다. / 해결책: `scripts/deploy-all.sh`(또는 `scripts/lib.sh`)에서 렌더링 전에 `OTEL_TRACES_SAMPLER_ARG`가 `0` 이상 `1` 이하의 유효한 소수(`^(0(\.[0-9]+)?|1(\.0+)?)$`)인지, `OTEL_DEPLOYMENT_ENVIRONMENT`가 안전한 식별자(`^[a-zA-Z0-9._-]+$`)인지 검증할 것.

### Low
- [ ] `k8s/tracing/tempo-values.yaml:39`, `scripts/lib.sh:16`, `scripts/deploy-all.sh:109` — S3 수명 주기 만료 일수는 `TEMPO_RETENTION_DAYS`(기본 `14`일) 환경변수로 설정 가능하며 `scripts/lib.sh:16`의 `TEMPLATE_VARS`에도 등록되어 있으나, 정작 `k8s/tracing/tempo-values.yaml:39`는 `retention: 336h`로 하드코딩되어 있어 운영자가 `.env`에서 `TEMPO_RETENTION_DAYS`를 변경할 경우 Tempo Compactor 보존 기간과 S3 Lifecycle 삭제 시점이 불일치하게 된다. / 해결책: `scripts/deploy-all.sh`에서 `TEMPO_RETENTION_DAYS`의 양의 정수 검증 후 파생 변수(예: `TEMPO_RETENTION_HOURS="$((TEMPO_RETENTION_DAYS * 24))h"`)로 `tempo-values.yaml`의 `retention`을 렌더링하거나, 두 설정이 항상 일치하도록 구성할 것.

배포 가능 여부: No
