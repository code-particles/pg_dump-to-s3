#!/usr/bin/env bash

#                     _                             _                  _____
#  _ __   __ _     __| |_   _ _ __ ___  _ __       | |_ ___        ___|___ /
# | '_ \ / _` |   / _` | | | | '_ ` _ \| '_ \ _____| __/ _ \ _____/ __| |_ \
# | |_) | (_| |  | (_| | |_| | | | | | | |_) |_____| || (_) |_____\__ \___) |
# | .__/ \__, |___\__,_|\__,_|_| |_| |_| .__/       \__\___/      |___/____/
# |_|    |___/_____|                   |_|
#
# Original Project at https://github.com/gabfl/pg_dump-to-s3
#

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

CONFIG_FILE="${HOME}/.pg_dump-to-s3.conf"
DEFAULT_CONFIG_FILE="$DIR/.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
elif [ -f "$DEFAULT_CONFIG_FILE" ]; then
    source "$DEFAULT_CONFIG_FILE"
else
    echo "Configuration file not found. Create $DEFAULT_CONFIG_FILE or $CONFIG_FILE."
    exit 1
fi

__usage="
USAGE:
  $(basename $0) [options] <db target> <s3 object>

OPTIONS:
  --latest           Restore the latest backup for <db target> (ignores <s3 object>)
  --list [prefix]    List available backups (optional prefix filter) and exit
  --dry-run          Print actions without downloading/restoring
  -h, --help         Show this help

EXAMPLE
  $(basename $0) service 2025-12-16-at-16-02-41_service.dump
  $(basename $0) --latest service
  $(basename $0) --list backups/
"

log() {
    [ "${QUIET:-0}" = "1" ] && return 0
    echo "$@"
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

command -v aws >/dev/null 2>&1 || fail "aws cli not found in PATH."
PG_RESTORE_BIN="${PG_RESTORE_BIN:-pg_restore}"
if [[ "$PG_RESTORE_BIN" =~ \  ]]; then
    command -v docker >/dev/null 2>&1 || fail "docker not found in PATH for PG_RESTORE_BIN override."
else
    command -v "$PG_RESTORE_BIN" >/dev/null 2>&1 || fail "pg_restore not found (set PG_RESTORE_BIN to override)."
fi
command -v psql >/dev/null 2>&1 || fail "psql not found in PATH."
command -v python3 >/dev/null 2>&1 || fail "python3 is required for latest backup selection."

REQUIRED_VARS=(PG_HOST PG_USER PG_PORT)
if [ -n "${S3_PATH:-}" ]; then
    REQUIRED_VARS+=(S3_PATH)
else
    REQUIRED_VARS+=(S3_BUCKET)
fi
for var in "${REQUIRED_VARS[@]}"; do
    [ -n "${!var:-}" ] || fail "Config variable $var is required."
done

resolve_s3_uri() {
    if [ -n "${S3_PATH:-}" ]; then
        local path="${S3_PATH%/}"
        echo "s3://${path}"
    else
        local prefix="${S3_PREFIX:-}"
        prefix="${prefix#/}"
        prefix="${prefix%/}"
        if [ -n "$prefix" ]; then
            echo "s3://${S3_BUCKET}/${prefix}"
        else
            echo "s3://${S3_BUCKET}"
        fi
    fi
}

S3_URI=$(resolve_s3_uri)
S3_BUCKET_NAME=$(echo "$S3_URI" | awk -F/ '{print $3}')
S3_PREFIX_PATH=$(echo "$S3_URI" | cut -d/ -f4-)

LIST_PREFIX=""
LIST_MODE=0
USE_LATEST=0
DRY_RUN="${DRY_RUN:-0}"
HEALTHCHECK_CMD="${HEALTHCHECK_CMD:-}"

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)
            USE_LATEST=1
            shift
            ;;
        --list)
            LIST_MODE=1
            # Optional prefix argument: if next token is not another flag, treat it as prefix
            if [[ $# -ge 2 && ! "$2" =~ ^-- ]]; then
                LIST_PREFIX="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            echo "$__usage"
            exit 0
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]-}"

if [ "$LIST_MODE" -eq 1 ]; then
    if [ -n "$LIST_PREFIX" ]; then
        log "Listing backups in ${S3_URI}/${LIST_PREFIX}"
        if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
            aws s3 ls "${S3_URI}/${LIST_PREFIX}" --endpoint-url "$AWS_ENDPOINT_URL"
        else
            aws s3 ls "${S3_URI}/${LIST_PREFIX}"
        fi
    else
        log "Listing backups in ${S3_URI}/"
        if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
            aws s3 ls "${S3_URI}/" --endpoint-url "$AWS_ENDPOINT_URL"
        else
            aws s3 ls "${S3_URI}/"
        fi
    fi
    exit 0
