#!/usr/bin/env bash
# =============================================================================
# meta-gallery Lightsail 인스턴스 초기 프로비저닝 (Ubuntu 24.04 전용)
#
#   대상    : AWS Lightsail  meta-gallery-app  (ubuntu_24_04 / micro_3_2 / 1GB RAM)
#   실행    : sudo bash infra/server/scripts/provision.sh [옵션]
#   옵션    : --yes              확인 프롬프트를 건너뛴다(자동화용)
#             --skip-apt         apt 설치 단계를 건너뛴다(재실행 시 빠르게)
#             --allow-other-os   Ubuntu 24.04 가 아니어도 진행한다
#             --repo-root <경로> 저장소 루트를 직접 지정한다
#             --dry-run          실제 변경 없이 수행할 단계만 출력한다
#             --force-nginx-conf 이미 STAGE 2(HTTPS)인 nginx 설정도 STAGE 1 로 덮는다
#                                (덮은 뒤 scripts/ops/enable-https.sh 로 다시 전환할 것)
#
#   !! 이 스크립트는 서버에서만 실행한다. 개발용 맥·윈도우에서 실행하지 않는다.
#      (패키지 설치, 시스템 디렉터리 생성, PostgreSQL 설정 변경을 한다)
#
#   멱등성 : 여러 번 실행해도 안전하게 만들었다. 이미 있는 설정 파일은
#            /var/backups/meta-gallery/provision/<타임스탬프>/ 로 백업한 뒤 바꾼다.
#            이미 있는 /etc/meta-gallery/*.env 는 건드리지 않는다(비밀번호 보존).
#   삭제    : 파일을 지우지 않는다. 비활성화가 필요한 기존 설정은 옮긴다(mv).
#            rm -rf / --force 류 명령은 쓰지 않는다.
#
#   하지 않는 일
#     - HTTPS 인증서 발급 (scripts/ops/issue-certificates.sh, 팀원4 담당)
#     - DuckDNS 갱신 타이머 설치 (infra/duckdns/, 팀원4 담당)
#     - meta-gallery-api@*.service enable/start (백엔드 코드가 아직 없다)
#     - AWS 자원 생성 (infra/terraform/, 팀원2 담당)
#
#   설계 근거: docs/plans/2026-11-13-aws-infra.md 1-1, 1-2, 1-5
#              docs/infra/server-layout.md
# =============================================================================
set -Eeuo pipefail

# --- 고정값 (계획서 1-2. 임의로 바꾸지 않는다) --------------------------------
readonly PROD_HOST="metagallery.duckdns.org"
readonly DEV_HOST="metagallery-dev.duckdns.org"
readonly SRV_ROOT="/srv/meta-gallery"
readonly ETC_DIR="/etc/meta-gallery"
readonly BACKUP_ROOT="/var/backups/meta-gallery"
readonly LOG_DIR="/var/log/meta-gallery"
readonly ACME_WEBROOT="/var/www/certbot"
readonly DEPLOY_USER="deploy"
readonly DEPLOY_GROUP="mgweb"
readonly PG_VERSION="16"
readonly PG_SUPERUSER="postgres"
readonly SWAP_FILE="/swapfile"
readonly SWAP_SIZE_MB=2048
readonly DEV_BASIC_AUTH_USER="preview"
readonly HTPASSWD_FILE="/etc/nginx/.htpasswd-meta-gallery-dev"

OPT_YES=0
OPT_SKIP_APT=0
OPT_ALLOW_OTHER_OS=0
DRY_RUN=0
REPO_ROOT=""
FORCE_NGINX_CONF=0
PROVISION_BACKUP_DIR=""
STEP=0

