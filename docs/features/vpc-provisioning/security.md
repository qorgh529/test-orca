# 보안 및 인프라 점검 결과 (`docs/features/vpc-provisioning/security.md`)

## Security Round 1 — 2026-10-26 (대상 커밋: 348e521)

점검 범위: `git diff master...HEAD` 전체(`.gitignore`, `README.md`, `docs/daily/2026-10-26.md`, `docs/features/vpc-provisioning/design.md`, `docs/features/vpc-provisioning/review.md`, `infra/aws/provision-aws-resources.sh`, `scripts/daily-start.sh`, `scripts/daily-stop.sh`, `scripts/nat-start.sh`, `scripts/nat-stop.sh`, `scripts/validate-manifests.sh`, `tests/scripts/daily-stop-start.test.sh`, `tests/scripts/vpc-provisioning.test.sh` 및 마스터 대비 누적 변경분), `docs/architecture.md` 보안 구조(§7), `docs/features/vpc-provisioning/design.md` 보안 요구사항(§1.2, §3.3~3.5, §5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env`는 `.gitignore`에 등록되어 제외되어 있으며, 새로 추가된 `docs/report/`도 `.gitignore`에 등록되어 증빙 자료 및 로컬 결과물이 추적되지 않음. 신규 셸 스크립트 및 테스트 코드 내 시크릿/비밀번호 하드코딩 없음).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 이상 없음 (`docs/daily/2026-10-26.md`, `README.md`, `design.md`, `review.md` 모두 12자리 AWS 계정 ID, 실존 IAM ARN, 개인 URL 실값 노출 없음. `design.md` §5.4에 명시된 사용자 승인 "도메인 공개 예외(Domain Disclosure Exception)" 원칙에 따라 개요 다이어그램 외 모든 파일에서 플레이스홀더 사용 규칙이 철저히 준수됨).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 이상 없음 (`petclinic-rt-db` 라우트 테이블에는 외부 인터넷 경로(`0.0.0.0/0`)를 일체 등록하지 않아 DB 프라이빗 서브넷 완전 격리(Air-Gapped) 원칙을 준수함. `petclinic-rt-app-2a/2c`는 퍼블릭 인입 없이 오직 해당 AZ의 NAT Gateway(`petclinic-nat-2a/2c`)를 통한 아웃바운드 인터넷 경로만 설정됨. 퍼블릭 서브넷 2a/2c만 IGW(`petclinic-igw`)로 연결됨).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 아래 Medium 1건 확인 (`design.md` §5.1에 `ec2:DescribeInstances` 누락).
- **리소스 제어 및 자산 영구 파괴 위험 (Blast Radius)**: 아래 High 1건 확인 (`nat-stop.sh`의 광범위한 EIP 반납).
- **오류 처리 및 입력/멱등성 검증**: 아래 Medium 1건, Low 2건 확인.

### Critical
지적 사항 없음.

### High
- [x] `scripts/nat-stop.sh:58-62` — EIP 해제 시 삭제 대상 NAT Gateway에 연결되어 있던 Elastic IP(`NatGatewayAddresses[].AllocationId`)로 범위를 한정하지 않고, `ap-northeast-2` 리전 전체에서 `Name=tag:Project,Values=petclinic` 태그가 붙은 모든 미연결 Elastic IP(`Addresses[?AssociationId==null]`)를 순회하며 반납(`release-address`)한다. 또한 NAT 게이트웨이가 존재하지 않는 경우(`nats`가 비어있는 상태)에도 EIP 해제 루프를 건너뛰지 않고 무조건 실행한다. 동일 프로젝트 내 다른 서비스(예: 배스천 호스트, DR 대기용 EIP, VPC 외부 연동용 고정 공인 IP 등)가 일시적으로 인스턴스와 연결 해제되어 있는 경우, `nat-stop.sh` 실행 시 해당 공인 IP가 AWS 퍼블릭 풀로 영구 반납되어 복구가 불가능해지며, 외부 방화벽 화이트리스트나 DNS 설정이 파괴되어 서비스 거부(DoS)를 유발할 수 있다. / 해결책: 삭제 대상 NAT Gateway를 삭제하기 전에 각 NAT의 `NatGatewayAddresses[].AllocationId`를 미리 수집하여 해당 ID 목록만 `release-address`하도록 제한하고, NAT 게이트웨이가 없는 경우 EIP 해제 단계를 조기 종료하거나, 부득이하게 실패한 생성 작업의 잔여 EIP를 정리해야 할 경우 `Name=petclinic-nat-2a`, `Name=petclinic-nat-2c` 전용 Name 태그로 엄격히 한정할 것. 비NAT 미연결 EIP가 보존되는 오프라인 회귀 테스트도 추가할 것. — `fc1114e`

### Medium
- [x] `infra/aws/provision-aws-resources.sh:143-152` — `rt_pub=$(vpc_route_table "$vpc_id" "$p-rt-public")` 등 명령어 치환 `$(...)` 서브셸 내부에서는 부모 셸의 `set -e`(`errexit`) 상속이 기본적으로 해제된다. 따라서 `vpc_route_table` 내부에서 `aws ec2 describe-route-tables` 실행 시 IAM 권한 부족, 일시적 네트워크 장애, API Throttling 등으로 실패하더라도 빈 문자열(`""`)로 처리되어 `if [ -z "$id" ]` 조건이 참(True)으로 평가된다. 이로 인해 이미 존재하는 라우트 테이블을 재사용하지 못하고 신규 생성을 시도하게 되며, 생성마저 실패할 경우 빈 라우트 테이블 ID가 반환되어 후속 `vpc_default_route` 및 `vpc_associate`가 빈 문자열(`""`)을 대상으로 실행되면서 치명적인 AWS CLI 파라미터 에러를 유발하고 프로비저닝 멱등성이 깨진다. / 해결책: 스크립트 상단에 `shopt -s inherit_errexit`를 설정하거나, `vpc_route_table` 함수 내에서 `aws ec2 describe-route-tables` 실행 실패 시 exit code를 확인하여 명시적으로 `return 1`하도록 에러 전파 처리를 추가할 것. 또한 라우트 테이블 ID가 비어있는 상태로 후속 함수가 호출되지 않도록 방어 검증을 추가할 것. — `fc1114e`
- [x] `docs/features/vpc-provisioning/design.md:327-336` — `scripts/nat-stop.sh:30`에서는 VPC 내 실행 중인 EC2 인스턴스를 점검하여 노드 아웃바운드 인터넷 단절을 방지하기 위해 `aws ec2 describe-instances`를 호출한다. 그러나 `docs/features/vpc-provisioning/design.md` §5.1(IAM 최소 권한 원칙)의 작업 허용 목록에는 `ec2:DescribeInstances`가 누락되어 있다. 만약 설계서에 명시된 권한만을 부여한 IAM Role/User로 운영 환경에서 `nat-stop.sh` 또는 `daily-stop.sh --stop-nat`을 실행할 경우, `ec2:DescribeInstances` 호출 시 `UnauthorizedOperation` / `AccessDenied` 에러가 발생하며 스크립트가 비정상 종료된다. / 해결책: `docs/features/vpc-provisioning/design.md` §5.1의 허용 권한 목록에 `ec2:DescribeInstances`를 명시적으로 추가하여 최소 권한 명세와 실제 코드의 권한 요구사항을 일치시킬 것. — (이 커밋)

### Low
- [x] `scripts/daily-stop.sh:148-152` — `daily-stop.sh`는 관리형 노드그룹 업데이트 축소 요청(`wait_update`)이 완료된 직후 `nat-stop.sh`를 호출한다. 하지만 EKS 관리형 노드그룹의 업데이트 완료 시점과 실제 EC2 인스턴스 종료(`Terminating` → `Terminated`) 완료 시점 간에는 수 초에서 수 분의 시차가 존재한다. 이 시차로 인해 `nat-stop.sh:28-35`의 실행 중 인스턴스 검증(`pending,running,stopping`)에 걸려 `exit 1`로 실패하게 되며, `daily-stop.sh` 전체가 비정상 종료되어 마지막 비용 절감 및 운영 안내(`notice()`)가 출력되지 못한다. / 해결책: `nat-stop.sh`에서 인스턴스가 존재할 경우 즉시 실패하기보다는 짧은 대기 루프(예: 최대 60~120초간 인스턴스 종료 폴링)를 두거나, `daily-stop.sh`에서 노드 인스턴스 완전 종료를 확인한 후 `nat-stop.sh`를 호출하도록 보완할 것. — `fc1114e`
- [x] `scripts/nat-stop.sh:58` — `for a in $(aws ec2 describe-addresses ...)` 구문에서 `aws ec2 describe-addresses` 호출이 네트워크 오류나 일시적 장애로 실패하더라도, Bash의 `for` 문 명령어 치환 특성상 `set -e`가 트리거되지 않고 루프를 무시한 채 통과한다. 결과적으로 실제 주소 반납이 전혀 수행되지 않았음에도 스크립트 마지막의 `echo "NAT gateways stopped"`가 정상 출력되어 운영자에게 잘못된 상태를 전달할 수 있다. / 해결책: `addrs=$(aws ec2 describe-addresses ...)`로 사전 변수 할당을 분리하여 `describe-addresses`의 실패가 `set -e`에 의해 즉시 포착되도록 개선할 것. — `fc1114e`

### 총평
VPC 10.0.0.0/16 및 서브넷 6개, IGW, 라우트 테이블 4개의 프로비저닝 로직은 서울 리전 고정 및 태그 기반 멱등성을 갖추고 있으며, DB 서브넷에 인터넷 경로를 배제하여 Air-Gapped 격리를 준수했다. 그러나 NAT Gateway 삭제 시 서울 리전 내 동일 프로젝트의 모든 미연결 Elastic IP를 무차별 반납하여 타 서비스의 공인 IP 자산 유실 및 DoS를 유발할 수 있는 High 보안/운영 결함과, 라우트 테이블 조회 실패 시 errexit 누락으로 인한 멱등성 훼손 및 IAM 최소 권한 명세 누락이 존재하므로 해당 항목 수정 후 재검토가 필요하다.

배포 가능 여부: No
