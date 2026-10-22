# Orca 역할 분담 워크플로

## 문서 구조
```
docs/
├── architecture.md          ← 시스템 전체 현황 (현재 master 기준, 계속 갱신)
└── features/
    └── <기능명>/
        ├── design.md         ← 기능별 설계
        ├── review.md         ← 코드 리뷰 라운드 기록
        └── security.md       ← 보안·환경 점검 라운드 기록
```
- **전체 구조를 보려면 `docs/architecture.md`** 를 본다.
- 특정 기능이 왜 그렇게 만들어졌는지는 `docs/features/<기능명>/` 을 본다.
- 기능별 문서는 폴더로 분리되어 있어 머지해도 서로 덮어쓰지 않는다.

## 0. 최초 1회 준비
1. `CLAUDE.md`, `AGENTS.md`, 이 파일을 저장소 루트(master)에 넣는다.
   → 이후 만드는 모든 worktree가 이 파일들을 물려받는다.
2. `CLAUDE.md` 와 `AGENTS.md` 맨 위에 다음 한 줄을 추가한다:
   ```
   작업 전에 docs/architecture.md 를 읽고 전체 구조와 일관되게 판단한다.
   ```
3. `docs/features/` 폴더를 만들고 커밋한다.
   ```bash
   mkdir -p docs/features && touch docs/features/.gitkeep
   git add CLAUDE.md AGENTS.md ORCA_WORKFLOW.md docs
   git commit -m "docs: agent role setup"
   ```
4. 초기 `docs/architecture.md` 를 만든다. master에서 Antigravity 탭을 열고:
   ```
   너는 이 저장소의 아키텍처 담당이다. 소스 코드는 수정하지 않는다.
   현재 저장소 전체를 읽고 docs/architecture.md 를 작성해라.
   (코드가 아직 없으면 프로젝트 목표와 빈 섹션만 만든다.)

   형식:
   # 아키텍처
   ## 1. 개요 — 시스템 목적과 범위
   ## 2. 구성 요소 — 각 컴포넌트의 역할
   ## 3. 디렉터리 구조
   ## 4. 데이터 흐름 — Mermaid 다이어그램
   ## 5. 실행 환경 — 런타임, 컨테이너/클라우드 리소스, 환경변수 목록 (값은 쓰지 말 것)
   ## 6. 외부 의존성 — 외부 API, DB, 서비스
   ## 7. 보안 구조 — 인증, 권한, 시크릿 관리 방식
   ## 8. 설계 결정 기록 — "- <기능명>: 결정 / 이유" 한 줄씩

   작성 후 커밋: "docs: initial architecture"
   ```

## 1. 기능 하나 = worktree 하나
Orca에서 기능용 worktree를 **하나만** 만들고, 그 안에 탭 3개를 연다: Antigravity / Claude / Codex.
(에이전트마다 worktree를 따로 만들면 서로의 코드를 못 본다.)

아래 프롬프트의 `<기능명>` 은 영문 kebab-case로 통일한다. (예: `user-login`)

## 2. 단계별 실행 — 아래 프롬프트를 각 탭에 붙여넣기

### ① Antigravity — 설계
```
너는 이 저장소의 아키텍처·환경 설계 담당이다. 소스 코드는 수정하지 않는다.
먼저 docs/architecture.md 를 읽고 기존 구조와 일관되게 설계해라.
기존 구조를 바꿔야 한다면 그 이유를 설계서에 명시해라.

기능명: <기능명>
요구사항: <여기에 기능 설명>

docs/features/<기능명>/design.md 를 작성해라. 포함할 항목:
1. 목표와 범위 (하지 않을 것 포함)
2. 구성 요소와 디렉터리 구조 (기존 구조 대비 추가·변경되는 부분 표시)
3. 데이터 흐름 / API 또는 인터페이스
4. 실행 환경 (런타임 버전, 컨테이너/클라우드 리소스, 환경변수 목록 — 값은 쓰지 말 것)
5. 보안 요구사항 (인증, 권한 최소화, 시크릿 관리 방식)
6. 구현 단계 체크리스트 (Claude가 순서대로 따라갈 수 있게)
7. "## 구현 중 질문" 빈 섹션
작성 후 커밋: "docs: design for <기능명>"
```

