# 보안 및 인프라 점검 결과 (`docs/features/landing-page/security.md`)

## Security Round 1 — 2026-10-27 (대상 커밋: 0c70b54)

점검 범위: `git diff master...HEAD` 전체(`docker/was/Dockerfile`, `docker/was/server.xml`, `docker/web/Dockerfile`, `docker/web/nginx.conf`, `docker/web/static/*`, `infra/aws/provision-aws-resources.sh`, `infra/aws/waf-staff-403.html`, `k8s/was/deployment-stable.yaml`, `k8s/was/deployment-canary.yaml`, `scripts/deploy-all.sh`, `scripts/lib.sh`, `scripts/validate-manifests.sh`, `tests/scripts/grafana-waf-ready.test.sh`, `app/src/main/webapp/WEB-INF/jsp/pets/*`, `docs/daily/2026-10-27.md`, `docs/features/landing-page/design.md`, `docs/features/landing-page/review.md`), `docs/architecture.md` 보안 구조(§7) 및 `docs/features/landing-page/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 안전하게 제외되어 있으며, 신규 커밋에 하드코딩된 API Key, DB 패스워드, AWS 자격증명 없음. DB 암호는 Kubernetes Secret `petclinic-rds-secret`의 `secretKeyRef` 방식을 유지함).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 보완 필요 (12자리 AWS 계정 ID, 실존 IAM/WAF ARN의 노출은 없으나, `docs/features/landing-page/design.md:12`에 실제 서비스 도메인 실값 `petclinix.cloud`가 하드코딩되어 노출됨. 또한 공개 데모 랜딩 페이지 `docker/web/static/index.html:119, 150`의 이메일 주소에도 동일 도메인이 기재되어 있음).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 IAM 역할이나 과다 권한 생성 없음. WAF IPSet 및 NGF 라우팅을 통해 인가된 IP만 내부 직원용 애플리케이션에 도달하도록 통제함).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 양호 (AWS WAF 최우선순위(Priority 0)에 `BlockUnauthorizedStaffAccess` 규칙을 배치하여 비인가 IP의 `/grafana*` 및 `/was*` 접근을 AWS 엣지에서 HTTP 403으로 원천 차단함. 루트 경로(`/`) 및 정적 에셋(`/resources/`, `/webjars/`, `/css/`)만 Nginx가 직접 서빙하여 외부에 공개됨. 다만 엣지 403 응답에 웹 보안 헤더 보완이 권장됨).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 보완 필요 (WAF 규칙 생성부에서는 `URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE` 3단계 텍스트 변환 파이프라인을 정상 적용하여 `%2fwas`, `/./was`, `/WAS` 등의 인코딩/경로 조작 우회를 차단하도록 구성했으나, `scripts/lib.sh`의 배포 전 WAF 검증 게이트 `staff_waf_ready`에서 `LOWERCASE` 누락 및 변환 우선순위 검증이 빠져 있어 취약한 WAF 규칙이 게이트를 통과할 수 있는 결함이 존재함).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (Tomcat `11.0.2-jdk21-temurin-noble`, Maven `3.9.9-eclipse-temurin-21`, Nginx `1.27.2-alpine`, JMX Exporter `1.0.1` 등 특정 고정 태그 및 SHA256 체크섬을 사용하며 `latest` 태그 미사용).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 양호 (Web 및 WAS 컨테이너 모두 UID 10001 비루트 전용 계정으로 구동되며, K8s 매니페스트 상 `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` 보안 컨텍스트 강제 적용됨. 단, WAS `server.xml` 상의 불필요한 종료 포트 및 동적 배포 설정에 대한 강화 권고).
- **design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부**: 보완 필요 (`RemoteIpValve`의 `internalProxies`를 사설 IP 대역(`10.0.0.0/16` 등)으로 제한하여 외부 헤더 위조를 차단한 점, Web Nginx에서 `X-Forwarded-Proto https` 및 `X-Forwarded-Port 443`을 명시 주입하여 302 Location의 `http://` 다운그레이드 문제를 해결한 점 등은 우수하나, `scripts/deploy-all.sh`에서 사용자 및 설계와 합의된 "stable web 선적용 후 stable WAS 적용" 순서를 지키지 않고 동시 배포하여 재배포 시 공개 `/` 서비스가 404로 깨지는 가용성 결함이 존재함).

---

### Critical
지적 사항 없음.

### High
- [ ] `docs/features/landing-page/design.md:12` — **설계 문서 내 실제 서비스 도메인 실값 노출.** `docs/features/landing-page/design.md:12` 배경 설명에 실제 프로덕션 서비스 도메인(`petclinix.cloud`)이 하드코딩되어 있다(`현재 petclinix.cloud의 루트 경로(/)에...`). `architecture.md` 및 프로젝트 표준에 맞추어 `${DOMAIN_NAME}` 플레이스홀더로 교체해야 한다. 아울러 공개 정적 페이지인 `docker/web/static/index.html:119, 150`의 이메일 주소(`contact@petclinix.cloud`, `privacy@petclinix.cloud`) 역시 실제 도메인이 노출되지 않도록 RFC 2606 예약 도메인(예: `example.com` 또는 `${DOMAIN_NAME}`)으로 교체할 것을 권고한다.
- [x] (4237983) `scripts/deploy-all.sh:154-158` — **배포 순서 역전에 따른 무중단 가용성 훼손 (설계 합의 Q2 위반).** 기존 `web`은 `/` 요청을 WAS(`:8080`)로 프록시한다. `deploy-all.sh` 154~155행에서 WAS와 web 매니페스트를 동시에 적용하고 156행에서 `deploy/was-stable`의 롤아웃을 먼저 대기하도록 되어 있는데, 새 `was-stable`이 먼저 준비될 경우 Tomcat에는 `/was` 컨텍스트만 존재하므로 기존 `web`을 통해 들어오는 공개 메인(`/`) 요청이 일시적으로 404를 반환하며 대외 서비스 중단이 발생한다. `design.md` §7.1 및 Q2에서 합의된 절차대로 "stable `web` 매니페스트 적용 및 롤아웃 대기 완료 후 stable `was` 매니페스트를 적용"하도록 배포 순서를 엄격히 분리해야 한다.