# ---------------------------------------------------------------------------
# 유틸
# ---------------------------------------------------------------------------
log()  { printf '%s [provision] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
step() { STEP=$((STEP + 1)); printf '\n==== [%02d] %s ====\n' "${STEP}" "$*" >&2; }
warn() { printf '%s [provision] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '%s [provision] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

run() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        printf '  [dry-run] %s\n' "$*" >&2
    else
        "$@"
    fi
}

usage() {
    # 파일 맨 위 주석 블록(= 사용법)만 출력한다. 줄 수가 바뀌어도 따라간다.
    sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# 기존 파일을 백업한 뒤 새 파일을 설치한다. 내용이 같으면 아무것도 하지 않는다.
install_file() {
    local src="$1" dst="$2" mode="$3" owner="${4:-root:root}"
    [[ -f "${src}" ]] || die "원본 파일이 없다: ${src}"

    if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
        log "변경 없음: ${dst}"
        return 0
    fi
    if [[ -e "${dst}" ]]; then
        if [[ -z "${PROVISION_BACKUP_DIR}" ]]; then
            PROVISION_BACKUP_DIR="${BACKUP_ROOT}/provision/$(date '+%Y%m%dT%H%M%S')"
            run mkdir -p "${PROVISION_BACKUP_DIR}"
        fi
        log "기존 파일 백업: ${dst} -> ${PROVISION_BACKUP_DIR}/"
        run cp -a "${dst}" "${PROVISION_BACKUP_DIR}/$(basename "${dst}")"
    fi
    log "설치: ${dst} (${mode} ${owner})"
    run install -o "${owner%%:*}" -g "${owner##*:}" -m "${mode}" "${src}" "${dst}"
}

# 영숫자 40자 난수. DATABASE_URL 에 들어가므로 퍼센트 인코딩이 필요한 문자를 쓰지 않는다.
gen_password() {
    openssl rand -base64 60 | tr -dc 'A-Za-z0-9' | cut -c1-40
}

# ---------------------------------------------------------------------------
# 인자 파싱
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)         OPT_YES=1 ;;
        --skip-apt)       OPT_SKIP_APT=1 ;;
        --allow-other-os) OPT_ALLOW_OTHER_OS=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --repo-root)      REPO_ROOT="${2:?--repo-root 값 필요}"; shift ;;
        --force-nginx-conf) FORCE_NGINX_CONF=1 ;;
        -h|--help)        usage 0 ;;
        *) printf 'ERROR: 알 수 없는 인자: %s\n' "$1" >&2; usage 2 ;;
    esac
    shift
done

if [[ -z "${REPO_ROOT}" ]]; then
    # infra/server/scripts/provision.sh 기준 3단계 위가 저장소 루트
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi
readonly SERVER_DIR="${REPO_ROOT}/infra/server"
[[ -d "${SERVER_DIR}/nginx" ]] || die "저장소 구조를 찾을 수 없다: ${SERVER_DIR} (--repo-root 로 지정하라)"

# ---------------------------------------------------------------------------
# 0. 사전 점검
# ---------------------------------------------------------------------------
step "사전 점검"
[[ ${EUID} -eq 0 ]] || die "root 권한이 필요하다: sudo bash $0"

OS_NAME="unknown"; OS_VER="unknown"
if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_NAME="${ID:-unknown}"; OS_VER="${VERSION_ID:-unknown}"
fi
log "OS: ${OS_NAME} ${OS_VER} / 커널 $(uname -r) / 메모리 $(free -m | awk 'NR==2 {print $2"MB"}')"
if [[ "${OS_NAME}" != "ubuntu" || "${OS_VER}" != "24.04" ]]; then
    if [[ ${OPT_ALLOW_OTHER_OS} -eq 1 ]]; then
        warn "Ubuntu 24.04 가 아니다(${OS_NAME} ${OS_VER}). --allow-other-os 로 계속한다"
    else
        die "Ubuntu 24.04 전용 스크립트다(현재: ${OS_NAME} ${OS_VER}). 그래도 진행하려면 --allow-other-os"
    fi
fi
log "저장소 루트: ${REPO_ROOT}"

if [[ ${OPT_YES} -eq 0 && ${DRY_RUN} -eq 0 ]]; then
    cat >&2 <<'CONFIRM'

이 스크립트는 다음을 변경합니다.
  - 패키지 설치: nginx, postgresql-16, apache2-utils, unzip 등
  - AWS CLI v2 설치(공식 설치본. Ubuntu 24.04 저장소에 awscli 패키지가 없다)
  - 2GB swapfile 생성 및 /etc/fstab 등록
  - 사용자/그룹 deploy:mgweb 생성, /srv/meta-gallery 디렉터리 생성
  - nginx 사이트 설정 설치(기존 default 사이트는 비활성화하고 백업으로 옮김)
  - PostgreSQL 설정(listen_addresses=localhost, pg_hba) 변경 및 재시작
  - DB/롤 생성, /etc/meta-gallery/{prod,dev}.env 생성(0600)
  - systemd 유닛/타이머, logrotate, sudoers 설치
파일을 삭제하지는 않습니다.

CONFIRM
    printf "계속하려면 'yes' 를 입력하세요: " >&2
    read -r confirm_answer
    [[ "${confirm_answer}" == "yes" ]] || die "사용자가 취소했다"
fi

# ---------------------------------------------------------------------------
# 1. 타임존
# ---------------------------------------------------------------------------
step "타임존 Asia/Seoul"
if [[ "$(cat /etc/timezone 2>/dev/null || true)" == "Asia/Seoul" ]]; then
    log "이미 Asia/Seoul"
else
    run timedatectl set-timezone Asia/Seoul
fi

# ---------------------------------------------------------------------------
# 2. 패키지
# ---------------------------------------------------------------------------
step "패키지 설치"
if [[ ${OPT_SKIP_APT} -eq 1 ]]; then
    log "--skip-apt 지정 - 건너뜀"
