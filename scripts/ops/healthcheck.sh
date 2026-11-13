#!/usr/bin/env bash
#
# healthcheck.sh - 메타 갤러리 인스턴스 자체 점검 (5분 주기)
#
# Lightsail 기본 지표에 없는 항목(디스크, 메모리/swap, PostgreSQL 응답, /healthz,
# 인증서 만료, DuckDNS 타이머, 백업 최신성)을 인스턴스 안에서 직접 본다.
# 임계값을 넘으면 로그에 WARN/CRIT으로 남기고 종료 코드로 알린다.
#
# 사용법
#   healthcheck.sh              # 전체 점검, 결과를 stdout(journal)과 로그 파일에 기록
#   healthcheck.sh --quiet      # WARN/CRIT 만 출력
#   healthcheck.sh --no-log     # 로그 파일 기록 생략
#
# 종료 코드: 0 정상 / 1 WARN 있음 / 2 CRIT 있음
#   (SKIP = 해당 환경에서 확인할 수 없는 항목. 종료 코드에 넣지 않는다.)
#
# 임계값은 환경변수로 덮어쓸 수 있다(기본값은 아래 참고).
#
set -uo pipefail

DISK_WARN="${DISK_WARN:-80}"
DISK_CRIT="${DISK_CRIT:-90}"
INODE_WARN="${INODE_WARN:-80}"
INODE_CRIT="${INODE_CRIT:-90}"
MEM_WARN="${MEM_WARN:-85}"
MEM_CRIT="${MEM_CRIT:-95}"
SWAP_WARN="${SWAP_WARN:-50}"
SWAP_CRIT="${SWAP_CRIT:-80}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-20}"
CERT_CRIT_DAYS="${CERT_CRIT_DAYS:-7}"
BACKUP_MAX_AGE_H="${BACKUP_MAX_AGE_H:-36}"

LOG_FILE="${HEALTHCHECK_LOG:-/var/log/meta-gallery/healthcheck.log}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/meta-gallery}"
PROD_HOST="metagallery.duckdns.org"
DEV_HOST="metagallery-dev.duckdns.org"
PROD_DB="metagallery_prod"
DEV_DB="metagallery_dev"

QUIET="no"
WRITE_LOG="yes"
WARN_COUNT=0
CRIT_COUNT=0
SKIP_COUNT=0
LINES=""

usage() { sed -n '2,20p' "$0" | sed -e 's/^#\{1,2\} \{0,1\}//' -e 's/^#$//'; }

