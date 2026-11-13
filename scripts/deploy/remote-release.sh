#!/usr/bin/env bash
#
# remote-release.sh — Lightsail 인스턴스 "안에서" 실행하는 릴리스 전환 스크립트
#
# 역할
#   1) 업로드된 산출물을 /srv/meta-gallery/<env>/releases/<git-sha>/ 에 설치
#   2) <env>/current 심볼릭 링크를 새 릴리스로 원자적 교체
#   3) nginx reload 후 /healthz 200 확인
#   4) 확인 실패 시 직전 릴리스로 자동 복귀(롤백)하고 0이 아닌 코드로 종료
#
# 기준 문서: docs/plans/2026-11-13-aws-infra.md (1-2 경로/호스트명, 1-6 배포 흐름)
#            docs/infra/git-and-cicd.md
#
# 사용 예
#   bash remote-release.sh --env dev --sha 0a1b2c3d --artifact /tmp/stage/meta-gallery.html
#
# 주의
#   - 이 스크립트는 파일이나 디렉터리를 "삭제하지 않는다". 오래된 릴리스 정리는
#     docs/infra/git-and-cicd.md 의 수동 절차로만 한다(팀 원칙: 되돌리기 어려운 명령 금지).
#   - current 심링크 교체는 포인터 전환이며 rollback.sh 로 되돌릴 수 있다.
#
set -Eeuo pipefail

readonly DEPLOY_ROOT="/srv/meta-gallery"
readonly EXPECTED_THREE="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"
readonly MIN_ARTIFACT_BYTES=20000

ENV_NAME=""
GIT_SHA=""
ARTIFACT=""
KEEP_WARN=5
HEALTH_RETRIES=10
HEALTH_INTERVAL=3
DO_RELOAD=1
REINSTALL=0

log()  { printf '[remote-release] %s\n' "$*"; }
warn() { printf '[remote-release][경고] %s\n' "$*" >&2; }
die()  { printf '[remote-release][실패] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
사용법:
  remote-release.sh --env <prod|dev> --sha <git-sha> --artifact <파일경로> [옵션]

필수:
  --env <prod|dev>      배포 환경
  --sha <git-sha>       릴리스 식별자(커밋 SHA, 7~40자 16진수)
  --artifact <경로>     업로드된 meta-gallery.html 경로

옵션:
  --keep <n>            릴리스 보관 권고 개수(초과 시 경고만, 기본 5)
  --health-retries <n>  헬스체크 재시도 횟수(기본 10)
  --health-interval <s> 헬스체크 간격 초(기본 3)
  --no-reload           nginx reload 생략
  --reinstall           같은 SHA 릴리스 디렉터리의 파일을 다시 설치
  -h, --help            이 도움말
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)             ENV_NAME="${2:-}"; shift 2 ;;
    --sha)             GIT_SHA="${2:-}"; shift 2 ;;
    --artifact)        ARTIFACT="${2:-}"; shift 2 ;;
    --keep)            KEEP_WARN="${2:-}"; shift 2 ;;
    --health-retries)  HEALTH_RETRIES="${2:-}"; shift 2 ;;
    --health-interval) HEALTH_INTERVAL="${2:-}"; shift 2 ;;
    --no-reload)       DO_RELOAD=0; shift ;;
    --reinstall)       REINSTALL=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

# ---------- 입력 검증 ----------
case "$ENV_NAME" in
  prod) PUBLIC_HOST="metagallery.duckdns.org" ;;
  dev)  PUBLIC_HOST="metagallery-dev.duckdns.org" ;;
  *)    die "--env 는 prod 또는 dev 여야 한다 (받은 값: '${ENV_NAME}')" ;;
esac

[[ "$GIT_SHA" =~ ^[0-9a-fA-F]{7,40}$ ]] || die "--sha 형식이 잘못됐다 (받은 값: '${GIT_SHA}')"
[ -n "$ARTIFACT" ] || die "--artifact 가 비어 있다"
[ -f "$ARTIFACT" ] || die "산출물 파일이 없다: ${ARTIFACT}"
[ -s "$ARTIFACT" ] || die "산출물 파일이 비어 있다: ${ARTIFACT}"
[[ "$KEEP_WARN" =~ ^[0-9]+$ ]] || die "--keep 는 숫자여야 한다"
[[ "$HEALTH_RETRIES" =~ ^[0-9]+$ ]] || die "--health-retries 는 숫자여야 한다"
[[ "$HEALTH_INTERVAL" =~ ^[0-9]+$ ]] || die "--health-interval 는 숫자여야 한다"