else
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    run apt-get install -y --no-install-recommends \
        nginx \
        "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" \
        apache2-utils \
        logrotate \
        ca-certificates curl openssl unzip \
        acl
    # certbot 은 팀원4의 scripts/ops/issue-certificates.sh 가 설치·발급을 담당한다.
    log "certbot 은 이 스크립트에서 설치하지 않는다(인증서 발급 담당 분리)"
fi

# ---------------------------------------------------------------------------
# 2-1. AWS CLI v2 (S3 백업 업로드용)
#
# Ubuntu 24.04(noble) 저장소에는 awscli 패키지가 없다. 2026-11-13 실제 실패:
#   Package 'awscli' has no installation candidate
# 그래서 AWS 공식 설치본(zip)으로 깐다. 이미 있으면 건너뛴다(멱등).
# ---------------------------------------------------------------------------
step "AWS CLI v2"
if command -v aws >/dev/null 2>&1; then
    log "이미 설치됨: $(aws --version 2>&1 | head -1)"
elif [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] AWS CLI v2 공식 설치본 다운로드 후 ./aws/install\n' >&2
else
    awscli_tmp="$(mktemp -d)"
    if curl -fsSL --max-time 180 \
        "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" \
        -o "${awscli_tmp}/awscliv2.zip"; then
        unzip -q "${awscli_tmp}/awscliv2.zip" -d "${awscli_tmp}"
        "${awscli_tmp}/aws/install" >/dev/null
        log "설치 완료: $(aws --version 2>&1 | head -1)"
    else
        # 백업 업로드 외의 기능은 aws 없이도 동작하므로 중단하지 않는다.
        warn "AWS CLI v2 다운로드 실패. S3 백업 업로드는 비활성 상태로 둔다."
        warn "  수동 설치: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    fi
    rm -r "${awscli_tmp}"
fi

# ---------------------------------------------------------------------------
# 3. swapfile 2GB (1GB RAM 인스턴스. 계획서 1-1)
# ---------------------------------------------------------------------------
step "swapfile ${SWAP_SIZE_MB}MB"
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${SWAP_FILE}"; then
    log "이미 활성화됨: ${SWAP_FILE} ($(swapon --show=NAME,SIZE --noheadings | tr '\n' ' '))"
elif [[ -e "${SWAP_FILE}" ]]; then
    warn "${SWAP_FILE} 이 있지만 활성화되지 않았다. 내용을 확인하지 않고 덮어쓰지 않는다."
    warn "  수동 확인 후: mkswap ${SWAP_FILE} && swapon ${SWAP_FILE}"
else
    log "swapfile 생성"
    if ! run fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_FILE}"; then
        log "fallocate 실패 - dd 로 생성"
        run dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_SIZE_MB}" status=none
    fi
    run chmod 0600 "${SWAP_FILE}"
    run mkswap "${SWAP_FILE}"
    run swapon "${SWAP_FILE}"
    if grep -q "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null; then
        log "/etc/fstab 에 이미 등록됨"
    else
        log "/etc/fstab 에 등록"
        if [[ ${DRY_RUN} -eq 1 ]]; then
            printf '  [dry-run] echo "%s none swap sw 0 0" >> /etc/fstab\n' "${SWAP_FILE}" >&2
        else
            printf '%s none swap sw 0 0\n' "${SWAP_FILE}" >> /etc/fstab
        fi
    fi
fi

log "메모리 커널 파라미터 (swap 적극 사용 억제)"
if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] write /etc/sysctl.d/60-meta-gallery.conf\n' >&2
else
    cat > /etc/sysctl.d/60-meta-gallery.conf <<'SYSCTL'
# meta-gallery: 1GB RAM + 2GB swap 환경. swap은 비상용으로만 쓴다.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL
    chmod 0644 /etc/sysctl.d/60-meta-gallery.conf
    sysctl -q --system || warn "sysctl 적용 실패 - 재부팅 후 반영된다"
fi

# ---------------------------------------------------------------------------
# 4. 사용자 / 그룹 / 디렉터리
# ---------------------------------------------------------------------------
step "배포 계정과 디렉터리"
if getent group "${DEPLOY_GROUP}" >/dev/null; then
    log "그룹 ${DEPLOY_GROUP} 이미 있음"
else
    run groupadd --system "${DEPLOY_GROUP}"
fi
if id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    log "사용자 ${DEPLOY_USER} 이미 있음"
else
    run useradd --system --create-home --home-dir "/home/${DEPLOY_USER}" \
        --shell /bin/bash --gid "${DEPLOY_GROUP}" "${DEPLOY_USER}"
