#!/usr/bin/env bash
# =============================================================================
# meta-gallery PostgreSQL 복구 (pg_restore)
#
#   설치 위치 : /usr/local/sbin/restore-postgres.sh   (0750 root:root)
#   사용법    : restore-postgres.sh --file <덤프> (--into-new <새DB> | --overwrite <prod|dev>) [옵션]
#
#   모드
#     --into-new <새DB>   새 DB를 만들어 복구한다. 기존 DB를 건드리지 않는다(권장).
#     --overwrite <env>   metagallery_<env> 의 기존 객체를 지우고 덮어쓴다(되돌릴 수 없다).
#
#   옵션
#     --list                  덤프 안의 객체 목록만 출력하고 끝낸다(변경 없음)
#     --disconnect-sessions   복구 전 대상 DB의 기존 접속을 끊는다(--overwrite 전용)
#     --skip-safety-dump      복구 전 안전 백업을 생략한다(권장하지 않음)
#     --allow-cross-env       prod 덤프를 dev에, dev 덤프를 prod에 넣는 것을 허용한다
#     --confirm-db <DB이름>   비대화식 실행용. 덮어쓸 DB 이름을 정확히 적어야 한다.
#                             추가로 META_GALLERY_RESTORE_CONFIRM=yes 환경변수도 필요하다.
#     --dry-run               실제 변경 없이 수행할 단계만 출력한다
#
#   !! --overwrite 는 대상 DB의 테이블·데이터를 삭제한다. 그래서
#      (1) 대화식이면 DB 이름을 손으로 똑같이 입력해야 하고
#      (2) 비대화식이면 --confirm-db 와 환경변수 두 개가 동시에 맞아야 하며
#      (3) 그 전에 자동으로 안전 백업을 하나 더 뜬다.
#      --force 류 플래그는 제공하지 않는다.
#
#   !! 개발계에 운영 데이터를 복사하지 않는다(계획서 3-2). 환경이 다르면 기본적으로
#      거부하고, --allow-cross-env 를 명시해야 진행한다.
#
#   설계 근거: docs/plans/2026-11-13-aws-infra.md 1-5 / docs/infra/server-layout.md
# =============================================================================
set -Eeuo pipefail

BACKUP_ROOT="/var/backups/meta-gallery"
LOG_DIR="/var/log/meta-gallery"
LOG_FILE="${LOG_DIR}/backup.log"
PG_SUPERUSER="postgres"

DUMP_FILE=""
MODE=""
TARGET_DB=""
TARGET_ENV=""
NEW_DB=""
DO_LIST=0
DO_DISCONNECT=0
DO_SAFETY_DUMP=1
ALLOW_CROSS_ENV=0
CONFIRM_DB=""
DRY_RUN=0

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S%z') [restore] $*"
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

usage() {
    # 파일 맨 위 주석 블록(= 사용법)만 출력한다. 줄 수가 바뀌어도 따라간다.
    sed -n '2,/^set -/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

run_psql() {
    runuser -u "${PG_SUPERUSER}" -- psql -v ON_ERROR_STOP=1 -q "$@"
}

# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)       DUMP_FILE="${2:?--file 값 필요}"; shift ;;
        --into-new)   MODE="into-new"; NEW_DB="${2:?--into-new 값 필요}"; shift ;;
        --overwrite)  MODE="overwrite"; TARGET_ENV="${2:?--overwrite 값 필요}"; shift ;;
        --list)                 DO_LIST=1 ;;
        --disconnect-sessions)  DO_DISCONNECT=1 ;;
        --skip-safety-dump)     DO_SAFETY_DUMP=0 ;;
        --allow-cross-env)      ALLOW_CROSS_ENV=1 ;;
        --confirm-db) CONFIRM_DB="${2:?--confirm-db 값 필요}"; shift ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)    usage 0 ;;
        *) printf 'ERROR: 알 수 없는 인자: %s\n' "$1" >&2; usage 2 ;;
    esac
    shift
done

[[ -n "${DUMP_FILE}" ]] || { printf 'ERROR: --file 이 필요하다\n' >&2; usage 2; }
[[ -f "${DUMP_FILE}" ]] || die "덤프 파일이 없다: ${DUMP_FILE}"
[[ ${EUID} -eq 0 ]] || die "root 권한이 필요하다 (sudo ${0##*/} ...)"
command -v pg_restore >/dev/null 2>&1 || die "pg_restore 를 찾을 수 없다"
command -v runuser    >/dev/null 2>&1 || die "runuser 를 찾을 수 없다"

mkdir -p "${LOG_DIR}"; chmod 0750 "${LOG_DIR}"

# ---------------------------------------------------------------------------
# 1. 덤프 무결성 확인
# ---------------------------------------------------------------------------
if [[ -f "${DUMP_FILE}.sha256" ]]; then
    log "체크섬 확인: ${DUMP_FILE}.sha256"
    ( cd "$(dirname "${DUMP_FILE}")" && sha256sum -c "$(basename "${DUMP_FILE}").sha256" ) \
        || die "체크섬 불일치. 손상된 덤프일 수 있다"
