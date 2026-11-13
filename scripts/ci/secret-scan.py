#!/usr/bin/env python3
"""평문 비밀값 패턴 검사기 (meta-gallery CI)

사용법:
    python3 scripts/ci/secret-scan.py              # 저장소 전체 검사
    python3 scripts/ci/secret-scan.py <파일>...     # 지정한 파일만 검사(회귀 테스트용)

종료코드: 0 = 의심 0건 / 1 = 의심 1건 이상

설계 원칙 (2026-11-13 팀장 검수 1·2차 보완)
-------------------------------------------------
1. 면제는 **줄이나 파일이 아니라 "매치된 값"에만** 적용한다.
   주석은 값에 끼어들지 않는다(값은 공백 전까지만 본다).
2. 키 이름 예외는 맨문자열이 아니라 **앵커로 좁힌다**(`^NOPASSWD:` 등).
3. `.example` 파일을 **스캔에서 제외하지 않는다.** 값이 자리표시자인지로 판정한다.
4. 제외 파일은 **이 파일 자신**뿐이다. `.github/workflows/ci.yml` 도 검사 대상이다.
5. **면제는 "완전일치" 아니면 "잔여 런 검사"로만 한다.**
   값 안에 `***`/`REDACTED`/`%s` 가 섞여 있다는 이유로 면제하면
   `DB_PASSWORD=R3alSecretPw9***` 처럼 진짜 비밀값에 가림 문자만 덧붙여 통과시킬 수 있다.
   그래서 자리표시자·포맷·마스크 토큰을 **제거한 뒤 영숫자가 8자 이상 연속으로
   남으면 면제하지 않는다.**

한계 (사람 검토를 대체하지 않는다)
-------------------------------------------------
- **영숫자 8자 하한**: 값이 8자 미만이면(`SHORT_TOKEN=Ab3xY9z`) 매치하지 않는다.
  또 토큰 제거 후 잔여 런이 8자 미만이면(`TOKEN=abc***def`) 면제된다.
  하한을 6자로 내리면 팀원4의 정상 로그·URL 템플릿(`&verbose=true`, `domains=%s`)이
  오탐으로 바뀐다(`docs/infra/git-and-cicd.md` 3-1 참고). 그래서 8자를 유지한다.
- 값이 **소문자 경로 꼴**이면 비밀값이 아니라고 본다. 소문자만 쓰고 `+` 가 없는
  base64 비밀값은 경로로 오인될 수 있다(대문자나 `+` 가 있으면 잡는다).
- 값에 백틱(`)이 들어 있으면 거기서 끊긴다(마크다운 인라인 코드 경계로 쓰기 때문).
- 알려진 패턴만 본다. 엔트로피 기반 탐지는 하지 않는다.
- `scripts/ci/testdata/` 는 저장소 전체 검사에서만 건너뛴다(검사기 자신의 회귀 테스트
  표본이 들어 있다). 회귀 테스트는 그 경로를 **인자로 직접 넘겨** 검사한다.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

# ---------- 검사 대상 선정 ----------

# 이 파일만 제외한다. 패턴 문자열 자체를 품고 있어서다.
SELF_PATH = "scripts/ci/secret-scan.py"

# 회귀 테스트 표본. 저장소 전체 검사에서만 건너뛴다(인자로 주면 검사한다).
FIXTURE_DIR = "scripts/ci/testdata"

# 빌드 산출물·의존성·상태 디렉터리
SKIP_DIR_PARTS = {".git", "dist", "node_modules", "__pycache__", ".terraform", ".venv", "venv"}

# 텍스트가 아닌 파일
BINARY_SUFFIX = (
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".woff", ".woff2",
    ".ttf", ".otf", ".zip", ".gz", ".tar", ".mp3", ".mp4", ".glb", ".pyc",
)

# 비밀값으로 볼 최소 길이. 아래 "한계"에 근거를 적었다.
MIN_VALUE_LEN = 8

# ---------- 값이 "자리표시자"인지 (완전일치) ----------
PLACEHOLDER_VALUE = re.compile(
    r"""^(?:
          __[A-Za-z0-9_]+__                     # __REPLACE_WITH_GENERATED_PASSWORD__
        | <[^>]+>                               # <CEO_PUBLIC_IP>
        | \$\{\{[^}]*\}\}?                      # ${{ secrets.X }}
        | \$\{[^}]*\}                           # ${VAR}
        | \$[A-Za-z_][A-Za-z0-9_]*              # $VAR
        | \$\([^)]*\)?                          # $(명령)
        | %[0-9.]*[sdqfxu]                      # printf 포맷
        | CHANGE_?ME | REPLACE_?ME | SET_?ME | TODO | FIXME
        | PLACEHOLDER | REDACTED | UNSET | NONE | NULL | EMPTY
        | x{4,} | \*{3,} | \.{3,} | -{3,} | _{3,}
      )$""",
    re.VERBOSE | re.IGNORECASE,
)

# ---------- 값이 "비밀값이 아닌 설정값"인지 (완전일치) ----------
BENIGN_VALUE = re.compile(
    r"""^(?:
          yes | no | true | false | on | off | enabled | disabled
        | localhost | 127\.0\.0\.1
        | scram-sha-256 | md5 | peer | trust | ident | reject | sha256
        | [\w.-]+\.(?:service|timer|conf|sh|py|sql|env|example|json|yml|yaml)
      )$""",
    re.VERBOSE | re.IGNORECASE,
)

# ---------- 경로 판정 ----------
# 경로 꼴이라고 바로 면제하면 base64 비밀값(`/aB3+xY9/zQ8wLm2`)이 빠져나간다.
# 이 저장소/서버의 경로는 모두 소문자이고 `+` 를 쓰지 않으므로 그 두 가지로 가른다.
PATH_SHAPE = re.compile(r"^(?:/|\./|~/)[\w./@-]*$")


def is_path_like(val: str) -> bool:
    if not PATH_SHAPE.match(val):
        return False
    if "+" in val:          # base64 알파벳
        return False
    if any(c.isupper() for c in val):   # 서버 경로는 소문자 관행
        return False
    return True


# ---------- 잔여 런 검사 ----------
# 자리표시자·포맷·마스크 토큰을 지우고 **영숫자 연속**이 얼마나 남는지 본다.
# 공백으로 치환해 인접 토큰이 이어 붙지 않게 한다.
STRIP_TOKENS = (
    re.compile(r"\$\{\{[^}]*\}\}?"),
    re.compile(r"\$\{[^}]*\}?"),
    re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*"),
    re.compile(r"\$\([^)]*\)?"),
    re.compile(r"<[^>]*>"),
    re.compile(r"__[A-Za-z0-9_]+__"),
    re.compile(r"%[0-9.]*[sdqfxu]"),
    re.compile(r"\*{3,}"),
    re.compile(
        r"REDACTED|MASKED|CHANGE_?ME|REPLACE_?ME|SET_?ME|PLACEHOLDER|TODO|FIXME",
        re.IGNORECASE,
    ),
)
RESIDUAL_RUN = re.compile(r"[A-Za-z0-9]{%d,}" % MIN_VALUE_LEN)


def has_strip_token(val: str) -> bool:
    """값에 자리표시자·포맷·마스크 토큰이 하나라도 들어 있는지."""
    return any(rx.search(val) for rx in STRIP_TOKENS)


def residual_run(val: str) -> str | None:
    """토큰을 지운 뒤 남은 영숫자 연속(8자 이상)을 돌려준다. 없으면 None."""
    stripped = val
    for rx in STRIP_TOKENS:
        stripped = rx.sub(" ", stripped)
    m = RESIDUAL_RUN.search(stripped)
    return m.group(0) if m else None


# ---------- 키 이름 예외 (앵커 고정, 매치된 텍스트에만 적용) ----------
BENIGN_ASSIGNMENT = (
    re.compile(r"^NOPASSWD\s*:", re.IGNORECASE),            # sudoers 태그
    re.compile(r"^password_encryption\s*="),                 # postgresql.conf
    re.compile(r"^password_authentication\s*=", re.IGNORECASE),
    re.compile(r"^auth_basic_user_file\b", re.IGNORECASE),    # nginx 지시어(값은 경로)
)

# ---------- 탐지 규칙 ----------
# 면제 모드:
#   "none"   : 값 자체가 비밀값 꼴이라 면제하지 않는다
#   "strict" : 자리표시자/설정값 **완전일치**만 면제 (잔여 런 검사 안 함)
#   "full"   : 완전일치 + 잔여 런 검사까지 허용
#
# 값 문자 클래스에서 `#`·`;` 를 빼지 않는다. 뺐더니 `DB_PASSWORD=Ab#cdefghij` 가
# `#` 에서 끊겨 매치되지 않았다(비밀번호에 쓰이는 `#` 과 주석 `#` 이 충돌).
# 대신 "공백 전까지"를 값으로 본다.
# 백틱은 값 문자에서 뺀다. 이 저장소는 문서(.md)가 많고, 산문에서 예시를
# `KEY=value` 로 적으면 값이 닫는 백틱을 넘어 한국어 문장까지 삼켜 오탐이 난다.
# 백틱은 마크다운 인라인 코드 경계이고, 비밀번호에 쓰이는 일도 드물다.
# (한계: 값에 백틱이 든 비밀값은 놓친다. `#` 과 달리 실제 쓰임이 거의 없어 감수한다.)
VALUE = r"[^\s\"'`]{%d,}" % MIN_VALUE_LEN

# 꺾쇠 자리표시자는 공백을 품을 수 있다(`<DuckDNS 계정 페이지의 token 값>`).
# 단 **값 전체가** 꺾쇠일 때만 이 분기를 쓴다. 그러지 않으면 `TOKEN=<x>실제비밀값` 에서
# `<x>` 만 값으로 잡혀 자리표시자로 오인되고 뒤에 붙은 실제 비밀값이 통째로 빠진다.
ANGLE_VALUE = r"<[^>\n]*>(?=[\"'`]?\s*(?:#|$))"

RULES = (
    (
        "AWS 액세스 키 ID",
        re.compile(r"(?P<val>\b(?:AKIA|ASIA)[0-9A-Z]{16}\b)"),
        "none",
    ),
    (
        "개인키 블록",
        re.compile(r"(?P<val>-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----)"),
        "none",
    ),
    (
        "AWS 시크릿 키 할당",
        re.compile(r"(?i)aws_secret_access_key\s*[:=]\s*[\"']?"
                   r"(?P<val>" + ANGLE_VALUE + r"|" + VALUE + r")"),
        "full",
    ),
    (
        # DB 접속 문자열의 비밀번호는 포맷·마스크 템플릿으로 쓰이는 일이 없다.
        # 그래서 완전일치 자리표시자만 면제한다(`realpw%s` 같은 값을 잡기 위해).
        "DB 접속 문자열 내 비밀번호",
        re.compile(r"postgres(?:ql)?://[^\s:/@]+:(?P<val>[^\s@/]+)@"),
        "strict",
    ),
    (
        "비밀값 직접 할당",
        re.compile(
            r"(?i)(?P<key>[A-Za-z0-9_.-]*"
            r"(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|credential)"
            r"[A-Za-z0-9_.-]*)\s*[:=]\s*[\"']?"
            r"(?P<val>" + ANGLE_VALUE + r"|" + VALUE + r")"
        ),
        "full",
    ),
    (
        "공인 IP 하드코딩",
        re.compile(
            r"(?<![\w.])"
            # 사설·예약·문서용(RFC 5737) 범위는 비밀이 아니므로 제외
            r"(?!0\.|10\.|127\.|169\.254\.|192\.168\.|"
            r"172\.(?:1[6-9]|2\d|3[01])\.|"
            r"22[4-9]\.|2[3-5]\d\.|"
            r"192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)"
            r"(?P<val>(?:\d{1,3}\.){3}\d{1,3})"
            r"(?![\w.])"
        ),
        "none",
    ),
)


def strip_value(raw: str) -> str:
    """값 양끝의 인용부호·대괄호·끝맺음 기호를 떼어 낸다."""
    val = raw.strip()
    val = val.strip("[](),")
    val = val.strip("\"'")
    val = val.rstrip(";,")
    # ["<CEO_PUBLIC_IP>/32"] 같은 CIDR 접미사 제거
    val = re.sub(r"/\d{1,3}$", "", val)
    return val.strip()


def is_exempt_value(value: str, mode: str) -> str | None:
    """값이 면제 대상이면 이유를, 아니면 None 을 돌려준다."""
    val = strip_value(value)
    if not val:
        return "빈 값"
    if PLACEHOLDER_VALUE.match(val):
        return "자리표시자(완전일치)"
    if BENIGN_VALUE.match(val):
        return "설정값(완전일치)"
    if is_path_like(val):
        return "파일 경로"
    if mode != "full":
        return None
    # 토큰이 섞인 템플릿·가림 문자열만 잔여 런 검사로 면제한다.
    # 토큰이 하나도 없으면 면제 후보가 아니다(`R3al-Secr-Etpw-9xy` 같은 값을 잡기 위해).
    if not has_strip_token(val):
        return None
    if residual_run(val) is None:
        return "자리표시자·포맷·마스크만 남음"
    return None


def is_exempt_assignment(match_text: str) -> bool:
    """매치된 텍스트가 앵커로 고정된 키 이름 예외에 걸리는지."""
    return any(rx.match(match_text.strip()) for rx in BENIGN_ASSIGNMENT)


def scan_text(text: str) -> list[tuple[int, str, str]]:
    findings: list[tuple[int, str, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if len(line) > 600:
            continue
        seen: set[tuple[int, str]] = set()
        for label, rx, mode in RULES:
            for m in rx.finditer(line):
                value = m.group("val")
                if mode != "none":
                    if is_exempt_assignment(m.group(0)):
                        continue
                    if is_exempt_value(value, mode):
                        continue
                if (lineno, label) in seen:
                    continue
                seen.add((lineno, label))
                findings.append((lineno, label, value))
    return findings


def repo_files() -> list[str]:
    try:
        out = subprocess.run(
            ["git", "ls-files", "-z"], capture_output=True, check=True
        )
        names = [n for n in out.stdout.decode().split("\0") if n]
        if names:
            return names
    except (OSError, subprocess.CalledProcessError):
        pass
    # git 저장소가 아니면 직접 훑는다
    names = []
    for p in pathlib.Path(".").rglob("*"):
        if p.is_file() and not (SKIP_DIR_PARTS & set(p.parts)):
            names.append(str(p))
    return names


def main(argv: list[str]) -> int:
    explicit = [a for a in argv if not a.startswith("-")]
    targets = explicit or repo_files()

    findings: list[tuple[str, int, str, str]] = []
    scanned = 0

    for name in sorted(targets):
        norm = pathlib.PurePosixPath(name.replace("\\", "/")).as_posix()
        norm = norm[2:] if norm.startswith("./") else norm

        if norm == SELF_PATH:
            continue
        if norm.endswith(BINARY_SUFFIX):
            continue
        if SKIP_DIR_PARTS & set(pathlib.PurePosixPath(norm).parts):
            continue
        if not explicit and norm.startswith(FIXTURE_DIR + "/"):
            continue

        try:
            text = pathlib.Path(name).read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        scanned += 1
        for lineno, label, value in scan_text(text):
            findings.append((norm, lineno, label, value))

    print(f"검사한 파일 {scanned}개")
    for name, lineno, label, value in findings:
        shown = value if len(value) <= 24 else value[:21] + "..."
        print(f"::error file={name},line={lineno}::[{label}] 값={shown}")

    if findings:
        print(f"평문 비밀값 의심 {len(findings)}건")
        print("자리표시자라면 <...> 또는 __REPLACE_WITH_...__ 꼴로 바꾸고,")
        print("실제 비밀값이면 GitHub Secrets / /etc/meta-gallery/*.env 로 옮긴다.")
        return 1

    print("평문 비밀값 의심 0건")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