fi
# nginx(www-data)가 /srv/meta-gallery 를 읽을 수 있게 그룹에 넣는다.
if id -nG www-data 2>/dev/null | tr ' ' '\n' | grep -qx "${DEPLOY_GROUP}"; then
    log "www-data 는 이미 ${DEPLOY_GROUP} 그룹"
else
    run usermod -aG "${DEPLOY_GROUP}" www-data
fi

for env_name in prod dev; do
    run install -d -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" -m 2750 "${SRV_ROOT}/${env_name}"
    run install -d -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" -m 2750 "${SRV_ROOT}/${env_name}/releases"
    run install -d -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" -m 2750 "${SRV_ROOT}/${env_name}/shared"
    # 공유 미디어(/media/). 릴리스 밖에 두어 배포마다 다시 올리지 않는다.
    # nginx 설정의 `location ^~ /media/` alias 대상이다. 파일은 이 스크립트가
    # 올리지 않는다(docs/infra/server-layout.md "공유 미디어 올리기" 참고).
    run install -d -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" -m 2750 "${SRV_ROOT}/${env_name}/shared/media"
    run install -d -o root -g root -m 0700 "${BACKUP_ROOT}/${env_name}"
done
run install -d -o root -g "${DEPLOY_GROUP}" -m 0755 "${SRV_ROOT}"
run install -d -o root -g root -m 0750 "${ETC_DIR}"
run install -d -o root -g root -m 0750 "${LOG_DIR}"
run install -d -o root -g root -m 0700 "${BACKUP_ROOT}/provision"
run install -d -o root -g www-data -m 0755 "${ACME_WEBROOT}"
run install -d -o root -g www-data -m 0755 "${ACME_WEBROOT}/.well-known"
# acme-challenge 까지 미리 만든다. scripts/ops/issue-certificates.sh 의 preflight 가
# 이 디렉터리가 없으면 발급을 중단한다(팀장 검수 2026-11-13: 누락 보완).
run install -d -o root -g www-data -m 0755 "${ACME_WEBROOT}/.well-known/acme-challenge"

# 첫 배포 전에도 nginx 가 뜨도록 부트스트랩 릴리스를 만든다.
step "부트스트랩 릴리스 (첫 배포 전 nginx 기동용)"
for env_name in prod dev; do
    boot_dir="${SRV_ROOT}/${env_name}/releases/0000-bootstrap"
    if [[ -e "${SRV_ROOT}/${env_name}/current" ]]; then
        log "${env_name}: current 가 이미 있다 - 건드리지 않는다"
        continue
    fi
    run install -d -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" -m 2750 "${boot_dir}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        printf '  [dry-run] write %s/index.html, symlink current\n' "${boot_dir}" >&2
    else
        cat > "${boot_dir}/index.html" <<HTMLDOC
<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>meta-gallery (${env_name})</title></head>
<body style="font-family:sans-serif;padding:2rem">
<h1>meta-gallery ${env_name}</h1>
<p>서버 준비 완료. 아직 배포된 릴리스가 없습니다.</p>
</body></html>
HTMLDOC
        chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "${boot_dir}/index.html"
        chmod 0640 "${boot_dir}/index.html"
        ln -sfn "releases/0000-bootstrap" "${SRV_ROOT}/${env_name}/current"
        chown -h "${DEPLOY_USER}:${DEPLOY_GROUP}" "${SRV_ROOT}/${env_name}/current"
    fi
done

# ---------------------------------------------------------------------------
# 5. nginx
# ---------------------------------------------------------------------------
step "nginx 사이트 설정"
# 저장소의 설정은 STAGE 1(HTTP 전용)이다. 인증서가 없는 새 서버에서 nginx -t 가
# 통과해야 부트스트랩이 되기 때문이다.
#
# 이미 STAGE 2(HTTPS)로 전환된 서버에 이 스크립트를 다시 돌리면 설정이 STAGE 1 로
# 덮여 443 이 닫힌다. 2026-11-13 실제로 이 일이 일어나 운영계 HTTPS 가 중단됐다.
# 그래서 설치된 설정이 이미 STAGE 2 면 덮지 않고 건너뛴다.
#
# STAGE 2 서버에 설정 변경을 반영하려면:
#   1) 저장소의 STAGE 1 설정을 고친다
#   2) 이 스크립트를 --force-nginx-conf 로 돌려 덮는다
#   3) scripts/ops/enable-https.sh all 로 STAGE 2 를 다시 적용한다
for env_name in prod dev; do
    installed="/etc/nginx/sites-available/meta-gallery-${env_name}.conf"
    if [[ ${FORCE_NGINX_CONF} -eq 0 ]] \
        && [[ -f "${installed}" ]] \
        && grep -qE '^[[:space:]]*listen 443 ssl' "${installed}"; then
        warn "${env_name}: 설치된 설정이 이미 STAGE 2(HTTPS)다. 덮지 않고 건너뛴다"
        warn "  덮으려면 --force-nginx-conf 를 주고, 그 뒤 enable-https.sh 로 다시 전환하라"
        continue
    fi
    install_file "${SERVER_DIR}/nginx/meta-gallery-${env_name}.conf" "${installed}" 0644
