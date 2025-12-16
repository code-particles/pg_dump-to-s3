Test harness for local development
==================================

This compose file spins up:
- Postgres (user/password: postgres/postgres)
- MinIO (access/secret: minioadmin/minioadmin), with bucket `pg-backups`

Usage
-----
```
cd tests
docker compose up -d
```

Then point `.conf` at:
- `PG_HOST=localhost`, `PG_PORT=5432`, `PG_USER=postgres`
- `S3_BUCKET=pg-backups`, `S3_PREFIX=` (empty)
- Export `AWS_ACCESS_KEY_ID=minioadmin`, `AWS_SECRET_ACCESS_KEY=minioadmin`, and set `AWS_ENDPOINT_URL=http://localhost:9000`

Run backups/restores against the local services. Stop with `docker compose down`.

