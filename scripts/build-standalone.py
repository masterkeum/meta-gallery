"""gallery-mockup.html(아티팩트용 본문 조각)을 브라우저에서 바로 열 수 있는 완전한 HTML 문서로 만든다.

아티팩트는 게시할 때 <!doctype>, <head>, <body>와 viewport 메타를 자동으로 붙인다.
로컬 실행이나 일반 웹 호스팅에서는 그게 없으므로 이 스크립트가 대신 붙인다.

사용: python3 scripts/build-standalone.py  →  dist/meta-gallery.html
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "gallery-mockup.html"
OUT = ROOT / "dist" / "meta-gallery.html"

src = SRC.read_text(encoding="utf-8")
cut = src.index("</style>") + len("</style>")
head, body = src[:cut], src[cut:].lstrip("\n")
# 아티팩트 뷰어 전용 메타는 일반 웹에서 의미가 없으므로 뺀다
head = "\n".join(l for l in head.splitlines() if 'name="claude:' not in l)

doc = f"""<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="description" content="고양이 캐릭터가 되어 나선 램프 전시관을 걸으며 작품을 감상하는 3D 메타버스 갤러리 목업">
<style>
/* 아티팩트 뷰어가 붙여 주던 기본 리셋 */
:root{{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}}
body{{margin:0}}
img{{max-width:100%}}
</style>
{head}
</head>
<body>
{body}
</body>
</html>
"""
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(doc, encoding="utf-8")
print(f"{OUT.relative_to(ROOT)} ({len(doc.encode('utf-8')):,} bytes)")
