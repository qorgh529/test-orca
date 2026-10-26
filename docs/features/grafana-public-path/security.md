# 보안 및 인프라 점검 결과 (`docs/features/grafana-public-path/security.md`)

## Security Round 1 — 2026-10-26 (대상 커밋: dc9e471)

점검 범위: `git diff master...HEAD` 전체(`docs/daily/2026-10-26.md`, `docs/features/grafana-public-path/design.md`, `docs/features/grafana-public-path/review.md`, `.env.example`, `README.md`, `infra/aws/provision-aws-resources.sh`, `k8s/gateway/gateway.yaml`, `k8s/gateway/httproute-grafana.yaml`, `k8s/monitoring/referencegrant-grafana.yaml`, `k8s/monitoring/networkpolicy-grafana.yaml`, `k8s/monitoring/kube-prometheus-values.yaml`, `scripts/deploy-all.sh`, `scripts/lib.sh`, `scripts/validate-manifests.sh`, `tests/scripts/grafana-waf-ready.test.sh` 및 이전 마스터 대비 변경분), `docs/architecture.md` 보안 구조(§7), `docs/features/grafana-public-path/design.md` 보안 요구사항(§1.2, §3.3, §3.4, §5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 안전하게 제외되어 있으며, Grafana 초기 관리자 패스워드는 하드코딩 없이 기존 Secrets Manager(`GRAFANA_ADMIN_SECRET_NAME`)와 ESO 연동 시크릿(`grafana-admin`)을 그대로 사용함. Alertmanager Webhook 또한 Secrets Manager 연동 파일 마운트 방식을 유지함).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md`, `README.md`, `design.md`, `review.md` 모두 12자리 AWS 계정 ID, 실존 IAM/WAF ARN, 실존 도메인 및 개인 URL 노출 없음. CIDR 예시는 RFC 5737 문서 전용 대역 `203.0.113.7/32` 준수).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 IAM 역할이나 과다 권한 부여 없음. Gateway API `ReferenceGrant`는 `nginx-gateway` 네임스페이스의 HTTPRoute가 `monitoring` 네임스페이스의 `kube-prometheus-stack-grafana` Service만을 참조하도록 엄격히 제한하며, Gateway의 `allowedRoutes`도 `petclinic`과 `nginx-gateway` 네임스페이스로만 한정하여 타 네임스페이스의 무단 라우트 바인딩 차단).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (AWS WAFv2 WebACL 최우선순위(Priority 0)에 `BlockUnauthorizedGrafanaAccess` 규칙을 배치하여 `GRAFANA_ALLOWED_CIDRS` IPSet에 포함되지 않은 모든 외부 요청을 AWS 엣지에서 HTTP 403으로 원천 차단함. `deploy-all.sh`에서 배포 전 WAF Priority 0 규칙 존재 여부를 사전 검증(`grafana_waf_ready`)하여 미적용 상태의 Grafana 공개를 원천 차단함. K8s 내부에서는 `networkpolicy-grafana.yaml`을 통해 Grafana Pod(TCP 3000) 인입을 NGF 데이터 플레인 Pod(`petclinic-gateway`)와 Prometheus Pod로만 이중 제한).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 이상 없음 (AWS WAF 규칙에서 `/grafana` 경로 매칭 시 `URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE` 3단계 텍스트 변환을 순차 적용하여 `%67rafana`, `//grafana`, `/./grafana` 등 경로 조작 및 인코딩 우회 공격을 차단함. `provision-aws-resources.sh` 내 `GRAFANA_ALLOWED_CIDRS` 파싱 시 엄격한 IPv4 CIDR 정규식 검증 수행).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (`kube-prometheus-stack` Helm 차트 92.11.0 및 내장 Grafana 14.0.1, Gateway API CRDs v1.6.3 표준 버전 고정 사용, `latest` 태그 미사용).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 이상 없음 (신규 Dockerfile 추가 없음. Grafana 영구 볼륨은 암호화된 `gp3` 스토리지 클래스를 사용하며, Grafana 컨테이너는 기본 비루트(UID 472) 사용).
- **design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부**: 이상 없음 (`design.md` §3.4 Same-Origin 완화 요구사항 준수: `server.serve_from_sub_path = true`를 통한 쿠키 경로 격리(`Path=/grafana/`), `cookie_secure = true`, `cookie_samesite = lax`, `allow_embedding = false` 프레임 임베딩 차단, `allow_sign_up = false` 회원가입 차단, `auth.anonymous.enabled = false` 익명 접근 차단 완비).

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
지적 사항 없음.

### Low
- [x] (12ec3e8) `scripts/validate-manifests.sh:428-433` — **정적 검증 스크립트 내 `cookie_samesite` 누락 검증 보완 제안.** `docs/features/grafana-public-path/design.md` §3.4에서는 동일 출처(Same-Origin) 환경에서 PetClinic과 Grafana 간 교차 사이트 요청 위조(CSRF) 방지를 위해 `cookie_samesite = lax` 설정을 필수 완화책으로 명시하고 있으며, 실제 `k8s/monitoring/kube-prometheus-values.yaml:98`에도 충실히 반영되어 있다. 그러나 `scripts/validate-manifests.sh` Section 12의 `want` 검증 딕셔너리에는 `cookie_secure`, `allow_embedding`, `allow_sign_up`, `auth.anonymous` 등만 포함되어 있고 `("security", "cookie_samesite"): "lax"` 검증이 누락되어 있다. 향후 values 파일 수정 시의 회귀를 방지하기 위해 정적 검증 항목에 추가할 것을 권고한다.
- [x] (12ec3e8) `infra/aws/provision-aws-resources.sh:381` — **`GRAFANA_ALLOWED_CIDRS` 내 공백 포함 시 사용자 편의를 위한 트림 처리 권고.** `provision-aws-resources.sh`의 `grafana_waf()`는 `IFS=',' read -r -a cidrs <<<"${GRAFANA_ALLOWED_CIDRS:-}"`로 파싱 후 정규식 `^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$`으로 각 항목을 검증한다. 만약 운영자가 `.env`에 `1.2.3.4/32, 5.6.7.8/32`와 같이 쉼표 뒤에 공백을 둘 경우, 두 번째 요소에 앞쪽 공백이 남아 유효한 CIDR임에도 오류가 발생하고 종료된다. 엄격한 검증 관점에서는 안전하지만, 운영 편의성을 위해 `${c// /}` 등으로 공백을 제거한 후 검증하는 방어적 처리를 권고한다.

### 총평
Grafana 하위 경로(`/grafana/`) 오픈 작업에 있어 AWS WAFv2 우선순위 0의 IP 차단 규칙(`BlockUnauthorizedGrafanaAccess`)과 `deploy-all.sh`의 배포 전 검증 게이트(`grafana_waf_ready`), 그리고 K8s 내부의 NetworkPolicy(NGF 데이터 플레인 및 Prometheus 인입 전용) 및 Gateway API ReferenceGrant가 결합되어 빈틈없는 다층 방어 체계를 확립했다. 세션 쿠키 격리, HTTPS 강제, CSRF/클릭재킹 방지, 가입 및 익명 접속 차단 등 웹 보안 설정이 설계에 맞게 완벽히 반영되었으며, 자격증명 및 실인프라 식별자 노출이 없으므로 즉시 배포 가능하다.

배포 가능 여부: Yes