ARTIFACT_BYTES="$(wc -c <"$ARTIFACT" | tr -d ' ')"
if [ "$ARTIFACT_BYTES" -lt "$MIN_ARTIFACT_BYTES" ]; then
  die "산출물이 너무 작다(${ARTIFACT_BYTES} bytes < ${MIN_ARTIFACT_BYTES}). 빌드가 깨졌을 수 있다."
fi
grep -F -q "$EXPECTED_THREE" "$ARTIFACT" \
  || die "산출물에 three.js r128 CDN 참조가 없다. 배포를 중단한다."

readonly BASE="${DEPLOY_ROOT}/${ENV_NAME}"
readonly RELEASES="${BASE}/releases"
readonly SHARED="${BASE}/shared"
readonly CURRENT="${BASE}/current"
readonly RELEASE_DIR="${RELEASES}/${GIT_SHA}"
readonly PREV_POINTER="${SHARED}/previous-release"

log "환경=${ENV_NAME} 호스트=${PUBLIC_HOST} sha=${GIT_SHA}"
log "릴리스 디렉터리=${RELEASE_DIR}"

# ---------- 디렉터리 준비 ----------
mkdir -p "$RELEASES" "$SHARED" "$RELEASE_DIR"

# ---------- 직전 릴리스 기록 (롤백 대비) ----------
PREV_SHA=""
if [ -L "$CURRENT" ]; then
  PREV_TARGET="$(readlink "$CURRENT")"
  PREV_SHA="$(basename "$PREV_TARGET")"
  log "직전 릴리스=${PREV_SHA}"
else
  log "직전 릴리스 없음(최초 배포로 본다)"
fi

# ---------- 산출물 설치 ----------
if [ -f "${RELEASE_DIR}/index.html" ] && [ "$REINSTALL" -eq 0 ]; then
  log "같은 SHA 릴리스가 이미 설치돼 있다. 파일을 덮어쓰지 않고 심링크만 전환한다(--reinstall 로 재설치)."
else
  install -m 0644 "$ARTIFACT" "${RELEASE_DIR}/index.html"
  install -m 0644 "$ARTIFACT" "${RELEASE_DIR}/meta-gallery.html"
  log "설치 완료: index.html, meta-gallery.html (${ARTIFACT_BYTES} bytes)"
fi

# 릴리스 메타데이터(배포 추적용. 비밀값을 넣지 않는다)
ARTIFACT_SHA256="$( (sha256sum "${RELEASE_DIR}/index.html" 2>/dev/null || shasum -a 256 "${RELEASE_DIR}/index.html") | awk '{print $1}')"
cat >"${RELEASE_DIR}/RELEASE.json" <<JSON
{
  "env": "${ENV_NAME}",
  "git_sha": "${GIT_SHA}",
  "public_host": "${PUBLIC_HOST}",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "deployed_by": "${DEPLOY_ACTOR:-unknown}",
  "artifact_bytes": ${ARTIFACT_BYTES},
  "artifact_sha256": "${ARTIFACT_SHA256}",
  "previous_release": "${PREV_SHA}"
}
JSON

# 설치 결과 검증
[ -s "${RELEASE_DIR}/index.html" ] || die "설치된 index.html 이 비어 있다"
grep -F -q "$EXPECTED_THREE" "${RELEASE_DIR}/index.html" \
  || die "설치된 index.html 에 three.js r128 참조가 없다"

# ---------- current 심링크 원자적 교체 ----------
switch_to() {
  # $1: 대상 릴리스 디렉터리(절대 경로)
  local target="$1"
  local tmp_link="${BASE}/.current.$$"
  ln -s "$target" "$tmp_link"
  # mv -T 는 rename(2) 한 번으로 끝나므로 교체 중간 상태가 없다.
  # 디렉터리가 아닌 심링크 포인터만 바꾸며, rollback.sh 로 되돌릴 수 있다.
  mv -T "$tmp_link" "$CURRENT"
}

log "current 심링크를 ${GIT_SHA} 로 전환한다"
switch_to "$RELEASE_DIR"
printf '%s\n' "$PREV_SHA" >"$PREV_POINTER"

