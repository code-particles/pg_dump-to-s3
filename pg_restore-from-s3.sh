#!/usr/bin/env bash

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

__usage="
USAGE:
  $(basename "$0") [db target] [s3 object]

EXAMPLE
  $(basename "$0") service 2023-06-28-at-10-29-44_service.dump
"

if [ "$#" -lt 2 ]; then
    echo "$__usage"
    exit 1
fi

command -v aws >/dev/null 2>&1 || { echo "aws cli not found in PATH."; exit 1; }
command -v pg_restore >/dev/null 2>&1 || { echo "pg_restore not found in PATH."; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "psql not found in PATH."; exit 1; }

REQUIRED_VARS=(PG_HOST PG_USER PG_PORT S3_PATH)
for var in "${REQUIRED_VARS[@]}"; do
    [ -n "${!var:-}" ] || { echo "Config variable $var is required."; exit 1; }
done

TARGET_DB="$1"
S3_OBJECT="$2"
TMP_DIR="${TMPDIR:-/tmp}"
LOCAL_BACKUP="${TMP_DIR}/${S3_OBJECT}"

echo "Downloading s3://${S3_PATH}/${S3_OBJECT}..."
aws s3 cp "s3://${S3_PATH}/${S3_OBJECT}" "$LOCAL_BACKUP"

DB_EXISTS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'")
if [ "$DB_EXISTS" = "1" ]; then
    echo "Database ${TARGET_DB} already exists, skipping creation"
    pg_restore -h "$PG_HOST" -U "$PG_USER" -p "$PG_PORT" -d "$TARGET_DB" -Fc --clean "$LOCAL_BACKUP"
else
    echo "Creating database ${TARGET_DB}"
    createdb -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -T template0 "$TARGET_DB"
    pg_restore -h "$PG_HOST" -U "$PG_USER" -p "$PG_PORT" -d "$TARGET_DB" -Fc "$LOCAL_BACKUP"
fi

rm -f "$LOCAL_BACKUP"
echo "${S3_OBJECT} restored to database ${TARGET_DB}"