### Medium
- [x] (4237983) `scripts/lib.sh:62` — **배포 전 WAF 게이트(`staff_waf_ready`)의 텍스트 변환 검증 불완전.** `staff_waf_ready` 내 `contains(["URL_DECODE", "NORMALIZE_PATH"])` 로직은 텍스트 변환의 단순 포함 여부만 확인할 뿐, 대소문자 우회 차단을 위한 `LOWERCASE` 변환 존재 여부와 `Priority` 순서(0: `URL_DECODE` -> 1: `NORMALIZE_PATH` -> 2: `LOWERCASE`)를 검증하지 않는다. 만약 WAF 규칙에서 `LOWERCASE`가 누락되거나 변환 순서가 뒤바뀐 채 적용되더라도 배포 게이트를 통과하여 WAF 우회 공격에 노출될 위험이 있다. `TextTransformations`의 우선순위 및 3개 변환 항목이 설계와 완벽히 일치하는지 엄격히 검증하도록 jq 조건을 강화하고, `tests/scripts/grafana-waf-ready.test.sh`에 관련 실패 검증 케이스를 추가해야 한다.
- [x] (4237983) `infra/aws/provision-aws-resources.sh:550-551` — **WAF 엣지 403 차단 응답에 클릭재킹 및 MIME 스니핑 방지 보안 헤더 누락.** WAF Priority 0 규칙 `BlockUnauthorizedStaffAccess`의 `CustomResponse`에 `Cache-Control: no-store`만 설정되어 있다. WAF 엣지에서 생성되는 403 응답은 내부 Web Nginx를 거치지 않으므로 Nginx의 보안 헤더(`X-Frame-Options`, `X-Content-Type-Options`)가 적용되지 않는다. 비인가 접근 차단 화면이 타 사이트의 iframe 등에 삽입되거나 악용되지 않도록 WAF `CustomResponse.ResponseHeaders`에 `X-Frame-Options: DENY` 및 `X-Content-Type-Options: nosniff`를 추가할 것을 권고한다.

### Low
- [x] (4237983) `docker/was/server.xml:6` — **Tomcat 컨테이너 불필요한 TCP 종료 포트(8005) 활성화.** 컨테이너 및 쿠버네티스 환경에서는 프로세스 수명주기를 SIGTERM/SIGKILL 신호로 제어하므로 로컬 TCP 8005 포트 리스너가 불필요하다. 로컬 루프백(`127.0.0.1:8005`)에 기본 종료 문자열 `"SHUTDOWN"`이 수신 대기 상태로 남아 있으면, 동일 Pod 네트워크 네임스페이스 내 사이드카나 프로세스를 통한 의도치 않은 WAS 종료 리스크가 존재한다. `<Server port="-1" shutdown="SHUTDOWN">`으로 설정하여 TCP 종료 포트를 비활성화하는 CIS Tomcat 하드닝 권고를 적용할 것을 제안한다.
- [x] (4237983) `docker/was/server.xml:33` — **운영 환경 Tomcat `autoDeploy="true"` 활성화.** `readOnlyRootFilesystem: true`로 구동되는 불변 컨테이너 환경에서 런타임 디렉터리 동적 스캔 및 자동 배포(`autoDeploy="true"`)는 불필요한 파일시스템 감시 오버헤드를 발생시키고 잠재적인 불안정성을 야기할 수 있다. 프로덕션 환경에 맞게 `autoDeploy="false"` 및 `deployOnStartup="true"`로 명시적 고정을 권고한다.
- [x] (4237983) `infra/aws/provision-aws-resources.sh:527` — **WAF IPSet 설명 문구 리소스 범위 불일치.** `provision-aws-resources.sh`의 `create-ip-set` 실행 시 `--description "Allowed source IPs for /grafana"`로 작성되어 있으나, 현재 해당 IPSet은 `/grafana`와 `/was` 공용 직원 인가 IP 대역으로 기능이 확장되었다. 운영상 혼선을 방지하기 위해 `--description "Allowed source IPs for /grafana and /was staff access"`로 갱신을 제안한다.

---

### 총평
병원 공개 랜딩 페이지 도입 및 직원용 PetClinic WAS(`/was/`) 격리 아키텍처는 AWS WAFv2 최우선순위(Priority 0) 차단 규칙, 403 사용자 지정 응답, Tomcat `RemoteIpValve`와 Nginx 역방향 프록시 헤더 제어를 통해 전반적으로 우수한 다층 방어 체계를 갖추고 있다. 또한 민감 자격증명의 하드코딩이나 과다한 권한 부여는 발견되지 않았다.  
그러나 **(1) 설계 문서 내 실제 서비스 도메인 실값 노출** 및 **(2) 재배포 시 메인 페이지(`/`) 일시 중단을 유발하는 `deploy-all.sh`의 배포 순서 역전 결함**이 존재하므로, 해당 High 항목들에 대한 보완 조치가 완료되기 전까지는 프로덕션 배포가 불가하다.

배포 가능 여부: No
