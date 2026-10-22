# 보안 및 인프라 점검 결과 (`docs/features/production-hardening/security.md`)

## Security Round 1 — 2026-10-22 (대상 커밋: 01cfb30)

점검 범위: `git diff master...HEAD` 전체, `docs/architecture.md` 보안 구조(§7), `docs/design.md` 보안 요구사항(§5 및 Step 8–12, Q1–Q6 포함 — 기능별 설계서가 별도로 분리되어 있지 않아 승인된 `docs/design.md` 기준). 기존 `docs/security.md` Round 1–3 완료 항목 재확인 포함.

### Critical
지적 사항 없음.

### High
- [ ] `k8s/monitoring/kube-prometheus-values.yaml:54`, `scripts/lib.sh:15`, `.env.example:57` — Alertmanager 수신처의 `${ALERTMANAGER_WEBHOOK_URL}`(Slack/PagerDuty 등 인증 토큰이 포함된 비밀 Webhook URL)이 Secrets Manager / ESO를 거치지 않고 `envsubst`를 통해 Helm release values 및 Alertmanager 설정에 평문으로 직접 주입되며, `monitoring` 네임스페이스에는 Egress NetworkPolicy가 없어 침해 시 임의의 외부 엔드포인트로 데이터를 유출(Exfiltration)하거나 SSRF에 악용될 수 있다. 이는 `docs/design.md` §5.3(시크릿의 AWS Secrets Manager + ESO 관리 원칙) 및 `docs/architecture.md` §7.4(시크릿 외부화)에 위배된다. / 해결책: Alertmanager Webhook URL을 AWS Secrets Manager(`petclinic/*` 경로)에 저장하고 `monitoring` 네임스페이스의 `ExternalSecret`으로 동기화한 뒤 Alertmanager의 `http_config.authorization` / `url_file`(또는 Secret 마운트/`alertmanagerConfigSecret`)을 통해 주입하도록 변경할 것.

### Medium
- [ ] `scripts/rotate-db-secrets.sh:18`, `scripts/rotate-db-secrets.sh:25` — 시크릿 회전 스크립트에서 `ExternalSecret`의 `.status.refreshTime` 갱신 확인 루프가 30회(60초) 동안 갱신되지 않고 타임아웃되어도 실패 처리 없이 루프를 빠져나가며, 직후 `kubectl wait --for=condition=Ready`는 이전 동기화 시점의 `Ready=True` 상태 때문에 즉시 통과한다. 그 결과 ESO 동기화가 지연되거나 실패한 상태에서 이전(구) 비밀번호로 `db-init` Job(`ALTER USER`)과 `was` 롤링 재시작이 수행되어 DB 비밀번호 불일치 및 인증 장애가 발생할 수 있다. / 해결책: 각 `ExternalSecret`의 `refreshTime >= $now` 갱신 성공 여부를 플래그로 검증하여 30회 내에 갱신되지 않으면 즉시 비정상 종료(`exit 1`)하도록 수정할 것.
- [ ] `scripts/deploy-all.sh:105`, `scripts/deploy-all.sh:107` — `deploy-all.sh`가 카나리 가중치를 `100/0`(`STABLE_WEIGHT=100 CANARY_WEIGHT=0`)으로 차단하기 전에 새 `was`/`web` Deployment(`was-canary`, `web-canary` 포함)를 먼저 적용한다. 이전 배포에서 `90/10` 카나리 라우팅이 활성화된 상태로 재배포를 실행하면, 스모크 검증(`X-Canary: always`)을 통과하기 전인 새 Canary Pod로 실제 사용자 트래픽 10%가 즉시 유입되어 `docs/design.md` Step 10의 카나리 게이팅 보안·가용성 요구사항을 우회한다. / 해결책: `STABLE_WEIGHT=100 CANARY_WEIGHT=0 render_all "$K/gateway" | kubectl apply -f -`를 `render_all "$K/was"` 및 `render_all "$K/web"` 적용보다 먼저 실행하여 카나리 트래픽을 0%로 격리한 뒤 워크로드를 롤아웃할 것.
- [ ] `k8s/was/keda-scaledobject.yaml:29` — `was-stable`용 KEDA `ScaledObject`에는 `fallback: { failureThreshold: 3, replicas: 4 }`가 설정되어 있으나, `was-canary`용 `ScaledObject`에는 `fallback`이 누락되어 있다. 카나리 트래픽(10%)을 처리하는 도중 Prometheus 장애가 발생하면 `was-canary`의 스케일링 보호가 동작하지 않는다. / 해결책: `was-canary` `ScaledObject`에도 적절한 `fallback`(예: `failureThreshold: 3, replicas: 2`)을 설정할 것.

### Low
- [ ] `infra/eksctl/cluster.yaml:57` — `aws-ebs-csi-driver` EKS 애드온의 `version` 필드가 제거되어 버전이 고정되어 있지 않다(`docs/design.md` §4.1 및 §5.4.2 고정 버전 원칙 미준수). 또한 `scripts/deploy-all.sh:43`에서 EKS 1.36으로 상향하면서 `aws-load-balancer-controller`(차트 `1.9.2`), `nginx-gateway-fabric`(`1.5.1`), `kube-prometheus-stack`(`65.8.1`), `metrics-server`(`3.12.2`), `aws-for-fluent-bit`(`0.1.34`)는 구버전 그대로 유지되어 있다(`docs/design.md` Q6 기록 참조). / 해결책: `infra/eksctl/cluster.yaml`의 `aws-ebs-csi-driver`에 EKS 1.36 호환 고정 버전(예: `version: v1.37.0-eksbuild.1` 이상 또는 환경변수 템플릿 `${EBS_CSI_VERSION}`)을 명시하고 `scripts/validate-manifests.sh`에서 EKS 애드온 버전 고정 여부를 검사할 것.

배포 가능 여부: No
