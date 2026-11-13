#!/usr/bin/env bash
#
# issue-certificates.sh - Let's Encrypt 인증서 발급/점검 (메타 갤러리)
#
# 방식: certbot + HTTP-01(webroot). 환경별로 인증서를 따로 발급해
#       한쪽 갱신 실패가 다른 쪽으로 번지지 않게 한다.
#
#   운영계: metagallery.duckdns.org      -> --cert-name meta-gallery-prod
#   개발계: metagallery-dev.duckdns.org  -> --cert-name meta-gallery-dev
#
# 실행 순서(강제)
#   1) preflight  : root/certbot/nginx/webroot/80번 도달성 점검
#   2) staging    : --dry-run (Let's Encrypt staging). 여기서 실패하면 멈춘다.
#   3) 본 발급    : --confirm 을 준 경우에만 수행
#   4) 자동갱신   : certbot renew --dry-run + certbot.timer 확인
#
# 사용법
#   issue-certificates.sh prod                  # preflight + staging dry-run 까지만
#   issue-certificates.sh prod --confirm        # dry-run 통과 시 본 발급까지
#   issue-certificates.sh all  --confirm
#   issue-certificates.sh prod --verify-only    # 발급 끝난 뒤 자동갱신만 점검
#
# 필요한 설정
#   /etc/meta-gallery/certbot.env (0600, root:root)
#     ACME_EMAIL=<만료 알림 받을 주소>          # CEO가 직접 입력
#   또는 환경변수 ACME_EMAIL 로 전달
#
# 주의
#   - Let's Encrypt 운영 환경은 발급 한도가 있다(같은 도메인 조합 주당 5회 등).
#     그래서 본 발급 전에 반드시 staging dry-run을 통과시킨다.
#   - *.duckdns.org 는 Public Suffix List에 등록돼 있어 서브도메인별 한도가 독립이다.
#
set -euo pipefail

WEBROOT="${ACME_WEBROOT:-/var/www/certbot}"
CHALLENGE_DIR="${WEBROOT}/.well-known/acme-challenge"
CERTBOT="${CERTBOT_BIN:-certbot}"
CERTBOT_ENV="${CERTBOT_ENV_FILE:-/etc/meta-gallery/certbot.env}"
DEPLOY_HOOK="${ACME_DEPLOY_HOOK:-systemctl reload nginx}"

TARGET=""
CONFIRM="no"
VERIFY_ONLY="no"
PROBE_FILE=""

log()  { printf '[issue-certificates] %s\n' "$1" >&2; }
fail() { printf '[issue-certificates] ERROR: %s\n' "$1" >&2; exit 1; }

usage() {
  sed -n '2,36p' "$0" | sed -e 's/^#\{1,2\} \{0,1\}//' -e 's/^#$//'
}

cleanup() {
  # 직접 만든 probe 파일만 지운다(경로를 challenge 디렉터리로 한정).
  if [ -n "$PROBE_FILE" ] && [ -f "$PROBE_FILE" ]; then
    case "$PROBE_FILE" in
      "${CHALLENGE_DIR}/"*) rm -f -- "$PROBE_FILE" ;;
      *) log "WARN: 예상 밖 경로라 probe 파일을 지우지 않았습니다: ${PROBE_FILE}" ;;
    esac
  fi
}
trap cleanup EXIT

host_for() {
  case "$1" in
    prod) printf 'metagallery.duckdns.org' ;;
    dev)  printf 'metagallery-dev.duckdns.org' ;;
    *) fail "알 수 없는 환경: $1" ;;
  esac
}

certname_for() {
  case "$1" in
    prod) printf 'meta-gallery-prod' ;;
    dev)  printf 'meta-gallery-dev' ;;
    *) fail "알 수 없는 환경: $1" ;;
  esac
}

