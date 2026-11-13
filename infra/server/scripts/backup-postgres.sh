#!/usr/bin/env bash
# =============================================================================
# meta-gallery PostgreSQL 백업 (pg_dump -Fc → 로컬 7일 보관 → S3 업로드)
#
#   설치 위치 : /usr/local/sbin/backup-postgres.sh   (0750 root:root)
#   호출 주체 : meta-gallery-backup.service (매일 03:10 KST, timer)
#   사용법    : backup-postgres.sh [prod|dev|all] [옵션]
#     --no-s3      S3 업로드를 건너뛴다
#     --no-prune   로컬 보관기간 정리를 건너뛴다
#     --dry-run    실제 변경 없이 할 일만 출력한다
#
#   복구는 restore-postgres.sh 를 쓴다(이 스크립트는 복구하지 않는다).
#   설계 근거: docs/plans/2026-11-13-aws-infra.md 1-5
#
#   파일 삭제에 대하여: 보관기간 정리는 계획서가 요구한 "로컬 7일 보관"을 위해 꼭
#   필요하다. timer가 무인 실행하므로 확인 프롬프트를 둘 수 없는 대신,
#     (1) 정해진 디렉터리의 maxdepth 1 에서
#     (2) metagallery_<env>-*.dump 이름 패턴에만
#     (3) 최신 MIN_KEEP개는 나이와 무관하게 남기고
#     (4) S3 업로드가 성공했거나 S3가 꺼져 있을 때만
#   파일 하나씩 `rm --` 로 지운다. rm -rf / --force 는 쓰지 않는다.
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 기본값 (/etc/meta-gallery/backup.env 로 덮어쓸 수 있다)
# ---------------------------------------------------------------------------
BACKUP_ROOT="/var/backups/meta-gallery"
LOG_DIR="/var/log/meta-gallery"
LOG_FILE="${LOG_DIR}/backup.log"
LOCK_FILE="/var/lock/meta-gallery-backup.lock"
CONFIG_FILE="/etc/meta-gallery/backup.env"

RETENTION_DAYS=7          # 계획서 1-5: 로컬 7일 보관
MIN_KEEP=3                # 나이와 무관하게 남길 최신 덤프 개수(안전장치)
MIN_FREE_MB=512           # 덤프 전 최소 여유 디스크
S3_ENABLED=0              # backup.env 에서 1로 바꾸면 업로드한다
S3_BUCKET=""              # 예: <BACKUPS_BUCKET>
S3_PREFIX="postgres"      # s3://<bucket>/<prefix>/<env>/YYYY/MM/DD/
PG_SUPERUSER="postgres"

OPT_S3=1
OPT_PRUNE=1
DRY_RUN=0
TARGETS=()
PART_FILE=""

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S%z') [backup] $*"
    if [[ -d "${LOG_DIR}" && -w "${LOG_DIR}" ]]; then
        printf '%s\n' "${msg}" | tee -a "${LOG_FILE}" >&2
    else
        printf '%s\n' "${msg}" >&2
    fi
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local code=$?
    log "ERROR: 중단됨 (exit=${code}, line=${BASH_LINENO[0]})"
    if [[ -n "${PART_FILE}" && -f "${PART_FILE}" ]]; then
        log "미완성 파일 정리: ${PART_FILE}"
        rm -- "${PART_FILE}" 2>/dev/null || log "WARN: ${PART_FILE} 정리 실패 - 수동 확인 필요"
    fi
}
trap on_error ERR

usage() {
    # 파일 맨 위 주석 블록(= 사용법)만 출력한다. 줄 수가 바뀌어도 따라간다.
    sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# 인자 파싱
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        prod|dev) TARGETS+=("$1") ;;
        all)      TARGETS+=(prod dev) ;;
        --no-s3)    OPT_S3=0 ;;
        --no-prune) OPT_PRUNE=0 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  usage 0 ;;
        *) printf 'ERROR: 알 수 없는 인자: %s\n' "$1" >&2; usage 2 ;;
    esac
    shift
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    printf 'ERROR: 대상 환경을 지정하세요 (prod | dev | all)\n' >&2
    usage 2
