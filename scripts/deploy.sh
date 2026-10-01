#!/bin/bash
# Postiz first-boot deploy: pull compose repo, ensure secrets, up the stack, wait healthy.
# Run as ubuntu on the EC2. Safe to re-run.
set -euo pipefail
cd /home/ubuntu/postiz

git pull --quiet origin main

# guard rails
[ -f .env ] || { echo "FATAL: .env missing"; exit 1; }
grep -q "^JWT_SECRET=.\{24,\}" .env || { echo "FATAL: JWT_SECRET not set"; exit 1; }
docker images --format '{{.Repository}}' | grep -qx postiz-wtf || { echo "FATAL: postiz-wtf image not built"; exit 1; }

echo "== pulling stack images =="
docker compose pull -q postiz-postgres postiz-redis caddy temporal temporal-postgresql temporal-elasticsearch temporal-ui 2>&1 | tail -2 || true

echo "== starting stack =="
docker compose up -d

echo "== waiting for postiz healthy (up to 8 min) =="
for i in $(seq 1 48); do
  S=$(docker inspect -f '{{.State.Health.Status}}' postiz 2>/dev/null || echo none)
  echo "[$i] postiz health: $S"
  [ "$S" = "healthy" ] && break
  sleep 10
done
[ "$(docker inspect -f '{{.State.Health.Status}}' postiz 2>/dev/null)" = "healthy" ] || { echo "FATAL: postiz not healthy"; docker compose logs --tail 50 postiz; exit 1; }

echo "== caddy =="
docker compose ps
echo "DEPLOY OK"
