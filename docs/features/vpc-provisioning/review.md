## Review Round 1 — 2026-10-26 (대상 커밋: 03edf81)

### Critical
- 지적 사항 없음.

### High
- [ ] `scripts/nat-stop.sh:58` — EIP 해제 대상이 삭제한 NAT의 주소가 아니라 서울 리전 전체의 `Project=petclinic` 미연결 주소다. 선택한 VPC 외부에서 쓰거나 교체·복구를 위해 예약해 둔 같은 프로젝트의 EIP도 NAT 존재 여부와 무관하게 반납하며, 해제한 공인 IP는 복구가 보장되지 않는다. 삭제 대상 NAT의 `NatGatewayAddresses[].AllocationId`를 삭제 전에 수집해 그 주소만 해제하고, 실패한 생성 작업의 잔여 EIP 정리가 필요하면 NAT 전용 Name 태그 등으로 별도 제한해야 한다. 같은 Project의 비NAT 미연결 주소를 남겨 두는 회귀 테스트를 추가한다.

### Medium / Low
- [ ] `infra/aws/provision-aws-resources.sh:148` — `rt_pub=$(vpc_route_table ...)` 등 명령 치환 안에서는 기본 Bash의 `errexit`가 해제되어, `describe-route-tables` 실패가 빈 조회 결과로 처리된다. 실제 함수에 조회만 exit 42로 실패하는 모의 `aws` 셸 함수를 주입하자 `create-route-table`이 호출되고 `result=rtb-created status=0`으로 종료됐다. 일시적 조회 실패나 Describe 권한 누락 시 기존 테이블 대신 중복 테이블을 만들어 멱등성 계약을 깨뜨리며, 생성 실패도 마지막 `echo`가 숨길 수 있다. 조회·생성 각각의 실패를 `|| return` 등으로 명시적으로 전달하고, 조회 실패 시 생성·연결 호출이 없고 전체 실행이 실패하는 테스트를 추가한다.

### 기존 아키텍처와의 정합성
- 별도 지적 사항 없음. 기존 `docs/architecture.md` §1의 일일 중지 시 NAT 삭제·재생성 제외는 이번 설계 §1.2 및 §3에서 선택적 NAT 관리로 확장한 것으로 판단한다. 기본 daily 실행이 NAT를 유지하고, `--start-nat`가 RDS·노드 시작보다 먼저 실행되는 동작을 확인했다. 아키텍처 문서의 범위·구성 요소·디렉터리 갱신은 설계 §7에 예정된 ⑦ 단계에서 반영하면 된다.

### 검증
- `git diff master...HEAD` 전체 변경을 검토했다. 이 비교에는 이전 기능(RDS 8.4, 대시보드, AZ 분산, graceful shutdown, Grafana 공개 경로) 변경도 포함되어 있으며 현재 아키텍처 및 해당 기능의 기존 리뷰 기록과 대조했다.
- `bash tests/scripts/vpc-provisioning.test.sh`: 16개 사례 통과.
- `bash scripts/validate-manifests.sh`: 전체 오프라인 스크립트 테스트 및 YAML 46개·워크로드 6개 검증 통과.
- 모의 셸 함수로 조회 실패 후 라우트 테이블 생성 문제를 추가 재현했다. 실제 AWS 호출은 실행하지 않았다.
- 이번 기능의 기존 review.md는 없어 이전 라운드 재확인 대상이 없다. 공개 저장소 실값 노출 관련 추가 지적 사항은 발견하지 못했다.

### 총평
정상 생성·재실행·NAT 연계 경로의 오프라인 검증은 통과했으나, NAT와 무관한 EIP 반납을 막고 조회 실패를 전파하는 처리가 필요하다. High 항목 해결 후 재검토한다.

머지 가능 여부: No
