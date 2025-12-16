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

# Capture any env-provided STORAGE_CLASS (including empty) before config sourcing
STORAGE_CLASS_PRESET="${STORAGE_CLASS-}"
STORAGE_CLASS_PRESET_SET="${STORAGE_CLASS+x}"

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

# Re-apply env override for STORAGE_CLASS if it was set (even to empty)
if [ "$STORAGE_CLASS_PRESET_SET" = "y" ] || [ "$STORAGE_CLASS_PRESET_SET" = "x" ]; then
    STORAGE_CLASS="$STORAGE_CLASS_PRESET"
fi

log() {
    [ "${QUIET:-0}" = "1" ] && return 0
    echo "$@"
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required for portable retention handling."
command -v aws >/dev/null 2>&1 || fail "aws cli not found in PATH."
PG_DUMP_BIN="${PG_DUMP_BIN:-pg_dump}"
# Allow compound commands (e.g., 'docker exec ... pg_dump') by skipping command -v when spaces are present
if [[ "$PG_DUMP_BIN" =~ \  ]]; then
    command -v docker >/dev/null 2>&1 || fail "docker not found in PATH for PG_DUMP_BIN override."
else
    command -v "$PG_DUMP_BIN" >/dev/null 2>&1 || fail "pg_dump not found (set PG_DUMP_BIN to override)."
fi
command -v shasum >/dev/null 2>&1 || fail "shasum (sha256) not found in PATH."

REQUIRED_VARS=(PG_HOST PG_USER PG_PORT PG_DATABASES DELETE_AFTER)
if [ -n "${S3_PATH:-}" ]; then
    REQUIRED_VARS+=(S3_PATH)
else
    REQUIRED_VARS+=(S3_BUCKET)
fi
for var in "${REQUIRED_VARS[@]}"; do
    [ -n "${!var:-}" ] || fail "Config variable $var is required."
done

TMP_DIR="${TMPDIR:-/tmp}"
MIN_FREE_MB="${MIN_FREE_MB:-512}"
STORAGE_CLASS="${STORAGE_CLASS-}"
PG_DUMP_COMPRESSION="${PG_DUMP_COMPRESSION:-0}"
DRY_RUN="${DRY_RUN:-0}"
HEALTHCHECK_CMD="${HEALTHCHECK_CMD:-}"

[ "$PG_DUMP_COMPRESSION" -ge 0 ] 2>/dev/null || fail "PG_DUMP_COMPRESSION must be an integer between 0-9."
[ "$PG_DUMP_COMPRESSION" -le 9 ] 2>/dev/null || fail "PG_DUMP_COMPRESSION must be an integer between 0-9."

RETENTION_DAYS_RAW="${DELETE_AFTER%% *}"
[[ "$RETENTION_DAYS_RAW" =~ ^[0-9]+$ ]] || fail "DELETE_AFTER must start with a number of days (e.g. '7' or '7 days')."
RETENTION_DAYS="$RETENTION_DAYS_RAW"

RETENTION_THRESHOLD_TS=$(python3 - <<PY
import time
days = int("$RETENTION_DAYS")
print(int(time.time() - days * 86400))
PY
)

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

check_disk_space() {
    local avail_kb
    avail_kb=$(df -Pk "$TMP_DIR" | awk 'NR==2 {print $4}')
    local avail_mb=$((avail_kb / 1024))
    [ "$avail_mb" -ge "$MIN_FREE_MB" ] || fail "Not enough free space in $TMP_DIR (available ${avail_mb}MB, need >= ${MIN_FREE_MB}MB)."
}

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

cleanup_files=()
cleanup() {
    for f in "${cleanup_files[@]}"; do
        [ -f "$f" ] && rm -f "$f"
    done
}
trap cleanup EXIT

IFS=',' read -ra DBS <<< "$PG_DATABASES"
if [ -n "${PG_DATABASES_EXCLUDE:-}" ]; then
    IFS=',' read -ra EXCLUDES <<< "$PG_DATABASES_EXCLUDE"
    filtered=()
    for db in "${DBS[@]}"; do
        skip=0
        for ex in "${EXCLUDES[@]}"; do
            [ "$db" = "$ex" ] && skip=1 && break
        done
        [ "$skip" -eq 0 ] && filtered+=("$db")
    done
    DBS=("${filtered[@]}")
fi
[ "${#DBS[@]}" -gt 0 ] || fail "No databases to back up after applying exclusions."

NOW=$(date +"%Y-%m-%d-at-%H-%M-%S")

log " * Backup in progress..."
check_disk_space

for db in "${DBS[@]}"; do
    FILENAME="${NOW}_${db}"
    BACKUP_FILE="${TMP_DIR}/${FILENAME}.dump"
    CHECKSUM_FILE="${BACKUP_FILE}.sha256"
    cleanup_files+=("$BACKUP_FILE" "$CHECKSUM_FILE")

    log "   -> backing up ${db}..."

    if [ "$DRY_RUN" = "1" ]; then
        log "      DRY RUN: ${PG_DUMP_BIN} -Fc -Z ${PG_DUMP_COMPRESSION} -h ${PG_HOST} -U ${PG_USER} -p ${PG_PORT} ${db} > ${BACKUP_FILE}"
        log "      DRY RUN: aws s3 cp ${BACKUP_FILE} ${S3_URI}/${FILENAME}.dump"
    else
        if [[ "$PG_DUMP_BIN" =~ \  ]]; then
            bash -c "$PG_DUMP_BIN -Fc -Z \"$PG_DUMP_COMPRESSION\" -h \"$PG_HOST\" -U \"$PG_USER\" -p \"$PG_PORT\" \"$db\" > \"$BACKUP_FILE\""
        else
            "$PG_DUMP_BIN" -Fc -Z "$PG_DUMP_COMPRESSION" -h "$PG_HOST" -U "$PG_USER" -p "$PG_PORT" "$db" > "$BACKUP_FILE"
        fi

        CHECKSUM=$(shasum -a 256 "$BACKUP_FILE" | awk '{print $1}')
        echo "${CHECKSUM}  ${FILENAME}.dump" > "$CHECKSUM_FILE"

        AWS_CP_ARGS=()
        # When using custom endpoints (e.g., MinIO), pass it explicitly
        if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
            AWS_CP_ARGS+=(--endpoint-url "$AWS_ENDPOINT_URL")
        fi
        [ -n "${STORAGE_CLASS:-}" ] && AWS_CP_ARGS+=(--storage-class "$STORAGE_CLASS")
        [ -n "${S3_SSE:-}" ] && AWS_CP_ARGS+=(--sse "$S3_SSE")
        [ -n "${S3_SSE_KMS_KEY_ID:-}" ] && AWS_CP_ARGS+=(--sse-kms-key-id "$S3_SSE_KMS_KEY_ID")
        AWS_CP_ARGS+=(--metadata "sha256=${CHECKSUM}")

        S3_KEY="${S3_PREFIX_PATH:+${S3_PREFIX_PATH}/}${FILENAME}.dump"
        S3_KEY_SHA="${S3_KEY}.sha256"

        retry aws s3 cp "$BACKUP_FILE" "s3://${S3_BUCKET_NAME}/${S3_KEY}" "${AWS_CP_ARGS[@]}"
        retry aws s3 cp "$CHECKSUM_FILE" "s3://${S3_BUCKET_NAME}/${S3_KEY_SHA}" "${AWS_CP_ARGS[@]}"

        if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
            META_SHA=$(retry aws s3api head-object --bucket "$S3_BUCKET_NAME" --key "$S3_KEY" --query 'Metadata.sha256' --output text --endpoint-url "$AWS_ENDPOINT_URL")
        else
            META_SHA=$(retry aws s3api head-object --bucket "$S3_BUCKET_NAME" --key "$S3_KEY" --query 'Metadata.sha256' --output text)
        fi
        if [ "$META_SHA" != "$CHECKSUM" ]; then
            fail "Checksum metadata mismatch for ${FILENAME}.dump (expected ${CHECKSUM}, got ${META_SHA})."
        fi
    fi

    log "      ...database ${db} has been backed up"
done

if [ "$DRY_RUN" = "1" ]; then
    log " * Skipping deletion of old backups (DRY_RUN=1)"
else
    log " * Deleting old backups..."
    if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
        aws s3 ls "${S3_URI}/" --endpoint-url "$AWS_ENDPOINT_URL"
    else
        aws s3 ls "${S3_URI}/"
    fi | while read -r line; do
        [ -z "$line" ] && continue
        FILENAME=$(echo "$line" | awk '{print $4}')
        [ -z "$FILENAME" ] && continue

        createDate=$(echo "$line" | awk '{print $1" "$2}')
        FILE_TS=$(python3 - <<PY
import datetime
from datetime import timezone
ts = "$createDate"
try:
    dt = datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    print("")
PY
)
        [ -z "$FILE_TS" ] && { log "   -> skipping $FILENAME (could not parse date: $createDate)"; continue; }

        if [ "$FILE_TS" -lt "$RETENTION_THRESHOLD_TS" ]; then
            log "   -> Deleting $FILENAME"
            if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
                aws s3 rm "${S3_URI}/${FILENAME}" --endpoint-url "$AWS_ENDPOINT_URL"
            else
                aws s3 rm "${S3_URI}/${FILENAME}"
            fi
        fi
    done
fi

if [ "$DRY_RUN" != "1" ] && [ -n "$HEALTHCHECK_CMD" ]; then
    log " * Running healthcheck command"
    bash -c "$HEALTHCHECK_CMD" || fail "Healthcheck command failed"
fi

log ""
log "...done!"
log ""