else
    log "WARN: 체크섬 파일이 없다 (${DUMP_FILE}.sha256) - 무결성 확인 생략"
fi

if [[ ${DO_LIST} -eq 1 ]]; then
    log "덤프 목차 출력 (변경 없음)"
    pg_restore --list "${DUMP_FILE}"
    exit 0
fi

[[ -n "${MODE}" ]] || { printf 'ERROR: --into-new 또는 --overwrite 중 하나가 필요하다\n' >&2; usage 2; }

# ---------------------------------------------------------------------------
# 2. 덤프의 원본 환경 추론 (파일명 규칙: metagallery_<env>-<stamp>.dump)
# ---------------------------------------------------------------------------
SOURCE_ENV="unknown"
case "$(basename "${DUMP_FILE}")" in
    metagallery_prod-*) SOURCE_ENV="prod" ;;
    metagallery_dev-*)  SOURCE_ENV="dev"  ;;
esac
log "덤프 원본 환경 추정: ${SOURCE_ENV} (파일명 기준)"

# ---------------------------------------------------------------------------
# 3. 대상 결정 + 교차 환경 차단
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "overwrite" ]]; then
    case "${TARGET_ENV}" in
        prod|dev) : ;;
        *) die "--overwrite 값은 prod 또는 dev 여야 한다 (받은 값: ${TARGET_ENV})" ;;
    esac
    TARGET_DB="metagallery_${TARGET_ENV}"
    TARGET_ROLE="mg_${TARGET_ENV}"
else
    TARGET_DB="${NEW_DB}"
    # 새 DB의 소유 롤은 덤프 원본 환경을 따른다. 알 수 없으면 postgres가 소유한다.
    if [[ "${SOURCE_ENV}" == "unknown" ]]; then
        TARGET_ROLE="${PG_SUPERUSER}"
    else
        TARGET_ROLE="mg_${SOURCE_ENV}"
    fi
    [[ "${TARGET_DB}" =~ ^[a-z_][a-z0-9_]*$ ]] \
        || die "--into-new DB 이름은 소문자·숫자·밑줄만 쓴다: ${TARGET_DB}"
    if [[ "${TARGET_DB}" == "metagallery_prod" || "${TARGET_DB}" == "metagallery_dev" ]]; then
        die "--into-new 로 운영 중인 DB 이름을 쓸 수 없다. 덮어쓰려면 --overwrite 를 쓴다"
    fi
fi

if [[ "${MODE}" == "overwrite" && "${SOURCE_ENV}" != "unknown" && "${SOURCE_ENV}" != "${TARGET_ENV}" ]]; then
    if [[ ${ALLOW_CROSS_ENV} -eq 1 ]]; then
        log "WARN: 교차 환경 복구 (${SOURCE_ENV} 덤프 → ${TARGET_ENV}). 운영 데이터를 개발계로 복사하는 것은 계획서 3-2 위반이다. 정보보호팀 승인 여부를 확인하라"
    else
        die "교차 환경 복구는 기본 차단이다 (${SOURCE_ENV} 덤프 → ${TARGET_ENV}). 꼭 필요하면 --allow-cross-env 를 붙이고 사유를 남겨라"
    fi
fi

log "복구 계획: 파일=${DUMP_FILE} 모드=${MODE} 대상DB=${TARGET_DB} 소유롤=${TARGET_ROLE}"

# ---------------------------------------------------------------------------
# 4. 되돌릴 수 없는 작업에 대한 확인 (--overwrite 전용)
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "overwrite" && ${DRY_RUN} -eq 0 ]]; then
    printf '\n'
    printf '*** 경고: 되돌릴 수 없는 작업 ***\n' >&2
    printf '  대상 DB   : %s\n' "${TARGET_DB}" >&2
    printf '  동작      : 기존 테이블·데이터를 삭제하고 덤프 내용으로 교체(pg_restore --clean)\n' >&2
    printf '  덤프 파일 : %s\n' "${DUMP_FILE}" >&2
    printf '\n' >&2

    if [[ -n "${CONFIRM_DB}" ]]; then
        [[ "${META_GALLERY_RESTORE_CONFIRM:-no}" == "yes" ]] \
            || die "비대화식 확인에는 META_GALLERY_RESTORE_CONFIRM=yes 도 필요하다"
        [[ "${CONFIRM_DB}" == "${TARGET_DB}" ]] \
            || die "--confirm-db 값(${CONFIRM_DB})이 대상 DB(${TARGET_DB})와 다르다"
        log "비대화식 확인 통과 (--confirm-db + META_GALLERY_RESTORE_CONFIRM)"
    else
        [[ -t 0 ]] || die "대화식 입력이 불가능하다. --confirm-db <DB이름> 와 META_GALLERY_RESTORE_CONFIRM=yes 를 쓰라"
        printf '계속하려면 대상 DB 이름을 정확히 입력하세요 (%s): ' "${TARGET_DB}" >&2
        read -r answer
        [[ "${answer}" == "${TARGET_DB}" ]] || die "입력이 일치하지 않는다. 복구를 취소했다"
        printf "마지막 확인입니다. 'RESTORE' 를 입력하세요: " >&2
        read -r answer2
        [[ "${answer2}" == "RESTORE" ]] || die "확인 문구가 일치하지 않는다. 복구를 취소했다"
        log "대화식 확인 통과"
    fi