read_env_value() {
  local key="$1" file="$2" line value
  [ -f "$file" ] || { printf '%s' ''; return 0; }
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -n 1 || true)
  [ -n "$line" ] || { printf '%s' ''; return 0; }
  value=${line#*=}
  printf '%s' "$value" | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

resolve_email() {
  local email="${ACME_EMAIL:-}"
  [ -n "$email" ] || email=$(read_env_value ACME_EMAIL "$CERTBOT_ENV")
  [ -n "$email" ] || fail "ACME_EMAIL이 없습니다. ${CERTBOT_ENV}(0600)에 ACME_EMAIL=... 을 넣으십시오. (값 입력은 CEO 작업)"
  case "$email" in
    *@*.*) : ;;
    *) fail "ACME_EMAIL 형식이 올바르지 않습니다: ${email}" ;;
  esac
  printf '%s' "$email"
}

public_ip() {
  # Lightsail IMDSv2 (링크 로컬). 실패하면 빈 값을 돌려주고 호출부에서 경고만 한다.
  local token ip
  token=$(curl -sS --max-time 3 -X PUT 'http://169.254.169.254/latest/api/token' \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
  [ -n "$token" ] || { printf '%s' ''; return 0; }
  ip=$(curl -sS --max-time 3 -H "X-aws-ec2-metadata-token: ${token}" \
         'http://169.254.169.254/latest/meta-data/public-ipv4' 2>/dev/null || true)
  printf '%s' "$ip"
}

preflight() {
  local env_name="$1" host resolved myip code
  host=$(host_for "$env_name")
  log "--- preflight (${env_name} / ${host}) ---"

  [ "$(id -u)" -eq 0 ] || fail "root로 실행하십시오(sudo)."
  command -v "$CERTBOT" >/dev/null 2>&1 || fail "certbot이 없습니다. 'sudo apt-get install -y certbot' 먼저 실행하십시오."
  command -v curl >/dev/null 2>&1 || fail "curl이 없습니다."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet nginx || fail "nginx가 떠 있지 않습니다. HTTP-01은 80번이 응답해야 합니다."
  else
    log "WARN: systemctl이 없어 nginx 상태를 확인하지 못했습니다."
  fi

  [ -d "$CHALLENGE_DIR" ] || fail "challenge 디렉터리가 없습니다: ${CHALLENGE_DIR} (아래 명령으로 생성)
  sudo install -d -o root -g www-data -m 0755 ${WEBROOT}
  sudo install -d -o root -g www-data -m 0755 ${WEBROOT}/.well-known
  sudo install -d -o root -g www-data -m 0755 ${CHALLENGE_DIR}"

  resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}' || true)
  [ -n "$resolved" ] || fail "DNS에서 ${host}를 찾지 못했습니다. DuckDNS 등록과 duckdns-update.timer 상태를 먼저 확인하십시오."
  log "DNS ${host} -> ${resolved}"

  myip=$(public_ip)
  if [ -z "$myip" ]; then
    log "WARN: 인스턴스 공인 IP를 확인하지 못했습니다(IMDS 응답 없음). DNS 대상 IP 일치 여부는 수동 확인하십시오."
  elif [ "$myip" != "$resolved" ]; then
    fail "DNS가 가리키는 IP(${resolved})와 이 인스턴스 공인 IP(${myip})가 다릅니다. DuckDNS 갱신을 먼저 맞추십시오."
  else
    log "공인 IP 일치: ${myip}"
  fi

  # 실제 HTTP-01 경로가 외부에서 200으로 열리는지 자체 점검한다.
  PROBE_FILE="${CHALLENGE_DIR}/preflight-$(date -u '+%Y%m%d%H%M%S')-$$"
  printf 'meta-gallery-acme-preflight\n' > "$PROBE_FILE"
  chmod 0644 "$PROBE_FILE"
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
          "http://${host}/.well-known/acme-challenge/$(basename "$PROBE_FILE")" || true)
  cleanup
  PROBE_FILE=""
  [ "$code" = "200" ] || fail "http://${host}/.well-known/acme-challenge/ 가 200을 주지 않습니다(HTTP ${code}).
nginx에 아래 location이 있어야 합니다(nginx 설정 담당: 인프라팀 팀원3).
  location ^~ /.well-known/acme-challenge/ { root ${WEBROOT}; default_type \"text/plain\"; auth_basic off; allow all; }"
  log "HTTP-01 경로 200 확인"
}