# 전환 결과 확인.
# /healthz 는 nginx 가 직접 반환하는 고정 문자열이라(1-2) "nginx 가 살아 있다"만 증명한다.
# "올바른 릴리스가 연결됐다"는 것은 심링크가 가리키는 실제 내용으로 확인한다.
LINKED_SHA="$(basename "$(readlink "$CURRENT")")"
[ "$LINKED_SHA" = "$GIT_SHA" ] || die "심링크 전환 후 확인 실패: current=${LINKED_SHA}, 기대값=${GIT_SHA}"
SERVED_SHA256="$( (sha256sum "${CURRENT}/index.html" 2>/dev/null || shasum -a 256 "${CURRENT}/index.html") | awk '{print $1}')"
[ "$SERVED_SHA256" = "$ARTIFACT_SHA256" ] \
  || die "심링크 경유 내용이 다르다: ${SERVED_SHA256} != ${ARTIFACT_SHA256}"
log "심링크 전환 확인 완료 (current → ${LINKED_SHA}, sha256 일치)"

# ---------- nginx reload ----------
reload_nginx() {
  if [ "$DO_RELOAD" -eq 0 ]; then
    log "--no-reload 지정: nginx reload 생략"
    return 0
  fi
  if sudo -n systemctl reload nginx 2>/dev/null; then
    log "nginx reload 완료"
    return 0
  fi
  warn "nginx reload 실패(권한 또는 설정 문제). 정적 파일은 심링크 전환만으로도 제공되지만,"
  warn "open_file_cache 가 켜져 있으면 이전 파일이 잠시 더 보일 수 있다. 수동 확인이 필요하다."
  return 0
}
reload_nginx

# ---------- 헬스체크 ----------
health_code() {
  curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    -H "Host: ${PUBLIC_HOST}" "http://127.0.0.1/healthz" 2>/dev/null || printf '000'
}

health_ok=0
for attempt in $(seq 1 "$HEALTH_RETRIES"); do
  code="$(health_code)"
  if [ "$code" = "200" ]; then
    log "헬스체크 통과 (${attempt}번째 시도, HTTP ${code})"
    health_ok=1
    break
  fi
  log "헬스체크 대기 (${attempt}/${HEALTH_RETRIES}, HTTP ${code})"
  sleep "$HEALTH_INTERVAL"
done

if [ "$health_ok" -eq 1 ]; then
  # ---------- 릴리스 보관 개수 경고 (삭제하지 않는다) ----------
  release_count="$(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if [ "$release_count" -gt "$KEEP_WARN" ]; then
    warn "릴리스 디렉터리가 ${release_count}개로 권고치(${KEEP_WARN})를 넘었다."
    warn "정리는 docs/infra/git-and-cicd.md '릴리스 보관과 정리' 절의 수동 절차로 한다(스크립트는 삭제하지 않는다)."
  fi
  log "배포 성공: ${ENV_NAME} / ${GIT_SHA}"
  exit 0
fi

# ---------- 실패: 자동 롤백 ----------
warn "헬스체크가 ${HEALTH_RETRIES}회 연속 실패했다. 자동 롤백을 시도한다."

if [ -z "$PREV_SHA" ]; then
  die "되돌릴 직전 릴리스가 없다(최초 배포). current 는 ${GIT_SHA} 에 그대로 있다. nginx 설정과 /healthz 를 수동 확인해야 한다."
fi
if [ ! -d "${RELEASES}/${PREV_SHA}" ]; then
  die "직전 릴리스 디렉터리가 없다: ${RELEASES}/${PREV_SHA}. 수동 복구가 필요하다."
fi

switch_to "${RELEASES}/${PREV_SHA}"
printf '%s\n' "$GIT_SHA" >"$PREV_POINTER"
reload_nginx

rollback_code="$(health_code)"
if [ "$rollback_code" = "200" ]; then
  warn "롤백 완료: current = ${PREV_SHA} (실패한 릴리스 ${GIT_SHA} 는 삭제하지 않고 남겨 둔다)"
else
  warn "롤백 후에도 헬스체크가 실패했다(HTTP ${rollback_code}). nginx 또는 서버 전체 문제일 수 있다."
fi
die "배포 실패: ${ENV_NAME} / ${GIT_SHA} (롤백 대상=${PREV_SHA}, 롤백 후 HTTP ${rollback_code})"
