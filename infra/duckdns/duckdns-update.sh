#!/usr/bin/env bash
#
# duckdns-update.sh - DuckDNS keepalive 갱신 (메타 갤러리)
#
# 목적
#   Lightsail 고정 IP를 쓰므로 IP는 바뀌지 않지만, DuckDNS는 장기간 갱신이 없는
#   도메인을 회수한다. 그래서 5분 주기 systemd timer로 keepalive 갱신만 돈다.
#   대상 호스트: metagallery.duckdns.org / metagallery-dev.duckdns.org
#
# 토큰 노출 방지 규칙 (검수 기준 2)
#   1) 토큰은 0600 env 파일(/etc/meta-gallery/duckdns.env)에서만 읽는다.
#      커맨드라인 인자로는 절대 받지 않는다.
#   2) env 파일을 source 하지 않고 KEY=VALUE 줄만 파싱한다(임의 코드 실행 방지).
#   3) curl 호출 시 토큰이 들어간 URL을 argv에 두지 않는다. `curl --config -`로
#      표준입력으로만 넘기므로 `ps`, `/proc/<pid>/cmdline`에 노출되지 않는다.
#   4) 모든 표준출력/표준에러는 redact()를 거쳐 토큰을 ***REDACTED***로 바꾼다.
#      curl 에러 메시지에 URL이 섞여 나오는 경우도 여기서 걸러진다.
#   5) 셸 히스토리 노출 방지: 토큰을 손으로 치는 명령을 쓰지 않는다.
#      env 파일 작성 절차는 infra/duckdns/README.md 참고.
#
# 사용법
#   duckdns-update.sh              # 실제 갱신 1회
#   duckdns-update.sh --check      # env 파일/권한/형식만 검사 (네트워크 호출 없음)
#   duckdns-update.sh --dry-run    # 보낼 요청을 토큰 가린 형태로 출력만 (호출 없음)
#   duckdns-update.sh --help
#
# 종료 코드
#   0 성공(OK) / 1 설정 오류 / 2 네트워크·HTTP 오류 / 3 DuckDNS가 KO 응답
#
set -euo pipefail

ENV_FILE="${DUCKDNS_ENV_FILE:-/etc/meta-gallery/duckdns.env}"
ENDPOINT="${DUCKDNS_ENDPOINT:-https://www.duckdns.org/update}"
DEFAULT_DOMAINS="metagallery,metagallery-dev"
CURL_TIMEOUT="${DUCKDNS_CURL_TIMEOUT:-20}"

TOKEN=""
DOMAINS=""
WANT_IP=""
MODE="update"

redact() {
  if [ -n "$TOKEN" ]; then
    sed -e "s/${TOKEN}/***REDACTED***/g"
  else
    cat
  fi
}

log() {
  printf '%s duckdns-update: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" | redact >&2
}

die() {
  log "ERROR: $2"
  exit "$1"
}

usage() {
  sed -n '2,30p' "$0" | sed -e 's/^#\{1,2\} \{0,1\}//' -e 's/^#$//'
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"
}

file_owner() {
  stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1"
}