staging_dry_run() {
  local env_name="$1" host certname email
  host=$(host_for "$env_name"); certname=$(certname_for "$env_name"); email=$(resolve_email)
  log "--- staging dry-run (${certname} / ${host}) ---"
  "$CERTBOT" certonly \
    --webroot --webroot-path "$WEBROOT" \
    --domain "$host" \
    --cert-name "$certname" \
    --email "$email" \
    --agree-tos --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    --dry-run
  log "staging dry-run 성공 (${certname})"
}

issue_real() {
  local env_name="$1" host certname email
  host=$(host_for "$env_name"); certname=$(certname_for "$env_name"); email=$(resolve_email)
  log "--- 본 발급 (${certname} / ${host}) ---"
  "$CERTBOT" certonly \
    --webroot --webroot-path "$WEBROOT" \
    --domain "$host" \
    --cert-name "$certname" \
    --email "$email" \
    --agree-tos --no-eff-email \
    --non-interactive \
    --keep-until-expiring \
    --deploy-hook "$DEPLOY_HOOK"
  log "발급 완료: /etc/letsencrypt/live/${certname}/fullchain.pem"
  log "nginx의 ssl_certificate 경로가 위와 같은지 확인하십시오(설정 담당: 팀원3)."
}

verify_renewal() {
  local env_name="$1" certname certdir
  certname=$(certname_for "$env_name")
  certdir="/etc/letsencrypt/live/${certname}"
  log "--- 자동갱신 점검 (${certname}) ---"

  if [ -f "${certdir}/cert.pem" ]; then
    if command -v openssl >/dev/null 2>&1; then
      log "만료일: $(openssl x509 -enddate -noout -in "${certdir}/cert.pem" | cut -d= -f2)"
      if openssl x509 -checkend 2592000 -noout -in "${certdir}/cert.pem" >/dev/null; then
        log "30일 이상 남아 있습니다."
      else
        log "WARN: 30일 이내 만료 예정입니다. 갱신 타이머 동작을 확인하십시오."
      fi
    fi
  else
    log "WARN: ${certdir}/cert.pem 이 없습니다(아직 발급 전)."
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled certbot.timer >/dev/null 2>&1; then
      log "certbot.timer enabled"
    else
      log "WARN: certbot.timer가 enabled가 아닙니다. 'sudo systemctl enable --now certbot.timer'"
    fi
    systemctl list-timers certbot.timer --no-pager || true
  fi

  log "갱신 리허설: certbot renew --dry-run (전체 인증서 대상)"
  "$CERTBOT" renew --dry-run
  log "갱신 리허설 성공"
  log "deploy-hook 등록 확인: grep -n renew_hook /etc/letsencrypt/renewal/${certname}.conf"
}

run_env() {
  local env_name="$1"
  if [ "$VERIFY_ONLY" = "yes" ]; then
    verify_renewal "$env_name"
    return 0
  fi
  preflight "$env_name"
  staging_dry_run "$env_name"
  if [ "$CONFIRM" != "yes" ]; then
    log "dry-run까지 통과했습니다. 본 발급은 --confirm 을 붙여 다시 실행하십시오:"
    log "  sudo $0 ${env_name} --confirm"
    return 0
  fi
  issue_real "$env_name"
  verify_renewal "$env_name"
}

main() {
  umask 022
  [ $# -ge 1 ] || { usage; exit 1; }

  while [ $# -gt 0 ]; do
    case "$1" in
      prod|dev|all) TARGET="$1" ;;
      --confirm)     CONFIRM="yes" ;;
      --dry-run-only) CONFIRM="no" ;;
      --verify-only) VERIFY_ONLY="yes" ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done

  [ -n "$TARGET" ] || fail "대상을 지정하십시오: prod | dev | all"

  if [ "$TARGET" = "all" ]; then
    run_env prod
    run_env dev
  else
    run_env "$TARGET"
  fi
  log "완료 (target=${TARGET}, confirm=${CONFIRM}, verify-only=${VERIFY_ONLY})"
}

main "$@"