### ② Claude — 구현
```
docs/architecture.md 와 docs/features/<기능명>/design.md 를 읽고
구현 단계 체크리스트 순서대로 구현해라. 단계마다 커밋해라.
```

### ③ Codex — 코드 리뷰
review.md에 써야 하므로 `--sandbox read-only`는 쓰지 않는다. 기본 모드로 실행하고, 아래 프롬프트로 쓰기 범위를 제한한다.
```
AGENTS.md 의 리뷰어 규칙을 따라라.
docs/architecture.md 와 docs/features/<기능명>/design.md 를 기준으로
git diff master...HEAD 를 리뷰하고 docs/features/<기능명>/review.md 에 새 라운드를 추가해라.
기존 아키텍처와 어긋나는 부분이 있으면 별도 항목으로 지적해라.
소스 코드는 수정하지 마라. 작성 후 커밋: "docs: review round N for <기능명>"
```

### ④ Antigravity — 보안·환경 점검
```
너는 보안·인프라 점검 담당이다. 소스 코드는 수정하지 않는다.
git diff master...HEAD, docs/architecture.md, docs/features/<기능명>/design.md 를 기준으로 점검하고
docs/features/<기능명>/security.md 에 새 라운드를 추가해라.

점검 항목:
- 시크릿/자격증명 하드코딩, .env 커밋 여부
- IAM/권한 과다 부여, 최소 권한 원칙 위반
- 네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)
- 입력 검증 누락 (인젝션, 경로 조작, SSRF)
- 의존성 취약점, 고정되지 않은 버전
- Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)
- design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부

형식: Critical / High / Medium / Low 별로 "- [ ] 파일:줄 — 문제 / 해결책"
마지막에 "배포 가능 여부: Yes / No" 한 줄.
작성 후 커밋: "docs: security round N for <기능명>"
```

### ⑤ Claude — 피드백 반영
```
docs/features/<기능명>/review.md 와 docs/features/<기능명>/security.md 의
최신 라운드에서 [ ] 항목을 처리해라.
CLAUDE.md 의 피드백 반영 규칙을 따라라.
```

### ⑥ 반복 판단
- Critical·High가 남아 있으면 ③~⑤ 반복
- review.md 와 security.md 모두 "Yes"가 되면 ⑦로 넘어간다

### ⑦ Antigravity — 아키텍처 문서 갱신 (머지 직전)
```
너는 아키텍처 담당이다. 소스 코드는 수정하지 않는다.
docs/features/<기능명>/design.md 와 git diff master...HEAD 를 읽고,
이번 기능이 반영된 상태로 docs/architecture.md 를 갱신해라.
- 구성 요소, 디렉터리 구조, 데이터 흐름(Mermaid), 실행 환경, 외부 의존성, 보안 구조를
  현재 코드 기준으로 맞춘다
- 이번 변경으로 틀려진 기존 내용은 수정한다 (변경 이력은 쓰지 않는다)
- "## 8. 설계 결정 기록"에 이번 기능의 주요 결정과 이유를 한 줄씩 추가한다
- design.md 와 실제 구현이 다른 부분은 실제 구현을 기준으로 쓴다
작성 후 커밋: "docs: update architecture for <기능명>"
```

### ⑧ 머지
Orca 소스 컨트롤에서 코드 diff와 `docs/architecture.md` 변경분을 함께 확인한 뒤 master에 머지한다.

## 팁
- 각 단계가 끝나면(사이드바에 Done 표시) 다음 탭으로 넘어간다.
- 탭 간 전달은 오직 `docs/` 아래 md 파일로 한다. 에이전트끼리 직접 대화하지 않는다.
- `architecture.md` 는 ⑦에서만 수정한다. 다른 단계에서 고칠 게 보이면 해당 기능의 design.md나 review.md에 적어 둔다.
- 기능 여러 개를 동시에 진행하면 `architecture.md` 머지 충돌이 날 수 있다. 먼저 머지된 기능 뒤에 오는 worktree는 master를 rebase한 다음 ⑦을 실행한다.
- Orca 에이전트 권한은 처음엔 "수동"으로 두고, 흐름이 익숙해지면 Auto로 올린다.
