#!/usr/bin/env bash
#
# enable-https.sh - nginx 설정을 STAGE 1(HTTP 전용) → STAGE 2(HTTPS)로 전환한다.
#
# 배경
#   저장소의 nginx 설정은 STAGE 1 상태로 둔다. 인증서가 없는 새 서버에서
#   nginx -t 가 통과해야 부트스트랩이 되기 때문이다(docs/infra/server-layout.md 5장).
#   인증서를 발급한 뒤 이 스크립트로 블록을 전환한다.
#
# 전환 내용 (server-layout.md 5장 표)
#   [A] 80 포트 전용        : 활성 → 주석
#   [B] 443 포트 (TLS)      : 주석 → 활성
#   [C] 80 → 443 리다이렉트 : 주석 → 활성
#
# 사용법
#   sudo bash scripts/ops/enable-https.sh prod
#   sudo bash scripts/ops/enable-https.sh all
#   sudo bash scripts/ops/enable-https.sh all --dry-run
#
# 멱등성
#   이미 STAGE 2 인 설정은 건너뛴다. 전환 전 원본을
#   /var/backups/meta-gallery/nginx/<타임스탬프>/ 로 복사한다.
#   파일을 지우지 않는다.
#
# 선행 조건
#   인증서가 이미 있어야 한다(scripts/ops/issue-certificates.sh ... --confirm).
#   없으면 nginx -t 가 실패하므로 전환하지 않고 멈춘다.
#
set -euo pipefail

SITES_DIR="${NGINX_SITES_DIR:-/etc/nginx/sites-available}"
BACKUP_ROOT="${NGINX_BACKUP_ROOT:-/var/backups/meta-gallery/nginx}"
DRY_RUN=0

log()  { printf '[enable-https] %s\n' "$*" >&2; }
die()  { printf '[enable-https] ERROR: %s\n' "$*" >&2; exit 1; }

target=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        prod|dev|all) target="$1" ;;
        --dry-run)    DRY_RUN=1 ;;
        *)            die "알 수 없는 인자: $1 (사용법: $0 prod|dev|all [--dry-run])" ;;
    esac
    shift
done
[[ -n "${target}" ]] || die "대상을 지정하십시오: prod | dev | all"

cert_name_for() {
    case "$1" in
        prod) printf 'meta-gallery-prod' ;;
        dev)  printf 'meta-gallery-dev' ;;
    esac
}

# STAGE 1 → STAGE 2 치환. 주석 블록 중 'server {' ~ '}' 구간만 해제하고
# 설명 주석([B]/[C] 머리말)은 주석으로 남긴다.
transform() {
    python3 - "$1" "$2" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")

def marker(tag):
    for i, l in enumerate(lines):
        if re.match(r'^#\s*\[' + tag + r'\]', l):
            return i
    raise SystemExit(f"[{tag}] 블록 머리말을 찾지 못했다: {src}")

a, b, c = marker("A"), marker("B"), marker("C")
if not a < b < c:
    raise SystemExit(f"블록 순서가 [A]<[B]<[C] 가 아니다: {src}")

out = list(lines)

# [A]: 활성 server 블록을 주석 처리
i = a
while i < b and not re.match(r'^server\s*\{', lines[i]):
    i += 1
if i >= b:
    raise SystemExit("이미 STAGE 2 이거나 [A] 활성 블록이 없다")
depth = 0
while i < b:
    depth += lines[i].count("{") - lines[i].count("}")
    out[i] = "# " + lines[i] if lines[i].strip() else "#"
    i += 1
    if depth == 0:
        break

# [B], [C]: 주석된 server 블록을 해제
def uncomment(start, end):
    j = start
    while j < end and not re.match(r'^#\s*server\s*\{', lines[j]):
        j += 1
    if j >= end:
        raise SystemExit("주석된 server 블록을 찾지 못했다")
    depth = 0
    while j < end:
        stripped = re.sub(r'^#[ ]?', '', lines[j])
        depth += stripped.count("{") - stripped.count("}")
        out[j] = stripped
        j += 1
        if depth == 0:
            break

uncomment(b, c)
uncomment(c, len(lines))

open(dst, "w", encoding="utf-8").write("\n".join(out))
PY
}

ts="$(date '+%Y%m%d-%H%M%S')"
envs=()
case "${target}" in
    all) envs=(prod dev) ;;
    *)   envs=("${target}") ;;
esac

changed=0
for env_name in "${envs[@]}"; do
    conf="${SITES_DIR}/meta-gallery-${env_name}.conf"
    [[ -f "${conf}" ]] || die "설정 파일이 없다: ${conf} (provision.sh 를 먼저 실행하십시오)"

    cert="/etc/letsencrypt/live/$(cert_name_for "${env_name}")/fullchain.pem"
    [[ -f "${cert}" ]] || die "인증서가 없다: ${cert} (issue-certificates.sh ${env_name} --confirm 먼저)"

    # 주의: 세미콜론을 넣으면 안 된다. 실제 설정은 nginx 1.24 문법인
    # `listen 443 ssl http2;` 라서 `ssl;` 로 찾으면 영영 매치되지 않고,
    # 이미 STAGE 2 인 서버에 다시 돌렸을 때 치환기로 들어가 die 한다.
    if grep -qE '^[[:space:]]*listen 443 ssl' "${conf}"; then
        log "${env_name}: 이미 STAGE 2 (443 활성). 건너뛴다"
        continue
    fi

    tmp="$(mktemp)"
    transform "${conf}" "${tmp}" || die "${env_name}: 치환 실패"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "${env_name}: [dry-run] 아래 차이를 적용할 예정"
        diff -u "${conf}" "${tmp}" || true
        rm -f "${tmp}"
        continue
    fi

    install -d -m 0755 "${BACKUP_ROOT}/${ts}"
    cp -p "${conf}" "${BACKUP_ROOT}/${ts}/meta-gallery-${env_name}.conf.stage1"
    log "${env_name}: 원본 백업 → ${BACKUP_ROOT}/${ts}/meta-gallery-${env_name}.conf.stage1"

    install -o root -g root -m 0644 "${tmp}" "${conf}"
    rm -f "${tmp}"
    changed=1
    log "${env_name}: STAGE 2 적용"
done

if [[ ${DRY_RUN} -eq 1 ]]; then
    log "dry-run 이므로 nginx 를 건드리지 않았다"
    exit 0
fi

if [[ ${changed} -eq 0 ]]; then
    log "변경 없음"
    exit 0
fi

log "nginx -t 검증"
if ! nginx -t; then
    log "검증 실패. 백업에서 되돌린다: ${BACKUP_ROOT}/${ts}/"
    for env_name in "${envs[@]}"; do
        bak="${BACKUP_ROOT}/${ts}/meta-gallery-${env_name}.conf.stage1"
        [[ -f "${bak}" ]] && install -o root -g root -m 0644 "${bak}" "${SITES_DIR}/meta-gallery-${env_name}.conf"
    done
    nginx -t && log "되돌림 후 검증 통과"
    die "STAGE 2 전환 실패. 설정을 STAGE 1 로 되돌렸다"
fi

systemctl reload nginx
log "nginx reload 완료. HTTPS 확인:"
for env_name in "${envs[@]}"; do
    case "${env_name}" in
        prod) host="metagallery.duckdns.org" ;;
        dev)  host="metagallery-dev.duckdns.org" ;;
    esac
    log "  curl -sI https://${host}/healthz"
done
