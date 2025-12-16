# pg_dump-to-s3

Automatically dump and archive PostgreSQL backups to Amazon S3.

## Requirements

- `python3` (portable retention and listing helpers)
- [AWS CLI](https://aws.amazon.com/cli) – can be installed via pip: `pip install -r requirements.txt`
- PostgreSQL client tools in PATH: `pg_dump`, `pg_restore`, `psql`

## Setup

- (Python deps) From the repo root, install Python-level dependencies:

  ```bash
  python3 -m pip install --user -r requirements.txt
  ```

- Use `aws configure` to store your AWS credentials in `~/.aws` ([docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html#cli-quick-configuration))
- Copy `.conf` to either the project root or `~/.pg_dump-to-s3.conf` and update the values. `.env` in the project root is also sourced (handy for container/CI).
- If your PostgreSQL connection uses a password, store it in `~/.pgpass` ([docs](https://www.postgresql.org/docs/current/static/libpq-pgpass.html)) or export `PGPASSWORD` securely.
- Ensure the S3 bucket/prefix exists and your credentials have `s3:GetObject`, `PutObject`, `DeleteObject`, and `ListBucket` on that prefix. If using SSE-KMS, grant `kms:Encrypt`, `kms:Decrypt`, and `kms:GenerateDataKey`.

### Local testing (Postgres + MinIO)

This repo includes a simple local harness to validate backups and restores end-to-end without touching real AWS:

- Start services:
  ```bash
  cd tests
  docker compose up -d
  ```
- From the repo root, use the provided `.conf` and `.env` (already tailored for the harness). The `.env` exports MinIO credentials and endpoint, and routes `pg_dump`/`pg_restore` through the Postgres container to avoid client/server version mismatches.
- Run a backup:
  ```bash
  ./pg_dump-to-s3.sh
  ```
- Verify the uploaded objects:
  ```bash
  AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin AWS_DEFAULT_REGION=us-east-1 \
    aws s3 ls s3://pg-backups/ --endpoint-url http://localhost:9000
  ```
- Restore the latest backup into a new database:
  ```bash
  ./pg_restore-from-s3.sh --latest restore_test
  ```

Notes:
- When using custom S3-compatible endpoints, the scripts honor `AWS_ENDPOINT_URL` for all S3 operations.
- To stream restore data into the container, `.env` sets `PG_RESTORE_BIN='docker exec -i tests-postgres-1 pg_restore'`. This avoids mapping host temp files into the container.

### Configuration keys (`.conf`)

| Key                    | Description                                    | Default                    |
| ---------------------- | ---------------------------------------------- | -------------------------- |
| `PG_HOST`              | PostgreSQL host                                | _required_                 |
| `PG_USER`              | PostgreSQL user                                | _required_                 |
| `PG_PORT`              | PostgreSQL port                                | _required_                 |
| `PG_DATABASES`         | Comma-separated databases to back up           | _required_                 |
| `PG_DATABASES_EXCLUDE` | Comma-separated names to skip                  | _unset_                    |
| `S3_PATH`              | Legacy bucket/prefix (`bucket/path`)           | _required if no S3_BUCKET_ |
| `S3_BUCKET`            | Bucket name (preferred)                        | _required if no S3_PATH_   |
| `S3_PREFIX`            | Optional prefix inside bucket                  | _unset_                    |
| `DELETE_AFTER`         | Retention in days (e.g. `7` or `7 days`)       | _required_                 |
| `STORAGE_CLASS`        | S3 storage class                               | `STANDARD_IA`              |
| `PG_DUMP_COMPRESSION`  | `pg_dump` compression level `0-9`              | `0`                        |
| `S3_SSE`               | Server-side encryption (`AES256` or `aws:kms`) | _unset_                    |
| `S3_SSE_KMS_KEY_ID`    | KMS key ID when `S3_SSE=aws:kms`               | _unset_                    |
| `RETRY_ATTEMPTS`       | Retry attempts for AWS calls                   | `3`                        |
| `RETRY_BASE_SLEEP`     | Backoff base seconds                           | `2`                        |
| `MIN_FREE_MB`          | Minimum free space in `TMPDIR`                 | `512`                      |
| `QUIET`                | Set `1` for quieter output (cron-friendly)     | `0`                        |
| `DRY_RUN`              | Set `1` to print actions only                  | `0`                        |
| `HEALTHCHECK_CMD`      | Optional command executed after success        | _unset_                    |
| `TMPDIR`               | Temp directory for dump files                  | `/tmp`                     |

## Usage

```bash
./pg_dump-to-s3.sh

#  * Backup in progress...
#    -> backing up test...
# upload: ... to s3://bucket/prefix/...
#  * Deleting old backups...

# ...done!
```

Notes:

- Retention is portable (python-based) and validated; works on macOS/Linux.
- Uploads include checksum metadata and a `.sha256` sidecar; SSE/KMS and storage class are configurable.
- Use `PG_DATABASES_EXCLUDE` to skip specific DBs from the backup list.
- `DRY_RUN=1` prints actions without touching S3 or Postgres.
- `HEALTHCHECK_CMD` can ping your monitoring endpoint after success.

## Restore a backup

```bash
# USAGE: pg_restore-from-s3.sh [options] <db target> <s3 object>
#        pg_restore-from-s3.sh --latest <db target>
#        pg_restore-from-s3.sh --list [prefix]

./pg_restore-from-s3.sh my_database_1 2023-06-28-at-10-29-44_my_database_1.dump
```

Restore extras:

- `--latest` auto-picks the newest backup for the database.
- `--list` shows available backups (optionally filtered by prefix) and exits.
- `DRY_RUN=1` prints actions without downloading/restoring.
- `HEALTHCHECK_CMD` can be used here as well.
