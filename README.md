# pg_dump-to-s3

Automatically dump and archive PostgreSQL backups to Amazon S3.

## Requirements

- [AWS CLI](https://aws.amazon.com/cli)
- `python3` (used for cross-platform date handling)
- `pg_dump`, `pg_restore`, and `psql` available in `PATH`

## Setup

- Use `aws configure` to store your AWS credentials in `~/.aws` ([docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html#cli-quick-configuration))
- Copy `.conf` to either the project root or `~/.pg_dump-to-s3.conf` and update the values.
- If your PostgreSQL connection uses a password, store it securely in `~/.pgpass` ([docs](https://www.postgresql.org/docs/current/static/libpq-pgpass.html)).

### Configuration keys (`.conf`)

| Key | Description | Default |
| --- | --- | --- |
| `PG_HOST` | PostgreSQL host | _required_ |
| `PG_USER` | PostgreSQL user | _required_ |
| `PG_PORT` | PostgreSQL port | _required_ |
| `PG_DATABASES` | Comma-separated list of databases to back up | _required_ |
| `S3_PATH` | Bucket and prefix (e.g. `my-bucket/backups`) | _required_ |
| `DELETE_AFTER` | Retention window in days (e.g. `7` or `7 days`) | _required_ |
| `STORAGE_CLASS` | S3 storage class for uploads | `STANDARD_IA` |
| `PG_DUMP_COMPRESSION` | `pg_dump` compression level `0-9` | `0` |
| `S3_SSE` | Optional S3 server-side encryption (`AES256` or `aws:kms`) | _unset_ |
| `S3_SSE_KMS_KEY_ID` | KMS key ID when `S3_SSE=aws:kms` | _unset_ |
| `TMPDIR` | Temp directory for dump files | `/tmp` |

## Usage

```bash
./pg_dump-to-s3.sh

#  * Backup in progress.,.
#    -> backing up test...
# upload: ../../../tmp/2023-06-28-at-22-20-08_test.dump to s3://*****/backups/2023-06-28-at-22-20-08_test.dump
#       ...database test has been backed up
#  * Deleting old backups...

# ...done!
```

Notes:
- Retention is computed with `python3`, so it works on macOS and Linux.
- The bucket/prefix must already exist and your AWS credentials need permission to `s3:GetObject`, `PutObject`, `DeleteObject`, and `ListBucket` on that prefix.
- Server-side encryption and storage class can be overridden via config (see above).

## Restore a backup

```bash
# USAGE: pg_restore-from-s3.sh [db target] [s3 object]

./pg_restore-from-s3.sh my_database_1 2023-06-28-at-10-29-44_my_database_1.dump

# download: s3://your_bucket/folder/2023-06-28-at-22-17-15_my_database_1.dump to /tmp/2023-06-28-at-22-17-15_my_database_1.dump
# Database my_database_1 already exists, skipping creation
# 2023-06-28-at-22-17-15_my_database_1.dump restored to database my_database_1
```

Restores will create the target database if it does not exist. Keep your `.conf` (or `~/.pg_dump-to-s3.conf`) in sync with the Postgres connection details used for backup.
