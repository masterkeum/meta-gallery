#!/usr/bin/env python3
"""secret-scan.py 회귀 테스트

사용법:
    python3 scripts/ci/test-secret-scan.py

확인하는 것
  1. 가짜 비밀값 표본에서 **심어 둔 줄 전부**를 탐지하는지 (누락 0)
  2. 그 표본에서 심지 않은 줄은 탐지하지 않는지 (오탐 0)
  3. 자리표시자·설정값 표본에서 0건을 보고하는지 (오탐 0)
  4. **실제 저장소 전체**에서 0건을 보고하는지

기대값은 표본 파일 안의 `[[DETECT]]` 마커에서 읽어 온다. 줄 번호를 이 파일에
적어 두지 않으므로 표본을 고쳐도 테스트가 어긋나지 않는다.

배경(2026-11-13 두 차례 검수):
  1차 — 예외가 값이 아니라 줄·파일 전체를 면제해 심은 9건 중 3건만 잡혔다.
  2차 — 오탐을 없애려 넣은 값 예외가 search() 라서, 진짜 비밀값에 `***`/`%s` 를
         덧붙이기만 하면 통과했다(심은 10건 전부 미탐지).
그 사례들을 표본에 담아 회귀를 막는다. `known-limits.txt` 는 지금도 못 잡는
사례를 고정해 두는 표본이다(탐지되기 시작하면 테스트가 실패해 문서 갱신을 요구한다).
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SCANNER = ROOT / "scripts" / "ci" / "secret-scan.py"
TESTDATA = ROOT / "scripts" / "ci" / "testdata"

MARKER = "[[DETECT]]"
ERROR_RE = re.compile(r"^::error file=(?P<file>[^,]+),line=(?P<line>\d+)::\[(?P<rule>[^\]]+)\]")

# 반드시 탐지돼야 하는 표본 (팀장이 지적한 9건이 들어 있다)
MUST_DETECT = [
    TESTDATA / "fake-secrets-env.txt",
    TESTDATA / "fake-secrets.env.example",
    TESTDATA / "fake-secrets-masked.txt",
]
# 보강 표본: 공인 IP 하드코딩
EXTRA_DETECT = [TESTDATA / "fake-public-ip.txt"]
# 절대 탐지돼선 안 되는 표본
MUST_BE_CLEAN = [TESTDATA / "clean-placeholders.env.example"]
# 알려진 한계: 지금은 탐지하지 못한다. 탐지되기 시작하면 문서를 갱신해야 하므로 실패시킨다.
KNOWN_LIMITS = [TESTDATA / "known-limits.txt"]

failures: list[str] = []


def run_scanner(paths: list[pathlib.Path]) -> tuple[int, dict[str, set[int]], str]:
    """검사기를 돌리고 (종료코드, {파일: 탐지된 줄번호 집합}, 원문출력) 반환."""
    # 저장소 루트 기준 상대경로로 넘긴다. 검사기 출력의 file= 키와 맞추기 위해서다.
    cmd = [sys.executable, str(SCANNER)] + [rel(p) for p in paths]
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    hits: dict[str, set[int]] = {}
    for line in proc.stdout.splitlines():
        m = ERROR_RE.match(line)
        if m:
            hits.setdefault(m.group("file"), set()).add(int(m.group("line")))
    return proc.returncode, hits, proc.stdout


def planted_lines(path: pathlib.Path) -> set[int]:
    """표본 파일에서 [[DETECT]] 마커가 붙은 줄 번호."""
    out = set()
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if MARKER in line:
            out.add(i)
    return out


def rel(path: pathlib.Path) -> str:
    return path.relative_to(ROOT).as_posix()


def check_detect(paths: list[pathlib.Path], title: str) -> int:
    print(f"\n--- {title} ---")
    code, hits, _ = run_scanner(paths)
    total_planted = 0
    total_detected = 0
    for p in paths:
        expected = planted_lines(p)
        actual = hits.get(rel(p), set())
        total_planted += len(expected)
        total_detected += len(expected & actual)
        missed = sorted(expected - actual)
        extra = sorted(actual - expected)
        for ln in sorted(expected):
            mark = "탐지" if ln in actual else "누락 ❌"
            text = p.read_text(encoding="utf-8").splitlines()[ln - 1]
            key = text.split("=")[0].split()[0][:34]
            print(f"  [{mark}] {rel(p)}:{ln}  {key}")
        if missed:
            failures.append(f"{rel(p)}: 심어 둔 줄 {missed} 을 놓쳤다")
        if extra:
            failures.append(f"{rel(p)}: 심지 않은 줄 {extra} 을 탐지했다(오탐)")
    if code != 1:
        failures.append(f"{title}: 종료코드가 1이 아니다({code})")
    print(f"  → 심어 둔 {total_planted}건 중 {total_detected}건 탐지, 종료코드 {code}")
    return total_planted


def check_clean(paths: list[pathlib.Path], title: str) -> None:
    print(f"\n--- {title} ---")
    code, hits, out = run_scanner(paths)
    if hits:
        for f, lines in hits.items():
            failures.append(f"{f}: 오탐 {sorted(lines)}")
            print(f"  [오탐 ❌] {f}:{sorted(lines)}")
    else:
        print(f"  [통과] 탐지 0건")
    if code != 0:
        failures.append(f"{title}: 종료코드가 0이 아니다({code})")
    print(f"  → 종료코드 {code}")


def check_known_limits() -> None:
    """현재 탐지하지 못하는 사례를 고정한다. 탐지되기 시작하면 문서 갱신이 필요하다."""
    print("\n--- 3b. 알려진 한계 — 지금은 미탐지가 정상 ---")
    code, hits, _ = run_scanner(KNOWN_LIMITS)
    for p in KNOWN_LIMITS:
        actual = sorted(hits.get(rel(p), set()))
        lines = p.read_text(encoding="utf-8").splitlines()
        cases = [i for i, l in enumerate(lines, 1)
                 if l.strip() and not l.strip().startswith("#")]
        for ln in cases:
            state = "탐지됨 → 한계 개선" if ln in actual else "미탐지(문서화된 한계)"
            print(f"  [{state}] {rel(p)}:{ln}  {lines[ln - 1].strip()[:40]}")
        if actual:
            failures.append(
                f"{rel(p)}: 한계 사례 {actual} 가 탐지되기 시작했다 → "
                f"docs/infra/git-and-cicd.md 3-1 '한계' 와 이 표본을 갱신하라")
    if code != 0:
        failures.append(f"알려진 한계 표본에서 종료코드가 0이 아니다({code})")


def check_repo() -> None:
    print("\n--- 4. 실제 저장소 전체 (0건이어야 한다) ---")
    proc = subprocess.run([sys.executable, str(SCANNER)],
                          capture_output=True, text=True, cwd=ROOT)
    print("  " + "\n  ".join(proc.stdout.strip().splitlines()))
    if proc.returncode != 0:
        failures.append(f"저장소 전체 스캔에서 의심 건이 나왔다(종료코드 {proc.returncode})")


def check_fixtures_exist() -> None:
    """표본이 빠지면(예: .gitignore 에 걸려 커밋 누락) 조용히 통과하지 않게 한다."""
    missing = [rel(p) for p in MUST_DETECT + EXTRA_DETECT + MUST_BE_CLEAN + KNOWN_LIMITS
               if not p.exists()]
    if missing:
        print("표본 파일이 없다: " + ", ".join(missing))
        print("커밋에서 빠졌을 수 있다. .gitignore 패턴(*.env 등)에 걸리지 않는지 확인한다.")
        failures.append(f"표본 누락: {missing}")


def main() -> int:
    print("=" * 68)
    print("secret-scan.py 회귀 테스트")
    print("=" * 68)

    check_fixtures_exist()
    if failures:
        print("\n".join(f"  ❌ {f}" for f in failures))
        return 1

    n1 = check_detect(MUST_DETECT, "1. 반드시 탐지 — 팀장 1·2차 지적 사례 + probe 로 찾은 구멍")
    n2 = check_detect(EXTRA_DETECT, "2. 보강 탐지 — 공인 IP 하드코딩")
    check_clean(MUST_BE_CLEAN, "3. 오탐 금지 — 자리표시자·설정값")
    check_known_limits()
    check_repo()

    print("\n" + "=" * 68)
    if failures:
        print(f"실패 {len(failures)}건")
        for f in failures:
            print(f"  ❌ {f}")
        return 1
    print(f"통과 — 필수 {n1}건 + 보강 {n2}건 전부 탐지, 오탐 0건, 저장소 0건")
    return 0


if __name__ == "__main__":
    sys.exit(main())