fi

if [ "$USE_LATEST" -eq 1 ]; then
    [ "$#" -ge 1 ] || { echo "$__usage"; exit 1; }
    TARGET_DB="$1"
else
    [ "$#" -ge 2 ] || { echo "$__usage"; exit 1; }
    TARGET_DB="$1"
    S3_OBJECT="$2"
fi

retry() {
    local attempts="${RETRY_ATTEMPTS:-3}"
    local base_sleep="${RETRY_BASE_SLEEP:-2}"
    local i=1
    while :; do
        "$@" && return 0
        if [ "$i" -ge "$attempts" ]; then
            return 1
        fi
        sleep_time=$((base_sleep ** i))
        log "   -> retry $i/$attempts after failure, sleeping ${sleep_time}s"
        sleep "$sleep_time"
        i=$((i+1))
    done
}

select_latest_object() {
    # Pick the latest .dump file by name using bash tools
    local list_cmd=("aws" "s3" "ls" "${S3_URI}/")
    if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
        list_cmd+=("--endpoint-url" "$AWS_ENDPOINT_URL")
    fi
    "${list_cmd[@]}" | awk '{print $4}' | grep -E '\.dump$' | sort | tail -n 1
}

if [ "$USE_LATEST" -eq 1 ]; then
    log "Selecting latest backup for database ${TARGET_DB}..."
    set +e
    S3_OBJECT=$(select_latest_object "$TARGET_DB")
    status=$?
    set -e
    [ "$status" -eq 0 ] || fail "No backup found for ${TARGET_DB}."
    log "Latest backup: ${S3_OBJECT}"
fi

TMP_DIR="${TMPDIR:-/tmp}"
LOCAL_BACKUP="${TMP_DIR}/${S3_OBJECT}"

S3_KEY="${S3_PREFIX_PATH:+${S3_PREFIX_PATH}/}${S3_OBJECT}"

log "Downloading s3://${S3_BUCKET_NAME}/${S3_KEY}..."
if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN: aws s3 cp s3://${S3_BUCKET_NAME}/${S3_KEY} ${LOCAL_BACKUP}"
else
    if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
        retry aws s3 cp "s3://${S3_BUCKET_NAME}/${S3_KEY}" "$LOCAL_BACKUP" --endpoint-url "$AWS_ENDPOINT_URL"
    else
        retry aws s3 cp "s3://${S3_BUCKET_NAME}/${S3_KEY}" "$LOCAL_BACKUP"
    fi
fi

DB_EXISTS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'")
if [ "$DB_EXISTS" = "1" ]; then
    log "Database ${TARGET_DB} already exists, skipping creation"
    if [ "$DRY_RUN" != "1" ]; then
        if [[ "$PG_RESTORE_BIN" =~ \  ]]; then
            bash -c "$PG_RESTORE_BIN -h \"$PG_HOST\" -U \"$PG_USER\" -p \"$PG_PORT\" -d \"$TARGET_DB\" -Fc --clean < \"$LOCAL_BACKUP\""
        else
            "$PG_RESTORE_BIN" -h "$PG_HOST" -U "$PG_USER" -p "$PG_PORT" -d "$TARGET_DB" -Fc --clean "$LOCAL_BACKUP"
        fi
    fi
else
    log "Creating database ${TARGET_DB}"
    if [ "$DRY_RUN" != "1" ]; then
        createdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -T template0 "$TARGET_DB"
        if [[ "$PG_RESTORE_BIN" =~ \  ]]; then
            bash -c "$PG_RESTORE_BIN -h \"$PG_HOST\" -U \"$PG_USER\" -p \"$PG_PORT\" -d \"$TARGET_DB\" -Fc < \"$LOCAL_BACKUP\""
        else
            "$PG_RESTORE_BIN" -h "$PG_HOST" -U "$PG_USER" -p "$PG_PORT" -d "$TARGET_DB" -Fc "$LOCAL_BACKUP"
        fi
    fi
fi

[ "$DRY_RUN" = "1" ] || rm -f "$LOCAL_BACKUP"

log "${S3_OBJECT} restored to database ${TARGET_DB}"

if [ "$DRY_RUN" != "1" ] && [ -n "$HEALTHCHECK_CMD" ]; then
    log " * Running healthcheck command"
    bash -c "$HEALTHCHECK_CMD" || fail "Healthcheck command failed"
fi
