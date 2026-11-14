#!/usr/bin/env bash
#
# upload-media.sh - 공유 미디어(/media/)를 서버의 shared/media/ 에 올린다.
#
# 배경
#   로비 사이니지 영상처럼 릴리스와 수명이 다른 정적 파일은 릴리스 디렉터리가 아니라
#   /srv/meta-gallery/<env>/shared/media/ 에 둔다. current 심링크는 릴리스마다 바뀌므로
#   그 안에 두면 배포할 때마다 다시 올려야 한다.
#   영상은 공개 저장소에 커밋하지 않으므로 CI 배포 경로를 타지 않는다. 그래서 이 스크립트로
#   수동 업로드한다. 자세한 설계는 docs/infra/server-layout.md 2장 "공유 미디어 올리기".
#
# 실행 위치
#   CEO 의 PC(로컬). 서버 안에서 실행하는 스크립트가 아니다.
#
# 사용법
#   bash scripts/ops/upload-media.sh --env prod --file signage.mp4 --file signage-poster.jpg
#   bash scripts/ops/upload-media.sh --env dev  --file signage.mp4 --dry-run
#
# 하는 일
#   1) 로컬 파일 사전 점검(존재·비어있지 않음·sha256 기록)
#   2) scp 로 서버 /tmp 스테이징에 올림
#   3) shared/media/ 생성(2750) 후 install -m 0640 으로 설치
#   4) 설치본 sha256 을 로컬 값과 대조 → 다르면 실패
#   5) 소유·권한이 deploy:mgweb 0640 인지 확인(nginx 가 읽을 수 있어야 한다)
#   6) 서버 안에서 /media/ 200 과 Range 206 확인
#
# 하지 않는 일
#   - 파일 삭제. rm -rf / --force 를 쓰지 않는다. 스테이징 파일도 지우지 않고 남긴다.
#   - nginx 설정 반영. 그것은 provision.sh --force-nginx-conf 뒤에
#     scripts/ops/enable-https.sh all 순서로 따로 한다(순서를 어기면 HTTPS 가 끊긴다).
#   - 같은 이름의 파일이 이미 있으면 덮어쓴다. 되돌릴 수 있게 --backup 으로 사본을 남길 수 있다.
#
# ssh 로 보내는 원격 명령에는 로컬 변수(설치 경로·Host 헤더)를 **일부러** 클라이언트 측에서
# 전개해 박는다. 값은 모두 이 스크립트가 --env 검증을 거쳐 만든 고정 문자열이다.
# shellcheck disable=SC2029

set -Eeuo pipefail

ENV_NAME=""
SSH_USER="${LIGHTSAIL_SSH_USER:-deploy}"
SSH_HOST="${LIGHTSAIL_HOST:-}"
DRY_RUN=0
BACKUP=0
FILES=()

log()  { printf '[upload-media] %s\n' "$*" >&2; }
warn() { printf '[upload-media][경고] %s\n' "$*" >&2; }
die()  { printf '[upload-media][실패] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
사용법:
  upload-media.sh --env <prod|dev> --file <경로> [--file <경로> ...] [옵션]

필수:
  --env <prod|dev>   대상 환경
  --file <경로>      올릴 파일(여러 번 지정 가능)

옵션:
  --host <호스트>    ssh 접속 대상(기본: 환경별 DuckDNS 호스트명, 또는 $LIGHTSAIL_HOST)
  --user <계정>      ssh 계정(기본: deploy, 또는 $LIGHTSAIL_SSH_USER)
  --backup           같은 이름 파일이 있으면 <이름>.<타임스탬프>.bak 으로 사본을 남긴다
  --dry-run          접속·업로드 없이 수행할 내용만 출력한다
  -h, --help         이 도움말
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)     ENV_NAME="${2:-}"; shift 2 ;;
    --file)    FILES+=("${2:-}"); shift 2 ;;
    --host)    SSH_HOST="${2:-}"; shift 2 ;;
    --user)    SSH_USER="${2:-}"; shift 2 ;;
    --backup)  BACKUP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