# env 파일을 source 하지 않고 KEY=VALUE 한 줄만 꺼낸다.
read_env_value() {
  local key="$1" line value
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" | tail -n 1 || true)
  if [ -z "$line" ]; then
    printf '%s' ''
    return 0
  fi
  value=${line#*=}
  value=$(printf '%s' "$value" | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")
  printf '%s' "$value"
}

check_env_file() {
  [ -f "$ENV_FILE" ] || die 1 "env 파일이 없습니다: ${ENV_FILE} (README의 '토큰 등록' 절차 참고)"
  [ -r "$ENV_FILE" ] || die 1 "env 파일을 읽을 수 없습니다: ${ENV_FILE} (root로 실행하십시오)"

  local mode owner tail2
  mode=$(file_mode "$ENV_FILE")
  owner=$(file_owner "$ENV_FILE")
  tail2=${mode: -2}
  if [ "$tail2" != "00" ]; then
    die 1 "env 파일 권한이 너무 넓습니다(현재 ${mode}). 'chmod 600 ${ENV_FILE}' 후 다시 실행하십시오."
  fi
  if [ "$owner" != "root" ]; then
    log "WARN: ${ENV_FILE} 소유자가 root가 아닙니다(현재 ${owner}). 운영 서버에서는 root:root 0600이어야 합니다."
  fi
}

load_config() {
  TOKEN=$(read_env_value DUCKDNS_TOKEN)
  DOMAINS=$(read_env_value DUCKDNS_DOMAINS)
  WANT_IP=$(read_env_value DUCKDNS_IP)
  [ -n "$DOMAINS" ] || DOMAINS="$DEFAULT_DOMAINS"

  # 토큰: 값 자체는 어떤 경로로도 출력하지 않는다. 형식/길이만 검사한다.
  if [ -z "$TOKEN" ]; then
    die 1 "DUCKDNS_TOKEN이 ${ENV_FILE}에 없습니다."
  fi
  case "$TOKEN" in
    *[!A-Za-z0-9-]*)
      die 1 "DUCKDNS_TOKEN 형식이 올바르지 않습니다(영숫자와 하이픈만 허용). 값은 출력하지 않습니다." ;;
  esac
  if [ "${#TOKEN}" -lt 8 ]; then
    die 1 "DUCKDNS_TOKEN이 너무 짧습니다(${#TOKEN}자). 값은 출력하지 않습니다."
  fi

  case "$DOMAINS" in
    *[!A-Za-z0-9,.-]*)
      die 1 "DUCKDNS_DOMAINS 형식이 올바르지 않습니다: ${DOMAINS}" ;;
  esac
  case "$DOMAINS" in
    *.duckdns.org*)
      die 1 "DUCKDNS_DOMAINS에는 서브도메인 이름만 적습니다(예: metagallery,metagallery-dev). 현재: ${DOMAINS}" ;;
  esac

  if [ -n "$WANT_IP" ]; then
    case "$WANT_IP" in
      *[!0-9.]*) die 1 "DUCKDNS_IP가 IPv4 형식이 아닙니다: ${WANT_IP}" ;;
    esac
  fi
}

build_url() {
  # ip= 를 비워 두면 DuckDNS가 요청 송신 IP(= Lightsail 고정 IP)를 그대로 쓴다.
  printf '%s?domains=%s&token=%s&ip=%s&verbose=true' \
    "$ENDPOINT" "$DOMAINS" "$TOKEN" "$WANT_IP"
}

do_update() {
  local url out rc body code
  url=$(build_url)

  set +e
  # --config - : 토큰이 포함된 URL을 표준입력으로만 전달(argv 노출 없음)
  # 2>&1       : curl 에러 메시지까지 redact 대상으로 모은다
  out=$(printf 'url = "%s"\n' "$url" | curl --config - \
      --silent --show-error \
      --max-time "$CURL_TIMEOUT" \
      --retry 2 --retry-delay 3 \
      --ipv4 \
      --write-out '\n%{http_code}' 2>&1)
  rc=$?
  set -e

  code=$(printf '%s' "$out" | tail -n 1)
  body=$(printf '%s' "$out" | sed '$d')

  if [ "$rc" -ne 0 ]; then
    log "ERROR: curl 실패 (exit ${rc}) / 응답: $(printf '%s' "$body" | tr '\n' ' ')"
    exit 2
  fi
  if [ "$code" != "200" ]; then
    log "ERROR: HTTP ${code} / 응답: $(printf '%s' "$body" | tr '\n' ' ')"
    exit 2
  fi

  case "$body" in
    OK*)
      log "OK domains=${DOMAINS} ip=${WANT_IP:-auto} $(printf '%s' "$body" | tr '\n' ' ')"
      return 0
      ;;
    KO*)
      log "ERROR: DuckDNS가 KO를 반환했습니다. 토큰 또는 서브도메인 소유 여부를 확인하십시오(domains=${DOMAINS})."
      exit 3
      ;;
    *)
      log "ERROR: 알 수 없는 응답: $(printf '%s' "$body" | tr '\n' ' ')"
      exit 2
      ;;
  esac
}

main() {
  umask 077

  while [ $# -gt 0 ]; do
    case "$1" in
      --check)   MODE="check" ;;
      --dry-run) MODE="dry-run" ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done

  check_env_file
  load_config

  case "$MODE" in
    check)
      log "OK env=${ENV_FILE} domains=${DOMAINS} ip=${WANT_IP:-auto} token=***REDACTED***(${#TOKEN}자) - 네트워크 호출 없음"
      ;;
    dry-run)
      log "요청 URL(토큰 가림): ${ENDPOINT}?domains=${DOMAINS}&token=***REDACTED***&ip=${WANT_IP:-}&verbose=true"
      log "dry-run 이므로 호출하지 않았습니다."
      ;;
    update)
      do_update
      ;;
  esac
}

main "$@"