done

for env_name in prod dev; do
    link="/etc/nginx/sites-enabled/meta-gallery-${env_name}.conf"
    if [[ -L "${link}" ]]; then
        log "활성화 링크 이미 있음: ${link}"
    else
        run ln -s "../sites-available/meta-gallery-${env_name}.conf" "${link}"
    fi
done

# 기본 사이트 비활성화: 심볼릭 링크를 지우지 않고 백업 디렉터리로 옮긴다.
if [[ -e /etc/nginx/sites-enabled/default ]]; then
    if [[ -z "${PROVISION_BACKUP_DIR}" ]]; then
        PROVISION_BACKUP_DIR="${BACKUP_ROOT}/provision/$(date '+%Y%m%dT%H%M%S')"
        run mkdir -p "${PROVISION_BACKUP_DIR}"
    fi
    log "nginx 기본 사이트 비활성화 -> ${PROVISION_BACKUP_DIR}/sites-enabled.default"
    run mv /etc/nginx/sites-enabled/default "${PROVISION_BACKUP_DIR}/sites-enabled.default"
else
    log "nginx 기본 사이트는 이미 비활성화 상태"
fi

# 개발계 Basic 인증 (계획서 1-2). 비밀번호는 stdin 으로만 전달한다(ps 노출 방지).
step "개발계 HTTP Basic 인증"
if [[ -f "${HTPASSWD_FILE}" ]]; then
    log "${HTPASSWD_FILE} 이미 있음 - 비밀번호를 바꾸지 않는다"
elif [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] htpasswd 생성: %s\n' "${HTPASSWD_FILE}" >&2
else
    dev_basic_pw="$(gen_password)"
    umask 077
    printf '%s\n' "${dev_basic_pw}" | htpasswd -niB "${DEV_BASIC_AUTH_USER}" > "${HTPASSWD_FILE}"
    chown root:www-data "${HTPASSWD_FILE}"
    chmod 0640 "${HTPASSWD_FILE}"
    cat > "${ETC_DIR}/dev-basic-auth.txt" <<CRED
# 개발계(${DEV_HOST}) HTTP Basic 인증 자격증명
# 생성: $(date '+%Y-%m-%d %H:%M:%S%z')
# CEO/담당자에게 안전한 경로로 전달한 뒤 이 파일을 삭제하세요.
# 보관 방식의 적정성은 정보보호본부 애플리케이션보안팀 검토 대상입니다.
user=${DEV_BASIC_AUTH_USER}
password=${dev_basic_pw}
CRED
    chmod 0600 "${ETC_DIR}/dev-basic-auth.txt"
    unset dev_basic_pw
    log "생성 완료. 자격증명: ${ETC_DIR}/dev-basic-auth.txt (0600, 전달 후 삭제)"
fi

# ---------------------------------------------------------------------------
# 6. PostgreSQL
# ---------------------------------------------------------------------------
step "PostgreSQL ${PG_VERSION} 설정"
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
if [[ ${DRY_RUN} -eq 0 && ! -d "${PG_CONF_DIR}" ]]; then
    die "${PG_CONF_DIR} 이 없다. postgresql-${PG_VERSION} 설치를 확인하라"
fi

run install -d -o "${PG_SUPERUSER}" -g "${PG_SUPERUSER}" -m 0750 "${PG_CONF_DIR}/conf.d"

if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] write %s/conf.d/10-meta-gallery.conf\n' "${PG_CONF_DIR}" >&2
    printf '  [dry-run] write %s/pg_hba.conf (기존 파일은 백업)\n' "${PG_CONF_DIR}" >&2
else
    cat > "${PG_CONF_DIR}/conf.d/10-meta-gallery.conf" <<'PGCONF'
# meta-gallery 전용 설정 (provision.sh 가 설치. 계획서 1-5)
# 외부 노출 금지: 루프백에만 바인딩한다. Lightsail 방화벽에도 5432를 열지 않는다.
listen_addresses = 'localhost'
port = 5432

password_encryption = 'scram-sha-256'

# 1GB RAM 인스턴스 기준 보수적 튜닝 (nginx + 향후 Node 2개와 공존)
max_connections = 40
shared_buffers = 128MB
effective_cache_size = 384MB
work_mem = 4MB
maintenance_work_mem = 64MB
wal_buffers = 4MB
min_wal_size = 80MB
max_wal_size = 1GB
random_page_cost = 1.1          # SSD
effective_io_concurrency = 200