# ---------- 입력 검증 ----------
case "$ENV_NAME" in
  prod) PUBLIC_HOST="metagallery.duckdns.org" ;;
  dev)  PUBLIC_HOST="metagallery-dev.duckdns.org" ;;
  *)    die "--env 는 prod 또는 dev 여야 한다 (받은 값: '${ENV_NAME}')" ;;
esac
[ -n "${SSH_HOST}" ] || SSH_HOST="${PUBLIC_HOST}"
[ "${#FILES[@]}" -gt 0 ] || die "--file 을 최소 하나 지정해야 한다"

MEDIA_DIR="/srv/meta-gallery/${ENV_NAME}/shared/media"
TS="$(date '+%Y%m%d-%H%M%S')"
STAGE_DIR="/tmp/meta-gallery-media-${TS}"

# 파일별 로컬 sha256 을 "이름<TAB>해시" 매니페스트 파일로 만든다.
# 파이프로 ssh 에 넘기면 heredoc(원격 스크립트 본문)이 stdin 을 덮어쓰므로,
# 매니페스트도 함께 올려서 원격이 파일로 읽게 한다.
# (이 맥의 bash 는 3.2 라 연관배열을 쓰지 않는다)
MANIFEST_FILE="$(mktemp -t mgmedia)"
MANIFEST_NAME="MANIFEST.sha256"
for f in "${FILES[@]}"; do
  [ -n "$f" ]  || die "--file 값이 비어 있다"
  [ -f "$f" ]  || die "파일이 없다: $f"
  [ -s "$f" ]  || die "파일이 비어 있다: $f"
  base="$(basename "$f")"
  case "$base" in
    */*|.|..|""|"$MANIFEST_NAME") die "파일 이름을 쓸 수 없다: $base" ;;
  esac
  sum="$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | awk '{print $1}')"
  bytes="$(wc -c <"$f" | tr -d ' ')"
  printf '%s\t%s\n' "$base" "$sum" >>"$MANIFEST_FILE"
  log "로컬: ${base}  ${bytes} bytes  sha256 ${sum}"
done

log "환경=${ENV_NAME}  공개호스트=${PUBLIC_HOST}  접속=${SSH_USER}@${SSH_HOST}"
log "설치 위치=${MEDIA_DIR}"
log "스테이징=${STAGE_DIR}"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] 아래를 수행할 예정이었다. 접속하지 않았다."
  printf '  scp %s %s@%s:%s/\n' "${FILES[*]}" "$SSH_USER" "$SSH_HOST" "$STAGE_DIR"
  for f in "${FILES[@]}"; do
    printf '  install -m 0640 %s/%s %s/%s\n' "$STAGE_DIR" "$(basename "$f")" "$MEDIA_DIR" "$(basename "$f")"
  done
  printf '  (설치 후) sha256 대조, 소유·권한 확인, /media/ 200 과 Range 206 확인\n'
  exit 0
fi

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)

# ---------- 1) 스테이징 디렉터리 ----------
log "스테이징 디렉터리를 만든다"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "install -d -m 0700 '${STAGE_DIR}'" \
  || die "ssh 접속 또는 스테이징 생성 실패"

# ---------- 2) 업로드 (미디어 + 매니페스트) ----------
log "파일을 올린다"
scp "${SSH_OPTS[@]}" "${FILES[@]}" "${SSH_USER}@${SSH_HOST}:${STAGE_DIR}/" \
  || die "scp 실패"
scp "${SSH_OPTS[@]}" "$MANIFEST_FILE" "${SSH_USER}@${SSH_HOST}:${STAGE_DIR}/${MANIFEST_NAME}" \
  || die "매니페스트 scp 실패"
rm -f "$MANIFEST_FILE"   # 자기가 만든 mktemp 파일만 지운다(enable-https.sh 와 같은 방식)

# ---------- 3~5) 설치·대조·권한 확인 (서버에서 한 번에) ----------
log "서버에 설치하고 sha256·권한을 대조한다"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" \
  "MEDIA_DIR='${MEDIA_DIR}' STAGE_DIR='${STAGE_DIR}' MANIFEST_NAME='${MANIFEST_NAME}' TS='${TS}' BACKUP='${BACKUP}' bash -s" <<'REMOTE' \
  || die "서버측 설치·검증 실패"
set -Eeuo pipefail
install -d -m 2750 "${MEDIA_DIR}"
manifest="${STAGE_DIR}/${MANIFEST_NAME}"
[ -s "$manifest" ] || { echo "매니페스트가 비어 있거나 없다: $manifest" >&2; exit 1; }
rc=0
while IFS="$(printf '\t')" read -r base want; do
  [ -n "${base:-}" ] || continue
  src="${STAGE_DIR}/${base}"
  dst="${MEDIA_DIR}/${base}"
  [ -f "$src" ] || { echo "스테이징에 파일이 없다: $src" >&2; rc=1; continue; }
  # 설치 "전에" 전송본을 검증한다. 설치 후에 검사하면 손상된 파일이 이미
  # 서빙 디렉터리에 들어간 뒤에 걸러진다(지우지 않는 원칙상 수동 정리가 필요해진다).
  staged="$(sha256sum "$src" | awk '{print $1}')"
  if [ "$staged" != "$want" ]; then
    echo "  전송본 sha256 불일치 - 설치하지 않는다: ${base} 기대=${want} 실제=${staged}" >&2
    rc=1
    continue
  fi
  if [ -f "$dst" ] && [ "$BACKUP" = "1" ]; then
    cp -p "$dst" "${dst}.${TS}.bak"
    echo "  기존 파일 사본: ${dst}.${TS}.bak"
  fi
  install -m 0640 "$src" "$dst"
  got="$(sha256sum "$dst" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "  설치본 sha256 불일치: ${base} 기대=${want} 실제=${got}" >&2
    rc=1
    continue
  fi
  owner="$(stat -c '%U:%G %a' "$dst")"
  echo "  설치: ${dst}  sha256 일치  ${owner}"
  case "$owner" in
    deploy:mgweb*) : ;;
    *) echo "  경고: 소유·그룹이 deploy:mgweb 이 아니다(${owner}). nginx 가 못 읽을 수 있다." >&2 ;;
  esac
done <"$manifest"
# 디렉터리까지 nginx(www-data)가 탐색 가능한지
stat -c '디렉터리: %n %U:%G %a' "${MEDIA_DIR}"
exit "$rc"
REMOTE

# ---------- 6) 서버 안에서 응답 확인 ----------
log "서버 안에서 /media/ 응답을 확인한다 (nginx 설정이 반영돼 있어야 200 이 나온다)"
for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  # shellcheck disable=SC2016
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" \
    "printf '  %-26s GET=%s Range=%s\n' '${base}' \
       \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: ${PUBLIC_HOST}' 'http://127.0.0.1/media/${base}')\" \
       \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -r 0-1023 -H 'Host: ${PUBLIC_HOST}' 'http://127.0.0.1/media/${base}')\"" \
    || warn "${base}: 응답 확인 명령이 실패했다"
done

log "완료. 기대값은 GET=200, Range=206 이다."
log "개발계는 Basic 인증이 걸려 있어 자격증명 없이 호출하면 401 이 정상이다."
log "200 이 아니면 nginx 설정이 아직 반영되지 않은 것이다. 순서를 지켜 반영한다:"
log "  sudo bash infra/server/scripts/provision.sh --force-nginx-conf"
log "  sudo bash scripts/ops/enable-https.sh all"
log "  sudo nginx -t && curl -sI https://${PUBLIC_HOST}/healthz"
log "스테이징(${STAGE_DIR})은 지우지 않았다. 확인 후 직접 정리한다."
