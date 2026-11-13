#!/usr/bin/env bash
#
# rollback.sh — Lightsail 인스턴스 "안에서" 실행하는 롤백 스크립트
#
# 역할
#   - current 심볼릭 링크를 직전 릴리스(또는 --to 로 지정한 SHA)로 되돌린다
#   - nginx reload 후 /healthz 200 을 확인한다
#   - 되돌리기 전 SHA 를 previous-release 포인터에 남겨 다시 되돌릴 수 있게 한다
#
# 기준 문서: docs/plans/2026-11-13-aws-infra.md (1-2 경로/호스트명, 1-6 배포 흐름)
#            docs/infra/git-and-cicd.md "롤백"
#
# 사용 예
#   bash rollback.sh --env prod            # 직전 릴리스로 되돌림
#   bash rollback.sh --env dev --to 0a1b2c3  # 특정 릴리스로 되돌림
#   bash rollback.sh --env prod --list     # 설치된 릴리스 목록만 보기
#
# 주의
#   - 이 스크립트는 어떤 파일도 삭제하지 않는다. 심링크 포인터만 바꾼다.
#   - GitHub Actions 의 실패 단계에서도 그대로 호출된다(멱등: 되돌릴 게 없으면 알리고 종료).
#
set -Eeuo pipefail

readonly DEPLOY_ROOT="/srv/meta-gallery"

ENV_NAME=""
TARGET_SHA=""
LIST_ONLY=0
DO_RELOAD=1
HEALTH_RETRIES=5
HEALTH_INTERVAL=3

log()  { printf '[rollback] %s\n' "$*"; }
warn() { printf '[rollback][경고] %s\n' "$*" >&2; }
die()  { printf '[rollback][실패] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
사용법:
  rollback.sh --env <prod|dev> [--to <git-sha>] [옵션]

필수:
  --env <prod|dev>      대상 환경

옵션:
  --to <git-sha>        되돌릴 릴리스 SHA (생략 시 shared/previous-release 사용)
  --list                설치된 릴리스와 현재 링크만 출력하고 종료
  --no-reload           nginx reload 생략
  --health-retries <n>  헬스체크 재시도 횟수(기본 5)
  --health-interval <s> 헬스체크 간격 초(기본 3)
  -h, --help            이 도움말
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)             ENV_NAME="${2:-}"; shift 2 ;;
    --to)              TARGET_SHA="${2:-}"; shift 2 ;;
    --list)            LIST_ONLY=1; shift ;;
    --no-reload)       DO_RELOAD=0; shift ;;
    --health-retries)  HEALTH_RETRIES="${2:-}"; shift 2 ;;
    --health-interval) HEALTH_INTERVAL="${2:-}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

case "$ENV_NAME" in
  prod) PUBLIC_HOST="metagallery.duckdns.org" ;;
  dev)  PUBLIC_HOST="metagallery-dev.duckdns.org" ;;
  *)    die "--env 는 prod 또는 dev 여야 한다 (받은 값: '${ENV_NAME}')" ;;
esac

[[ "$HEALTH_RETRIES" =~ ^[0-9]+$ ]] || die "--health-retries 는 숫자여야 한다"
[[ "$HEALTH_INTERVAL" =~ ^[0-9]+$ ]] || die "--health-interval 는 숫자여야 한다"

readonly BASE="${DEPLOY_ROOT}/${ENV_NAME}"
readonly RELEASES="${BASE}/releases"
readonly SHARED="${BASE}/shared"
readonly CURRENT="${BASE}/current"
readonly PREV_POINTER="${SHARED}/previous-release"

[ -d "$RELEASES" ] || die "릴리스 디렉터리가 없다: ${RELEASES} (아직 배포한 적이 없다)"

CURRENT_SHA=""
if [ -L "$CURRENT" ]; then
  CURRENT_SHA="$(basename "$(readlink "$CURRENT")")"
fi

# ---------- 목록 출력 ----------
if [ "$LIST_ONLY" -eq 1 ]; then
  log "환경=${ENV_NAME}"
  log "현재 current = ${CURRENT_SHA:-(없음)}"
  if [ -f "$PREV_POINTER" ]; then
    log "previous-release 포인터 = $(cat "$PREV_POINTER")"
  else
    log "previous-release 포인터 = (없음)"
  fi
  log "설치된 릴리스 (최근 수정 순):"
  find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
  exit 0
fi

# ---------- 대상 결정 ----------
if [ -z "$TARGET_SHA" ]; then
  [ -f "$PREV_POINTER" ] || die "직전 릴리스 포인터가 없다(${PREV_POINTER}). --to <sha> 로 직접 지정해야 한다. --list 로 목록을 볼 수 있다."
  TARGET_SHA="$(tr -d '[:space:]' <"$PREV_POINTER")"
  [ -n "$TARGET_SHA" ] || die "직전 릴리스 포인터가 비어 있다(최초 배포였을 수 있다). --to <sha> 로 직접 지정해야 한다."
  log "직전 릴리스 포인터에서 대상을 읽었다: ${TARGET_SHA}"
fi

[[ "$TARGET_SHA" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "--to SHA 형식이 잘못됐다 (받은 값: '${TARGET_SHA}')"

readonly TARGET_DIR="${RELEASES}/${TARGET_SHA}"
[ -d "$TARGET_DIR" ] || die "대상 릴리스 디렉터리가 없다: ${TARGET_DIR}. --list 로 목록을 확인해야 한다."
[ -s "${TARGET_DIR}/index.html" ] || die "대상 릴리스에 index.html 이 없거나 비어 있다: ${TARGET_DIR}"

if [ "$TARGET_SHA" = "$CURRENT_SHA" ]; then
  log "current 가 이미 ${TARGET_SHA} 다. 바꿀 것이 없다."
  exit 0
fi

# ---------- 심링크 전환 ----------
log "current 를 ${CURRENT_SHA:-(없음)} → ${TARGET_SHA} 로 되돌린다"
tmp_link="${BASE}/.current.$$"
ln -s "$TARGET_DIR" "$tmp_link"
mv -T "$tmp_link" "$CURRENT"

# 되돌리기 전 SHA 를 포인터에 남겨 다시 전환할 수 있게 한다
mkdir -p "$SHARED"
printf '%s\n' "$CURRENT_SHA" >"$PREV_POINTER"

# ---------- nginx reload ----------
if [ "$DO_RELOAD" -eq 1 ]; then
  if sudo -n systemctl reload nginx 2>/dev/null; then
    log "nginx reload 완료"
  else
    warn "nginx reload 실패(권한 또는 설정 문제). 수동 확인이 필요하다."
  fi
else
  log "--no-reload 지정: nginx reload 생략"
fi

# ---------- 헬스체크 ----------
code="000"
for attempt in $(seq 1 "$HEALTH_RETRIES"); do
  code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    -H "Host: ${PUBLIC_HOST}" "http://127.0.0.1/healthz" 2>/dev/null || printf '000')"
  if [ "$code" = "200" ]; then
    log "헬스체크 통과 (${attempt}번째 시도, HTTP ${code})"
    log "롤백 완료: ${ENV_NAME} / current = ${TARGET_SHA}"
    exit 0
  fi
  log "헬스체크 대기 (${attempt}/${HEALTH_RETRIES}, HTTP ${code})"
  sleep "$HEALTH_INTERVAL"
done

warn "롤백은 했지만 헬스체크가 실패했다(HTTP ${code}). current = ${TARGET_SHA}"
warn "nginx 설정(/healthz)·서비스 상태를 수동 확인해야 한다: sudo nginx -t; systemctl status nginx"
exit 1