# 로그: 느린 쿼리와 오류만. 평문 비밀번호가 남지 않도록 log_statement 는 none 유지.
log_statement = 'none'
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'Asia/Seoul'
timezone = 'Asia/Seoul'
PGCONF
    chown "${PG_SUPERUSER}:${PG_SUPERUSER}" "${PG_CONF_DIR}/conf.d/10-meta-gallery.conf"
    chmod 0644 "${PG_CONF_DIR}/conf.d/10-meta-gallery.conf"

    # pg_hba.conf: local=peer, 127.0.0.1/32=scram-sha-256 (계획서 1-5)
    hba_tmp="$(mktemp)"
    cat > "${hba_tmp}" <<'PGHBA'
# meta-gallery 관리 파일 (provision.sh 가 설치. 계획서 1-5)
# 외부 접속 항목을 추가하지 않는다. DB는 루프백 전용이다.
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
local   replication     all                                     peer
PGHBA
    if cmp -s "${hba_tmp}" "${PG_CONF_DIR}/pg_hba.conf"; then
        log "pg_hba.conf 변경 없음"
        rm -- "${hba_tmp}"
    else
        install_file "${hba_tmp}" "${PG_CONF_DIR}/pg_hba.conf" 0640 "${PG_SUPERUSER}:${PG_SUPERUSER}"
        rm -- "${hba_tmp}"
    fi
fi

run systemctl enable postgresql
log "PostgreSQL 재시작 (설정 반영)"
run systemctl restart postgresql

step "DB / 롤 생성 (metagallery_prod / metagallery_dev)"
if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] psql -f %s/postgres/init-databases.sql\n' "${SERVER_DIR}" >&2
else
    # 파일을 postgres 계정이 읽을 수 있는 임시 경로로 옮겨 실행한다.
    sql_tmp="$(mktemp /tmp/mg-init-XXXXXX.sql)"
    cat "${SERVER_DIR}/postgres/init-databases.sql" > "${sql_tmp}"
    chmod 0644 "${sql_tmp}"
    runuser -u "${PG_SUPERUSER}" -- psql -v ON_ERROR_STOP=1 -f "${sql_tmp}"
    rm -- "${sql_tmp}"
fi

