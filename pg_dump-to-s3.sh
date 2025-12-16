#!/usr/bin/env bash

#                     _                             _                  _____
#  _ __   __ _     __| |_   _ _ __ ___  _ __       | |_ ___        ___|___ /
# | '_ \ / _` |   / _` | | | | '_ ` _ \| '_ \ _____| __/ _ \ _____/ __| |_ \
# | |_) | (_| |  | (_| | |_| | | | | | | |_) |_____| || (_) |_____\__ \___) |
# | .__/ \__, |___\__,_|\__,_|_| |_| |_| .__/       \__\___/      |___/____/
# |_|    |___/_____|                   |_|
#
# Project at https://github.com/gabfl/pg_dump-to-s3
#

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
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

fail() {
    echo "Error: $1" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required for cross-platform date handling."
command -v aws >/dev/null 2>&1 || fail "aws cli not found in PATH."
command -v pg_dump >/dev/null 2>&1 || fail "pg_dump not found in PATH."

REQUIRED_VARS=(PG_HOST PG_USER PG_PORT PG_DATABASES S3_PATH DELETE_AFTER)
for var in "${REQUIRED_VARS[@]}"; do
    [ -n "${!var:-}" ] || fail "Config variable $var is required."
done

# Normalize retention in days (takes first numeric token, e.g. '7 days' -> 7)
RETENTION_DAYS_RAW="${DELETE_AFTER%% *}"
[[ "$RETENTION_DAYS_RAW" =~ ^[0-9]+$ ]] || fail "DELETE_AFTER must start with a number of days (e.g. '7 days' or '14')."
RETENTION_DAYS="$RETENTION_DAYS_RAW"

RETENTION_THRESHOLD_TS=$(python3 - <<PY
import time
days = int("$RETENTION_DAYS")
print(int(time.time() - days * 86400))
PY
)

NOW=$(date +"%Y-%m-%d-at-%H-%M-%S")
TMP_DIR="${TMPDIR:-/tmp}"
STORAGE_CLASS="${STORAGE_CLASS:-STANDARD_IA}"
PG_DUMP_COMPRESSION="${PG_DUMP_COMPRESSION:-0}"

[ "$PG_DUMP_COMPRESSION" -ge 0 ] 2>/dev/null || fail "PG_DUMP_COMPRESSION must be an integer between 0-9."
[ "$PG_DUMP_COMPRESSION" -le 9 ] 2>/dev/null || fail "PG_DUMP_COMPRESSION must be an integer between 0-9."

IFS=',' read -ra DBS <<< "$PG_DATABASES"

echo " * Backup in progress..."
for db in "${DBS[@]}"; do
    FILENAME="${NOW}_${db}"
    BACKUP_FILE="${TMP_DIR}/${FILENAME}.dump"

    echo "   -> backing up ${db}..."

    pg_dump -Fc -Z "$PG_DUMP_COMPRESSION" -h "$PG_HOST" -U "$PG_USER" -p "$PG_PORT" "$db" > "$BACKUP_FILE"

    AWS_CP_ARGS=(--storage-class "$STORAGE_CLASS")
    [ -n "${S3_SSE:-}" ] && AWS_CP_ARGS+=(--sse "$S3_SSE")
    [ -n "${S3_SSE_KMS_KEY_ID:-}" ] && AWS_CP_ARGS+=(--sse-kms-key-id "$S3_SSE_KMS_KEY_ID")

    aws s3 cp "$BACKUP_FILE" "s3://${S3_PATH}/${FILENAME}.dump" "${AWS_CP_ARGS[@]}"

    rm -f "$BACKUP_FILE"
    echo "      ...database ${db} has been backed up"
done

echo " * Deleting old backups..."
aws s3 ls "s3://${S3_PATH}/" | while read -r line; do
    # Skip empty lines
    [ -z "$line" ] && continue
    # Extract filename (4th column); if absent, skip (could be directory)
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

    [ -z "$FILE_TS" ] && { echo "   -> skipping $FILENAME (could not parse date: $createDate)"; continue; }

    if [ "$FILE_TS" -lt "$RETENTION_THRESHOLD_TS" ]; then
        echo "   -> Deleting $FILENAME"
        aws s3 rm "s3://${S3_PATH}/${FILENAME}"
    fi
done

echo ""
echo "...done!"
echo ""
