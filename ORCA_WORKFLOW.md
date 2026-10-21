# Orca 역할 분담 워크플로

## 0. 최초 1회 준비
1. `CLAUDE.md`, `AGENTS.md`, 이 파일을 저장소 루트(master)에 넣고 커밋한다.
   → 이후 만드는 모든 worktree가 이 파일들을 물려받는다.
2. `docs/` 폴더를 만들어 둔다.

```bash
mkdir -p docs && git add CLAUDE.md AGENTS.md ORCA_WORKFLOW.md docs && git commit -m "docs: agent role setup"
```

## 1. 기능 하나 = worktree 하나
Orca에서 기능용 worktree를 **하나만** 만들고, 그 안에 탭 3개를 연다: Antigravity / Claude / Codex.
(기존처럼 에이전트마다 worktree를 따로 만들면 서로의 코드를 못 본다.)

## 2. 단계별 실행 — 아래 프롬프트를 각 탭에 붙여넣기

### ① Antigravity — 설계
```
너는 이 저장소의 아키텍처·환경 설계 담당이다. 소스 코드는 수정하지 않는다.
요구사항: <여기에 기능 설명>

docs/design.md 를 작성해라. 포함할 항목:
1. 목표와 범위 (하지 않을 것 포함)
2. 구성 요소와 디렉터리 구조
3. 데이터 흐름 / API 또는 인터페이스
4. 실행 환경 (런타임 버전, 컨테이너/클라우드 리소스, 환경변수 목록 — 값은 쓰지 말 것)
5. 보안 요구사항 (인증, 권한 최소화, 시크릿 관리 방식)
6. 구현 단계 체크리스트 (Claude가 순서대로 따라갈 수 있게)
7. "## 구현 중 질문" 빈 섹션
작성 후 커밋: "docs: design for <기능명>"
```

### ② Claude — 구현
```
docs/design.md 를 읽고 구현 단계 체크리스트 순서대로 구현해라. 단계마다 커밋해라.
```

### ③ Codex — 코드 리뷰
review.md에 써야 하므로 `--sandbox read-only`는 쓰지 않는다. 기본 모드로 실행하고, 아래 프롬프트로 쓰기 범위를 제한한다.
```
AGENTS.md 의 리뷰어 규칙을 따라라.
git diff master...HEAD 를 리뷰하고 docs/review.md 에 새 라운드를 추가해라.
소스 코드는 수정하지 마라. 작성 후 커밋: "docs: review round N"
```

### ④ Antigravity — 보안·환경 점검
```
너는 보안·인프라 점검 담당이다. 소스 코드는 수정하지 않는다.
git diff master...HEAD 와 docs/design.md 를 기준으로 점검하고 docs/security.md 에 새 라운드를 추가해라.

점검 항목:
- 시크릿/자격증명 하드코딩, .env 커밋 여부
- IAM/권한 과다 부여, 최소 권한 원칙 위반
- 네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)
- 입력 검증 누락 (인젝션, 경로 조작, SSRF)
- 의존성 취약점, 고정되지 않은 버전
- Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)
- design.md 의 보안 요구사항 준수 여부

형식: Critical / High / Medium / Low 별로 "- [ ] 파일:줄 — 문제 / 해결책"
마지막에 "배포 가능 여부: Yes / No" 한 줄.
작성 후 커밋: "docs: security round N"
```

### ⑤ Claude — 피드백 반영
```
docs/review.md 와 docs/security.md 의 최신 라운드에서 [ ] 항목을 처리해라.
CLAUDE.md 의 피드백 반영 규칙을 따라라.
```

### ⑥ 반복 / 종료
- Critical·High가 남아 있으면 ③~⑤ 반복
- 두 문서 모두 "Yes"가 되면 Orca 소스 컨트롤에서 diff 최종 확인 후 master에 머지

## 팁
- 각 단계가 끝나면(사이드바에 Done 표시) 다음 탭으로 넘어간다.
- 탭 간 전달은 오직 `docs/*.md` 파일로 한다. 에이전트끼리 직접 대화하지 않는다.
- Orca 에이전트 권한은 처음엔 "수동"으로 두고, 흐름이 익숙해지면 Auto로 올린다.