fi

# ---------------------------------------------------------------------------
# 설정 파일 로드 (0600 root:root. AWS 자격증명과 버킷 이름이 들어 있다)
# ---------------------------------------------------------------------------
if [[ -r "${CONFIG_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "${CONFIG_FILE}"
    set +a
fi

[[ ${EUID} -eq 0 ]] || die "root 권한이 필요하다 (sudo ${0##*/} ...)"
command -v pg_dump  >/dev/null 2>&1 || die "pg_dump 를 찾을 수 없다 (postgresql-client 미설치?)"
command -v runuser  >/dev/null 2>&1 || die "runuser 를 찾을 수 없다"

mkdir -p "${LOG_DIR}"
chmod 0750 "${LOG_DIR}"

# ---------------------------------------------------------------------------
# 중복 실행 방지 (타이머와 수동 실행이 겹치지 않게)
# ---------------------------------------------------------------------------
if [[ "${META_GALLERY_BACKUP_LOCKED:-0}" != "1" ]]; then
    if command -v flock >/dev/null 2>&1; then
        export META_GALLERY_BACKUP_LOCKED=1
        exec flock -n "${LOCK_FILE}" "$0" "$@"
    else
        log "WARN: flock 없음 - 중복 실행 방지를 건너뛴다"
    fi
fi

# ---------------------------------------------------------------------------
# 한 환경 백업
# ---------------------------------------------------------------------------
backup_one() {
    local env="$1"
    local db="metagallery_${env}"
    local dir="${BACKUP_ROOT}/${env}"
    local stamp out free_mb uploaded=0

    stamp="$(date '+%Y%m%dT%H%M%S%z')"
    out="${dir}/${db}-${stamp}.dump"

    log "=== ${env} 백업 시작 (db=${db}) ==="

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "[dry-run] mkdir -p ${dir}"
        log "[dry-run] pg_dump -Fc ${db} > ${out}"
    else
        mkdir -p "${dir}"
        chmod 0700 "${dir}"

        # DB 존재 확인 (없으면 조용히 실패하지 않고 분명히 알린다)
        if ! runuser -u "${PG_SUPERUSER}" -- psql -tAc \
                "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
            die "데이터베이스 ${db} 가 없다. init-databases.sql 을 먼저 실행했는지 확인하라"
        fi

        free_mb="$(df -Pm "${dir}" | awk 'NR==2 {print $4}')"
        if [[ -n "${free_mb}" && "${free_mb}" -lt "${MIN_FREE_MB}" ]]; then
            die "여유 디스크 ${free_mb}MB < ${MIN_FREE_MB}MB. 백업을 중단한다"
        fi

        # pg_dump 는 postgres 권한으로 실행하고, 출력 리다이렉트는 root가 한다.
        # (백업 디렉터리는 0700 root 유지. postgres 계정에 쓰기 권한을 주지 않는다)
        PART_FILE="${out}.part"
        umask 077
        runuser -u "${PG_SUPERUSER}" -- pg_dump --format=custom --compress=6 \
            --no-password --dbname="${db}" > "${PART_FILE}"

        [[ -s "${PART_FILE}" ]] || die "덤프 파일이 비어 있다: ${PART_FILE}"

        mv -- "${PART_FILE}" "${out}"
        PART_FILE=""
        chmod 0600 "${out}"

        ( cd "${dir}" && sha256sum "$(basename "${out}")" > "$(basename "${out}").sha256" )
        chmod 0600 "${out}.sha256"
        log "덤프 완료: ${out} ($(du -h "${out}" | cut -f1))"
    fi

    # --- S3 업로드 ---
    if [[ ${OPT_S3} -eq 1 && "${S3_ENABLED}" = "1" ]]; then
        [[ -n "${S3_BUCKET}" ]] || die "S3_ENABLED=1 인데 S3_BUCKET 이 비어 있다 (${CONFIG_FILE})"
        command -v aws >/dev/null 2>&1 || die "aws CLI 를 찾을 수 없다"

        local key_dir
        key_dir="s3://${S3_BUCKET}/${S3_PREFIX}/${env}/$(date '+%Y/%m/%d')"

        if [[ ${DRY_RUN} -eq 1 ]]; then
            log "[dry-run] aws s3 cp ${out} ${key_dir}/"
        else
            log "S3 업로드: ${key_dir}/$(basename "${out}")"
            aws s3 cp "${out}"           "${key_dir}/" --only-show-errors --no-progress
            aws s3 cp "${out}.sha256"    "${key_dir}/" --only-show-errors --no-progress
            uploaded=1
            log "S3 업로드 완료"
        fi
    elif [[ ${OPT_S3} -eq 0 ]]; then
        log "S3 업로드 건너뜀 (--no-s3)"
    else
        log "S3 업로드 건너뜀 (S3_ENABLED != 1). 설정: ${CONFIG_FILE}"
    fi

    # --- 로컬 보관기간 정리 ---
    if [[ ${OPT_PRUNE} -eq 1 ]]; then
        if [[ "${S3_ENABLED}" = "1" && ${OPT_S3} -eq 1 && ${uploaded} -eq 0 && ${DRY_RUN} -eq 0 ]]; then
            log "WARN: S3 업로드가 확인되지 않아 로컬 정리를 건너뛴다"
        else
            prune_old "${env}" "${dir}"
        fi
    else
        log "로컬 정리 건너뜀 (--no-prune)"
    fi

    log "=== ${env} 백업 종료 ==="
}

# ---------------------------------------------------------------------------
# 보관기간 정리 — 안전장치를 모두 통과한 파일만 하나씩 지운다
# ---------------------------------------------------------------------------
prune_old() {
    local env="$1" dir="$2"
    local pattern="metagallery_${env}-*.dump"
    local files=() idx=0 f

    # 안전장치: 경로 변수가 비었거나 예상 경로를 벗어나면 아무것도 지우지 않는다.
    [[ -n "${BACKUP_ROOT}" ]] || die "BACKUP_ROOT 가 비어 있다 - 정리 중단"
    [[ "${dir}" == "${BACKUP_ROOT}/${env}" ]] || die "정리 대상 경로가 예상과 다르다: ${dir}"
    [[ -d "${dir}" ]] || { log "정리 대상 디렉터리 없음: ${dir}"; return 0; }

    # 최신순 목록 (GNU find 의 -printf 사용. 대상 OS는 Ubuntu 24.04)
    while IFS= read -r f; do
        [[ -n "${f}" ]] && files+=("${f}")
    done < <(find "${dir}" -maxdepth 1 -type f -name "${pattern}" -printf '%T@ %p\n' \
             | sort -rn | awk '{ $1=""; sub(/^ /, ""); print }')

    log "보관 중인 ${env} 덤프 ${#files[@]}개 (보관 ${RETENTION_DAYS}일 / 최신 ${MIN_KEEP}개는 항상 유지)"

    for f in "${files[@]}"; do
        idx=$((idx + 1))
        if [[ ${idx} -le ${MIN_KEEP} ]]; then
            continue
        fi
        # 나이 확인: RETENTION_DAYS 보다 오래된 것만
        if find "${f}" -maxdepth 0 -mtime "+${RETENTION_DAYS}" -print -quit | grep -q .; then
            if [[ ${DRY_RUN} -eq 1 ]]; then
                log "[dry-run] 삭제 대상: ${f}"
            else
                log "보관기간 초과 삭제: ${f}"
                rm -- "${f}" || log "WARN: 삭제 실패 ${f}"
                if [[ -f "${f}.sha256" ]]; then
                    rm -- "${f}.sha256" || log "WARN: 삭제 실패 ${f}.sha256"
                fi
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
main() {
    log "시작: 대상=${TARGETS[*]} dry_run=${DRY_RUN} s3=${OPT_S3}/${S3_ENABLED} prune=${OPT_PRUNE}"
    local env
    for env in "${TARGETS[@]}"; do
        backup_one "${env}"
    done
    log "전체 완료"
}

main
