#!/bin/bash
# Postiz daily backup: app DB dump + uploads volume + config volume.
# S3 sync happens only when the instance IAM role allows it.
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
DIR=/home/ubuntu/backups
mkdir -p "$DIR"
cd /home/ubuntu/postiz

# 1. App database (postiz-postgres)
docker compose exec -T postiz-postgres pg_dump -U postiz-user postiz-db-local > "$DIR/postiz-db-$TS.sql"
gzip "$DIR/postiz-db-$TS.sql"

# 2. Uploads volume
docker run --rm -v postiz_postiz-uploads:/data -v "$DIR":/backup alpine \
  sh -c "tar czf /backup/postiz-uploads-$TS.tar.gz -C /data ." || echo "WARN: uploads backup failed"

# 3. Config volume (AI provider config etc.)
docker run --rm -v postiz_postiz-config:/data -v "$DIR":/backup alpine \
  sh -c "tar czf /backup/postiz-config-$TS.tar.gz -C /data ." || echo "WARN: config backup failed"

# 4. Prune local copies older than 7 days
find "$DIR" -type f -mtime +7 -delete

# 5. Off-box copy (best-effort; fails silently when role not attached)
aws s3 sync "$DIR" s3://wtf-labs-postiz-backups/ --only-show-errors || echo "WARN: S3 sync skipped (no role/bucket access)"

echo "backup done: $TS"
ls -la "$DIR" | tail -5