fi

# ---------------------------------------------------------------------------
# 5. 복구 전 안전 백업
# ---------------------------------------------------------------------------
db_exists() {
    runuser -u "${PG_SUPERUSER}" -- psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '$1'" | grep -q 1
}

if [[ "${MODE}" == "overwrite" && ${DO_SAFETY_DUMP} -eq 1 ]]; then
    if db_exists "${TARGET_DB}"; then
        safety_dir="${BACKUP_ROOT}/${TARGET_ENV}"
        safety="${safety_dir}/${TARGET_DB}-pre-restore-$(date '+%Y%m%dT%H%M%S%z').dump"
        if [[ ${DRY_RUN} -eq 1 ]]; then
            log "[dry-run] 안전 백업: ${safety}"
        else
            mkdir -p "${safety_dir}"; chmod 0700 "${safety_dir}"
            umask 077
            log "복구 전 안전 백업 중: ${safety}"
            runuser -u "${PG_SUPERUSER}" -- pg_dump --format=custom --compress=6 \
                --no-password --dbname="${TARGET_DB}" > "${safety}"
            [[ -s "${safety}" ]] || die "안전 백업이 비어 있다. 복구를 중단한다"
            log "안전 백업 완료 ($(du -h "${safety}" | cut -f1)). 문제가 생기면 이 파일로 되돌린다"
        fi
    else
        log "대상 DB ${TARGET_DB} 가 아직 없다 - 안전 백업 생략"
    fi
elif [[ "${MODE}" == "overwrite" ]]; then
    log "WARN: --skip-safety-dump 지정됨. 복구 전 백업 없이 진행한다"
fi

# ---------------------------------------------------------------------------
# 6. 복구
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "into-new" ]]; then
    if db_exists "${TARGET_DB}"; then
        die "DB ${TARGET_DB} 가 이미 있다. 덮어쓰지 않는다. 다른 이름을 쓰거나 --overwrite 를 쓰라"
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "[dry-run] CREATE DATABASE ${TARGET_DB} OWNER postgres"
        log "[dry-run] pg_restore --dbname=${TARGET_DB} --no-owner --role=${TARGET_ROLE} ${DUMP_FILE}"
        exit 0
    fi
    log "새 DB 생성: ${TARGET_DB}"
    run_psql -c "CREATE DATABASE ${TARGET_DB} OWNER ${PG_SUPERUSER} ENCODING 'UTF8' TEMPLATE template0"
    run_psql -d "${TARGET_DB}" -c "REVOKE ALL ON DATABASE ${TARGET_DB} FROM PUBLIC"
    if [[ "${TARGET_ROLE}" != "${PG_SUPERUSER}" ]]; then
        run_psql -c "GRANT CONNECT, TEMPORARY ON DATABASE ${TARGET_DB} TO ${TARGET_ROLE}"
    fi
    log "pg_restore 시작 (새 DB라 --clean 을 쓰지 않는다)"
    runuser -u "${PG_SUPERUSER}" -- pg_restore --dbname="${TARGET_DB}" \
        --no-owner --role="${TARGET_ROLE}" --no-privileges --exit-on-error "${DUMP_FILE}"
    log "복구 완료: ${TARGET_DB} (원본 DB는 변경되지 않았다)"
else
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "[dry-run] (옵션) 세션 종료 → pg_restore --clean --if-exists --dbname=${TARGET_DB}"
        exit 0
    fi
    db_exists "${TARGET_DB}" || die "대상 DB ${TARGET_DB} 가 없다. init-databases.sql 을 먼저 실행하라"

    if [[ ${DO_DISCONNECT} -eq 1 ]]; then
        log "대상 DB 기존 접속 종료 (--disconnect-sessions)"
        run_psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                     WHERE datname = '${TARGET_DB}' AND pid <> pg_backend_pid()" >/dev/null
    else
        log "기존 접속을 끊지 않는다. 잠금 충돌이 나면 API를 멈추거나 --disconnect-sessions 를 쓰라"
        log "  예) systemctl stop meta-gallery-api@${TARGET_ENV}.service"
    fi

    log "pg_restore 시작 (--clean --if-exists: 기존 객체를 지우고 다시 만든다)"
    runuser -u "${PG_SUPERUSER}" -- pg_restore --dbname="${TARGET_DB}" \
        --clean --if-exists --no-owner --role="${TARGET_ROLE}" --exit-on-error "${DUMP_FILE}"
    log "복구 완료: ${TARGET_DB}"
    log "확인 권장: systemctl status meta-gallery-api@${TARGET_ENV}.service, 애플리케이션 동작 점검"
fi