emit() {
  local level="$1" name="$2" detail="$3" line
  line=$(printf '%s %-4s %-18s %s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$name" "$detail")
  LINES="${LINES}${line}
"
  case "$level" in
    CRIT) CRIT_COUNT=$((CRIT_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
  esac
  if [ "$QUIET" = "no" ] || [ "$level" = "WARN" ] || [ "$level" = "CRIT" ]; then
    printf '%s\n' "$line"
  fi
}

# 수치 1개를 warn/crit 임계값과 비교해 등급을 매긴다.
grade() {
  local name="$1" value="$2" warn="$3" crit="$4" unit="$5"
  if [ "$value" -ge "$crit" ]; then
    emit CRIT "$name" "${value}${unit} (임계 ${crit}${unit})"
  elif [ "$value" -ge "$warn" ]; then
    emit WARN "$name" "${value}${unit} (주의 ${warn}${unit})"
  else
    emit OK "$name" "${value}${unit}"
  fi
}

check_disk() {
  local used
  used=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  if [ -z "${used:-}" ]; then
    emit SKIP "disk-root" "df 결과를 읽지 못했습니다"
    return
  fi
  grade "disk-root" "$used" "$DISK_WARN" "$DISK_CRIT" "%"

  local iused
  iused=$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  if [ -z "${iused:-}" ] || ! printf '%s' "$iused" | grep -Eq '^[0-9]+$'; then
    emit SKIP "disk-inode" "inode 사용률을 확인하지 못했습니다"
  else
    grade "disk-inode" "$iused" "$INODE_WARN" "$INODE_CRIT" "%"
  fi
}

check_memory() {
  if [ ! -r /proc/meminfo ]; then
    emit SKIP "memory" "/proc/meminfo 없음(Linux 아님)"
    emit SKIP "swap" "/proc/meminfo 없음(Linux 아님)"
    return
  fi
  local total avail used_pct stotal sfree sused_pct
  total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  if [ -n "${total:-}" ] && [ -n "${avail:-}" ] && [ "$total" -gt 0 ]; then
    used_pct=$(( (total - avail) * 100 / total ))
    grade "memory" "$used_pct" "$MEM_WARN" "$MEM_CRIT" "%"
  else
    emit SKIP "memory" "MemTotal/MemAvailable를 읽지 못했습니다"
  fi

  stotal=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  sfree=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  if [ -z "${stotal:-}" ] || [ "$stotal" -eq 0 ]; then
    emit WARN "swap" "swap이 없습니다. 1GB RAM 인스턴스에는 2GB swapfile이 필요합니다(provision.sh)"
  else
    sused_pct=$(( (stotal - sfree) * 100 / stotal ))
    grade "swap" "$sused_pct" "$SWAP_WARN" "$SWAP_CRIT" "%"
  fi
}

check_service() {
  local unit="$1" name="$2"
  if ! command -v systemctl >/dev/null 2>&1; then
    emit SKIP "$name" "systemctl 없음"
    return
  fi
  if systemctl is-active --quiet "$unit"; then
    emit OK "$name" "${unit} active"
  else
    emit CRIT "$name" "${unit} 가 active가 아닙니다 (systemctl status ${unit})"
  fi
}

check_timer() {
  local unit="$1" name="$2"
  if ! command -v systemctl >/dev/null 2>&1; then
    emit SKIP "$name" "systemctl 없음"
    return
  fi
  if systemctl is-active --quiet "$unit"; then
    emit OK "$name" "${unit} active"
  else
    emit WARN "$name" "${unit} 가 active가 아닙니다 (도메인 회수/인증서 만료 위험)"
  fi
}

check_postgres() {
  if ! command -v pg_isready >/dev/null 2>&1; then
    emit SKIP "postgres" "pg_isready 없음(미설치 환경)"
    return
  fi
  if pg_isready -h 127.0.0.1 -p 5432 -q; then
    emit OK "postgres" "127.0.0.1:5432 응답"
  else
    emit CRIT "postgres" "127.0.0.1:5432 무응답 (systemctl status postgresql)"
    return
  fi

  if ! command -v psql >/dev/null 2>&1 || [ "$(id -u)" -ne 0 ]; then
    emit SKIP "postgres-db" "psql 없음 또는 root가 아니어서 DB별 질의를 생략했습니다"
    return
  fi
  local db
  for db in "$PROD_DB" "$DEV_DB"; do
    if sudo -u postgres psql -d "$db" -tAc 'SELECT 1' >/dev/null 2>&1; then
      emit OK "postgres-${db}" "SELECT 1 정상"
    else
      emit CRIT "postgres-${db}" "SELECT 1 실패 (DB 존재/권한 확인)"
    fi
  done
}

check_healthz() {
  local host="$1" name="$2" code
  if ! command -v curl >/dev/null 2>&1; then
    emit SKIP "$name" "curl 없음"
    return
  fi
  # 외부 DNS를 타지 않고 로컬 nginx에 Host 헤더로 직접 물어본다.
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
          -H "Host: ${host}" "http://127.0.0.1/healthz" 2>/dev/null || true)
  case "$code" in
    200) emit OK "$name" "HTTP 200" ;;
    401) emit WARN "$name" "HTTP 401 - /healthz에 Basic 인증이 걸려 있습니다. 감시용으로 auth_basic off가 필요합니다(nginx 담당 확인)" ;;
    000|"") emit CRIT "$name" "응답 없음 (nginx 80번 확인)" ;;
    *) emit CRIT "$name" "HTTP ${code}" ;;
  esac
}

