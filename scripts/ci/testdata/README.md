# `scripts/ci/testdata/` — 비밀값 검사기 회귀 테스트 표본

> **이 디렉터리의 "비밀값"은 전부 가짜다. 실제 자격증명이 아니다.**
> **Every "secret" in this directory is fake. None of them are real credentials.**

`scripts/ci/secret-scan.py`(저장소 자체 비밀값 검사기)가 제대로 동작하는지 확인하기 위한
**회귀 테스트 고정 표본**이다. `scripts/ci/test-secret-scan.py`가 이 파일들을 검사기에 넣고
"잡아야 할 줄을 전부 잡는지 / 잡으면 안 되는 줄을 잡지 않는지"를 대조한다.

그래서 이 값들은 **절대 바꾸거나 자리표시자로 치환하면 안 된다.** 치환하는 순간 회귀 테스트가
깨지고, 과거에 실제로 발생했던 미탐지 사례를 다시 막지 못하게 된다.

## 파일

| 파일 | 역할 |
|---|---|
| `fake-secrets-env.txt` | 반드시 탐지돼야 하는 줄 모음 (과거 미탐지 사례 포함) |
| `fake-secrets.env.example` | `.example` 파일이라고 검사를 건너뛰지 않는지 확인 |
| `fake-secrets-masked.txt` | 진짜 비밀값에 `***`·`%s`만 덧붙여 통과시키던 회귀 사례 |
| `fake-public-ip.txt` | 공인 IP 하드코딩 탐지 확인 |
| `clean-placeholders.env.example` | 자리표시자·설정값은 **탐지되면 안 되는** 표본 (오탐 0 확인) |
| `known-limits.txt` | 현재 구현이 못 잡는 사례를 고정. 잡히기 시작하면 테스트가 실패해 문서 갱신을 요구한다 |

각 줄에는 기대값 마커 `[[DETECT]]`가 붙어 있다. 테스트는 줄 번호를 코드에 적어 두지 않고
이 마커에서 기대값을 읽기 때문에, 표본을 고쳐도 테스트가 어긋나지 않는다.

## 왜 가짜라고 단정할 수 있는가

정보보호본부 애플리케이션보안팀이 2026-11-13 공개 전 점검에서 값별로 판정한 근거다.

| 값의 종류 | 가짜인 근거 |
|---|---|
| AWS 액세스 키 꼴 (`AKIA…`) | 형식(`AKIA` + 16자)은 맞지만 본문이 `EXAMPLEFAKE`라는 **표식 문자열**이다. 실제 발급 키는 무작위 영숫자다 |
| AWS 시크릿 키 꼴 | 본문이 `OBVIOUSLYFAKE` / `NOTAREALSECRET` + `0` 패딩이다 |
| GitHub PAT 꼴 (`ghp_…`) | 본문이 `NotAReal…` 표식이고, GitHub PAT 길이 규격에도 맞지 않는다 |
| Stripe 키 꼴 (`sk-live-…`) | 동일하게 `NotAReal…` 표식이다 |
| UUID 토큰 꼴 | UUID 형태지만 마지막 세그먼트가 **비(非)16진수 영문 표식**(`notarealtoken`)이라 UUID로 파싱되지 않는다 |
| 비밀번호 꼴 | `NOT-A-REAL-…`, `NotAReal…`, `***`, `%s` 같은 표식이 붙은 합성 문자열이다 |
| 개인키 블록 | **`-----BEGIN … PRIVATE KEY-----` 머리글 한 줄뿐이고 키 본문이 없다.** 복호화할 재료 자체가 없다 |
| `198.19.44.77` | **IANA 벤치마크 전용 대역** `198.18.0.0/15`([RFC 2544](https://www.rfc-editor.org/rfc/rfc2544)). 실제 호스트에 할당되지 않는다 |
| `203.0.113.x` | **문서 전용 예약 대역** `203.0.113.0/24` (TEST-NET-3, [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737)) |
| `10.0.1.x` | RFC 1918 사설 대역. 인터넷에서 라우팅되지 않는다 |

모든 표본 파일 머리말에도 "값은 모두 명백히 가짜다"가 적혀 있다.

## 외부 보안 스캐너에게

이 경로는 **의도적으로 심어 둔 탐지 테스트 표본**이다(`used in tests`).
GitHub Secret Scanning Push Protection을 포함한 자동 스캐너가 경고를 올릴 수 있으나,
위 근거대로 유효한 자격증명이 아니다.

`secret-scan.py`는 저장소 전체 검사에서 이 디렉터리를 건너뛰고(`FIXTURE_DIR`),
회귀 테스트가 경로를 **인자로 직접 넘길 때만** 검사한다.

---

**English summary** — This directory contains fixtures for `secret-scan.py`, the repository's
own plaintext-secret detector. All "credentials" here are deliberately fake: token bodies carry
`NotAReal` / `EXAMPLEFAKE` markers, the private key is a header line with no key body, and the
IP addresses come from IANA benchmarking (`198.18.0.0/15`) and documentation (`203.0.113.0/24`,
RFC 5737) ranges that are never assigned to real hosts. Do not "fix" or redact these values —
`scripts/ci/test-secret-scan.py` asserts on them, and replacing them breaks the regression suite.