# ---------------------------------------------------------------------------
# 7. 환경 파일 (DB 비밀번호 생성 — 커맨드라인·로그에 노출하지 않는다)
# ---------------------------------------------------------------------------
step "환경 파일 ${ETC_DIR}/{prod,dev}.env"
for env_name in prod dev; do
    env_file="${ETC_DIR}/${env_name}.env"
    example="${SERVER_DIR}/env/${env_name}.env.example"

    if [[ -f "${env_file}" ]]; then
        log "${env_file} 이미 있음 - 비밀번호를 바꾸지 않는다(기존 값 보존)"
        continue
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        printf '  [dry-run] 난수 비밀번호 생성 → ALTER ROLE mg_%s → %s 작성(0600)\n' \
            "${env_name}" "${env_file}" >&2
        continue
    fi

    db_pw="$(gen_password)"
    [[ ${#db_pw} -ge 32 ]] || die "비밀번호 생성 실패"

    # ALTER ROLE 은 stdin(heredoc)으로만 보낸다. 인자로 주면 ps 에 평문이 노출된다.
    # log_statement='none' 이라 서버 로그에도 남지 않는다.
    runuser -u "${PG_SUPERUSER}" -- psql -v ON_ERROR_STOP=1 -q <<SQL
SET log_statement = 'none';
ALTER ROLE mg_${env_name} WITH PASSWORD '${db_pw}';
SQL

    # 예시 파일의 자리표시자만 치환한다. 외부 명령을 쓰지 않아 argv 노출이 없다.
    umask 077
    : > "${env_file}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        printf '%s\n' "${line//__REPLACE_WITH_GENERATED_PASSWORD__/${db_pw}}"
    done < "${example}" >> "${env_file}"
    chown root:root "${env_file}"
    chmod 0600 "${env_file}"
    unset db_pw
    log "작성 완료: ${env_file} (0600 root:root)"

    if grep -q '__REPLACE_WITH_GENERATED_PASSWORD__' "${env_file}"; then
        die "${env_file} 에 자리표시자가 남아 있다. 예시 파일을 확인하라"
    fi
done

# 백업 스크립트 설정 파일 (S3 업로드용). 자격증명은 CEO/정보보호팀 확인 후 채운다.
step "백업 설정 ${ETC_DIR}/backup.env"
if [[ -f "${ETC_DIR}/backup.env" ]]; then
    log "이미 있음 - 건드리지 않는다"
elif [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] write %s/backup.env (S3_ENABLED=0)\n' "${ETC_DIR}" >&2
else
    umask 077
    cat > "${ETC_DIR}/backup.env" <<'BACKUPENV'
# meta-gallery 백업 설정 (backup-postgres.sh / logrotate 가 읽는다)
#   0600 root:root. 저장소에 커밋하지 않는다.
#
# S3 업로드를 켜려면 S3_ENABLED=1 로 바꾸고 버킷 이름과 자격증명을 채운다.
# Lightsail 인스턴스에는 IAM 인스턴스 역할을 붙일 수 없어 액세스 키가 필요하다.
# 전용 IAM 사용자(백업 버킷 PutObject 권한만)로 발급해야 하며,
# 키 발급·보관·교체 주기는 정보보호본부 애플리케이션보안팀 검토 대상이다(계획서 3-2).
S3_ENABLED=0
S3_BUCKET=
S3_PREFIX=postgres
AWS_DEFAULT_REGION=ap-southeast-2
# AWS_ACCESS_KEY_ID=
# AWS_SECRET_ACCESS_KEY=

# 로컬 보관 정책 (계획서 1-5)
RETENTION_DAYS=7
MIN_KEEP=3
BACKUPENV
    chmod 0600 "${ETC_DIR}/backup.env"
    log "작성 완료 (S3_ENABLED=0 으로 시작. 버킷·자격증명 확정 후 수정)"
fi

# ---------------------------------------------------------------------------
# 8. 스크립트 / systemd / logrotate 설치
# ---------------------------------------------------------------------------
step "운영 스크립트 설치 (/usr/local/sbin)"
install_file "${SERVER_DIR}/scripts/backup-postgres.sh"  /usr/local/sbin/backup-postgres.sh  0750
install_file "${SERVER_DIR}/scripts/restore-postgres.sh" /usr/local/sbin/restore-postgres.sh 0750
# healthcheck.sh 는 scripts/ops/ 에 있다(팀원4 담당 경로). 유닛의 ExecStart 가
# /usr/local/sbin/healthcheck.sh 를 가리키므로 여기서 같이 설치한다.
if [[ -f "${REPO_ROOT}/scripts/ops/healthcheck.sh" ]]; then
    install_file "${REPO_ROOT}/scripts/ops/healthcheck.sh" /usr/local/sbin/healthcheck.sh 0750
else
    warn "scripts/ops/healthcheck.sh 가 없다. 감시 타이머를 설치하지 않는다"
fi

step "systemd 유닛 설치"
install_file "${SERVER_DIR}/systemd/meta-gallery-api@.service"    /etc/systemd/system/meta-gallery-api@.service    0644
install_file "${SERVER_DIR}/systemd/meta-gallery-backup.service"  /etc/systemd/system/meta-gallery-backup.service  0644
install_file "${SERVER_DIR}/systemd/meta-gallery-backup.timer"    /etc/systemd/system/meta-gallery-backup.timer    0644
install_file "${SERVER_DIR}/systemd/meta-gallery-healthcheck.service" /etc/systemd/system/meta-gallery-healthcheck.service 0644
install_file "${SERVER_DIR}/systemd/meta-gallery-healthcheck.timer"   /etc/systemd/system/meta-gallery-healthcheck.timer   0644
run systemctl daemon-reload

log "백업 타이머 활성화 (매일 03:10 KST)"
run systemctl enable --now meta-gallery-backup.timer

# 감시 타이머(5분 주기). 2026-11-13 최초 적용 때 유닛 자체가 설치 목록에서
# 빠져 있어 감시가 돌지 않았다. 설치와 활성화를 함께 한다.
if [[ -x /usr/local/sbin/healthcheck.sh || ${DRY_RUN} -eq 1 ]]; then
    log "감시 타이머 활성화 (5분 주기)"
    run systemctl enable --now meta-gallery-healthcheck.timer
else
    warn "/usr/local/sbin/healthcheck.sh 가 없어 감시 타이머를 활성화하지 않았다"
fi

# API 유닛은 백엔드 코드가 없으므로 enable 하지 않는다(계획서 1-2).
log "meta-gallery-api@{prod,dev}.service 는 설치만 했다. enable/start 하지 않는다"
log "  백엔드팀이 ExecStart 를 확정한 뒤: systemctl enable --now meta-gallery-api@prod.service"

step "logrotate 설치"
install_file "${SERVER_DIR}/logrotate/meta-gallery" /etc/logrotate.d/meta-gallery 0644
if [[ ${DRY_RUN} -eq 0 ]]; then
    if logrotate -d /etc/logrotate.d/meta-gallery >/dev/null 2>&1; then
        log "logrotate 문법 확인 통과"
    else
        warn "logrotate -d 에서 경고/오류가 있다. 아래 명령으로 확인하라:"
        warn "  logrotate -d /etc/logrotate.d/meta-gallery"
    fi
fi

# ---------------------------------------------------------------------------
# 9. deploy 계정 sudoers (최소 권한. 계획서 1-2)
# ---------------------------------------------------------------------------
step "deploy sudoers"
if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] write /etc/sudoers.d/meta-gallery-deploy (visudo -c 검증 후)\n' >&2
else
    sudoers_tmp="$(mktemp)"
    cat > "${sudoers_tmp}" <<'SUDOERS'
# meta-gallery 배포 계정 최소 권한 (provision.sh 가 설치. 계획서 1-2)
#
# 릴리스 심볼릭 링크 교체에는 sudo 가 필요 없다. deploy 가 /srv/meta-gallery 를
# 소유하므로 자기 권한으로 ln -sfn 을 할 수 있다. 그래서 여기엔 넣지 않는다.
#
# 아래는 nginx 재적용만 허용한다. restart 가 아니라 reload 다(무중단).
Cmnd_Alias MG_NGINX = /usr/bin/systemctl reload nginx, \
                      /usr/bin/systemctl is-active nginx, \
                      /usr/bin/nginx -t
deploy ALL=(root) NOPASSWD: MG_NGINX

# 백엔드 코드가 생기면 API 재시작도 필요하다. 정보보호본부 애플리케이션보안팀
# 검토 후 아래 2줄의 주석을 해제한다(계획서 3-2).
# Cmnd_Alias MG_API = /usr/bin/systemctl restart meta-gallery-api@prod.service, \
#                     /usr/bin/systemctl restart meta-gallery-api@dev.service
# deploy ALL=(root) NOPASSWD: MG_API
SUDOERS
    if visudo -c -q -f "${sudoers_tmp}"; then
        install_file "${sudoers_tmp}" /etc/sudoers.d/meta-gallery-deploy 0440
    else
        rm -- "${sudoers_tmp}"
        die "sudoers 문법 검증 실패 - 설치하지 않았다"
    fi
    if [[ -f "${sudoers_tmp}" ]]; then
        rm -- "${sudoers_tmp}"
    fi
fi

# ---------------------------------------------------------------------------
# 10. nginx 검증 및 기동
# ---------------------------------------------------------------------------
step "nginx 설정 검증 및 적용"
if [[ ${DRY_RUN} -eq 1 ]]; then
    printf '  [dry-run] nginx -t && systemctl enable --now nginx && systemctl reload nginx\n' >&2
else
    if nginx -t; then
        log "nginx -t 통과"
        systemctl enable nginx
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
        else
            systemctl start nginx
        fi
        log "nginx 기동 완료 (STAGE 1: HTTP 80만. HTTPS 는 인증서 발급 후)"
    else
        die "nginx -t 실패. 설정을 확인하라 (사이트 링크는 설치된 상태다)"
    fi
fi

# ---------------------------------------------------------------------------
# 11. 요약
# ---------------------------------------------------------------------------
step "완료 요약"
cat >&2 <<SUMMARY

프로비저닝이 끝났습니다. 확인과 다음 단계는 아래와 같습니다.

[자체 확인]
  curl -sI http://127.0.0.1/healthz -H 'Host: ${PROD_HOST}'     # 200 ok
  curl -sI http://127.0.0.1/healthz -H 'Host: ${DEV_HOST}'      # 200 ok
  systemctl status nginx postgresql --no-pager
  systemctl list-timers meta-gallery-backup.timer --no-pager
  swapon --show
  runuser -u ${PG_SUPERUSER} -- psql -c '\\l'                     # DB 2개 확인
  /usr/local/sbin/backup-postgres.sh all --dry-run              # 백업 경로 점검

[다음 단계 — 이 스크립트가 하지 않는 일]
  1) DuckDNS 서브도메인 2개를 고정 IP로 연결 (팀원4 / CEO 계정 필요)
     - ${PROD_HOST}
     - ${DEV_HOST}
  2) HTTPS 인증서 발급: scripts/ops/issue-certificates.sh (webroot=${ACME_WEBROOT})
  3) 발급 후 nginx 설정에서 STAGE 2 블록 전환 (docs/infra/server-layout.md 참고)
  4) 백엔드 코드 확정 후 meta-gallery-api@.service 의 ExecStart 작성 → enable
  5) S3 백업 업로드: ${ETC_DIR}/backup.env 의 S3_ENABLED=1 + 버킷·자격증명

[전달/삭제 필요]
  ${ETC_DIR}/dev-basic-auth.txt  (개발계 Basic 인증 자격증명. 전달 후 삭제)

SUMMARY
log "provision.sh 정상 종료"