check_cert() {
  local certname="$1" name="$2" cert days
  cert="/etc/letsencrypt/live/${certname}/cert.pem"
  if [ ! -f "$cert" ]; then
    emit SKIP "$name" "${cert} 없음(아직 발급 전)"
    return
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    emit SKIP "$name" "openssl 없음"
    return
  fi
  local end end_epoch now_epoch
  end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
  end_epoch=$(date -d "$end" +%s 2>/dev/null || true)
  if [ -z "${end_epoch:-}" ]; then
    emit SKIP "$name" "만료일 파싱 실패: ${end}"
    return
  fi
  now_epoch=$(date +%s)
  days=$(( (end_epoch - now_epoch) / 86400 ))
  if [ "$days" -le "$CERT_CRIT_DAYS" ]; then
    emit CRIT "$name" "만료 ${days}일 전 (${end})"
  elif [ "$days" -le "$CERT_WARN_DAYS" ]; then
    emit WARN "$name" "만료 ${days}일 전 (${end}) - certbot.timer 확인"
  else
    emit OK "$name" "만료 ${days}일 전"
  fi
}

check_backup() {
  local env_name="$1" dir latest age_h
  dir="${BACKUP_DIR}/${env_name}"
  if [ ! -d "$dir" ]; then
    emit SKIP "backup-${env_name}" "${dir} 없음(백업 미구성)"
    return
  fi
  latest=$(find "$dir" -type f -name '*.dump' 2>/dev/null | sort | tail -n 1)
  if [ -z "$latest" ]; then
    emit WARN "backup-${env_name}" "${dir}에 덤프 파일이 없습니다"
    return
  fi
  local mtime now
  mtime=$(stat -c '%Y' "$latest" 2>/dev/null || stat -f '%m' "$latest" 2>/dev/null || true)
  if [ -z "${mtime:-}" ]; then
    emit SKIP "backup-${env_name}" "최신 덤프 시각을 읽지 못했습니다"
    return
  fi
  now=$(date +%s)
  age_h=$(( (now - mtime) / 3600 ))
  if [ "$age_h" -gt "$BACKUP_MAX_AGE_H" ]; then
    emit WARN "backup-${env_name}" "최신 덤프가 ${age_h}시간 전입니다(기준 ${BACKUP_MAX_AGE_H}시간) - $(basename "$latest")"
  else
    emit OK "backup-${env_name}" "최신 덤프 ${age_h}시간 전"
  fi
}

write_log() {
  [ "$WRITE_LOG" = "yes" ] || return 0
  local dir
  dir=$(dirname "$LOG_FILE")
  if [ ! -d "$dir" ]; then
    printf '[healthcheck] 로그 디렉터리가 없어 파일 기록을 생략했습니다: %s\n' "$dir" >&2
    return 0
  fi
  if ! { printf '%s' "$LINES" >> "$LOG_FILE"; } 2>/dev/null; then
    printf '[healthcheck] 로그 파일에 쓸 수 없어 생략했습니다: %s\n' "$LOG_FILE" >&2
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) QUIET="yes" ;;
      --no-log) WRITE_LOG="no" ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
    shift
  done

  check_disk
  check_memory
  check_service nginx nginx
  check_service postgresql postgresql
  check_timer duckdns-update.timer duckdns-timer
  check_timer certbot.timer certbot-timer
  check_postgres
  check_healthz "$PROD_HOST" healthz-prod
  check_healthz "$DEV_HOST" healthz-dev
  check_cert meta-gallery-prod cert-prod
  check_cert meta-gallery-dev cert-dev
  check_backup prod
  check_backup dev

  local summary
  summary=$(printf 'summary CRIT=%d WARN=%d SKIP=%d' "$CRIT_COUNT" "$WARN_COUNT" "$SKIP_COUNT")
  emit INFO "healthcheck" "$summary"
  write_log

  if [ "$CRIT_COUNT" -gt 0 ]; then exit 2; fi
  if [ "$WARN_COUNT" -gt 0 ]; then exit 1; fi
  exit 0
}

main "$@"
