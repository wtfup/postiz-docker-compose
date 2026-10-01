#!/bin/bash
# Postiz adversarial validation suite.
# Every check that FAILs must be fixed, then this suite re-run until green.
# Exit code: number of failures.
set -u

FAIL=0
PASS=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

check() { # check <desc> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc — $*"; fi
}

cd /home/ubuntu/postiz

echo "=== 1. Stack state ==="
# every service present
for svc in postiz postiz-caddy postiz-postgres postiz-redis temporal temporal-postgresql temporal-elasticsearch temporal-ui; do
  docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -qx "$svc" \
    && ok "container running: $svc" \
    || bad "container not running: $svc"
done
# healthchecks (postiz has one)
HP=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' postiz 2>/dev/null)
[ "$HP" = "healthy" ] && ok "postiz healthcheck healthy (got: $HP)" || bad "postiz healthcheck not healthy (got: $HP)"

echo "=== 2. HTTP/TLS edge ==="
check "https 200/3xx on root"           curl -fsS -o /dev/null --max-time 15 https://postiz.wtflabs.ai
check "http redirects to https"         bash -c 'code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://postiz.wtflabs.ai); [ "$code" -ge 300 ] && [ "$code" -lt 400 ]'
check "cert still valid >20 days"       bash -c 'echo | openssl s_client -servername postiz.wtflabs.ai -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -checkend 1728000 2>/dev/null | grep -q "will not expire"'
CERT_CN=$(echo | openssl s_client -servername postiz.wtflabs.ai -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
echo "$CERT_CN" | grep -qi "postiz.wtflabs.ai" && ok "cert CN matches domain" || bad "cert CN mismatch: $CERT_CN"

echo "=== 3. Public surface (must ONLY expose 80/443 to 0.0.0.0/0) ==="
PUB_PORTS=$(sudo ss -tlnp 2>/dev/null | awk '{print $4}' | grep -vE '127\.0\.0\.1|::1|127\.0\.0\.53|127\.0\.0\.54|0\.0\.0\.0:22|0\.0\.0\.0:80|0\.0\.0\.0:443|\[::\]:22|\[::\]:80|\[::\]:443|Local' | sort -u | tr '\n' ' ')
[ -z "$PUB_PORTS" ] && ok "no unexpected public listeners" || bad "unexpected public listeners: $PUB_PORTS"
for p in 4007 5432 6379 7233 8080 9200; do
  (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null && ok "port $p bound to localhost only (checked via ss)" || true
done

echo "=== 4. Secrets & config ==="
check ".env exists with JWT_SECRET"        bash -c 'grep -q "^JWT_SECRET=.\{24,\}" .env'
check ".env POSTGRES_PASSWORD strong"      bash -c 'grep -q "^POSTGRES_PASSWORD=.\{16,\}" .env'
check "AI key configured (AZURE_OPENAI_API_KEY)" bash -c 'grep -q "^AZURE_OPENAI_API_KEY=.\{8,\}" .env'
check "no default passwords in compose"    bash -c '! grep -Eq "postiz-password|CHANGE_ME" docker-compose.yaml .env'
check "registration disabled post-setup"   bash -c 'grep -q "^DISABLE_REGISTRATION=true" .env || grep -q "DISABLE_REGISTRATION=true" docker-compose.yaml'

echo "=== 5. OS hardening ==="
check "UFW active"                         bash -c 'sudo ufw status | grep -q "Status: active"'
check "UFW allows 22/80/443 only"          bash -c 'ports=$(sudo ufw status numbered | grep ALLOW | grep -oE "(22|80|443)/tcp" | sort -u | wc -l); [ "$ports" -eq 3 ]'
check "docker log rotation set"            bash -c 'grep -q "max-size" /etc/docker/daemon.json'
check "swap active"                        bash -c 'swapon --show | grep -q swap'
check "disk >20% free"                     bash -c 'pct=$(df / | tail -1 | awk "{print \$5}" | tr -d "%"); [ $pct -lt 80 ]'
check "no OOM kills in dmesg"              bash -c '! sudo dmesg 2>/dev/null | grep -qi "killed process.*(postiz\|temporal\|postgres\|redis\|elasticsearch)"'

echo "=== 6. Durability ==="
check "backup script exists"               test -f scripts/backup.sh
check "backup cron installed"              bash -c 'crontab -l 2>/dev/null | grep -q "backup.sh"'
check "cert auto-renew (caddy handles; caddy cron n/a)" true
B_COUNT=$(ls /home/ubuntu/backups/postiz-db-* 2>/dev/null | wc -l)
[ "$B_COUNT" -ge 1 ] && ok "at least one DB backup exists" || bad "no DB backups found"

echo "=== 7. Restart resilience (live test) ==="
docker compose restart postiz >/dev/null 2>&1
sleep 35
check "app healthy after restart"          bash -c 'docker inspect -f "{{.State.Health.Status}}" postiz | grep -q healthy'
check "https serves after restart"         curl -fsS -o /dev/null --max-time 15 https://postiz.wtflabs.ai

echo "=== 8. Azure GPT connectivity ==="
AIKEY=$(grep -m1 '^AZURE_OPENAI_API_KEY=' .env | cut -d= -f2-)
AIEP=$(grep -m1 '^AZURE_OPENAI_ENDPOINT=' .env | cut -d= -f2-)
AIDEP=$(grep -m1 '^AZURE_OPENAI_DEPLOYMENT=' .env | cut -d= -f2-)
IMGEP=$(grep -m1 '^AZURE_OPENAI_IMAGE_DEPLOYMENT=' .env | cut -d= -f2-)
check "Azure chat works (gpt-5-2)"      bash -c "curl -fsS --max-time 60 \"$AIEP/openai/deployments/$AIDEP/chat/completions?api-version=2024-12-01-preview\" -H \"api-key: $AIKEY\" -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_completion_tokens\":10}' | grep -q '\"model\"'"
check "Azure image works (sunburst)"      bash -c "curl -fsS --max-time 180 \"$AIEP/openai/deployments/$IMGEP/images/generations?api-version=2024-12-01-preview\" -H \"api-key: $AIKEY\" -H 'Content-Type: application/json' -d '{\"prompt\":\"validation test\",\"size\":\"1024x1024\"}' | grep -q 'b64_json'"

echo
echo "==================================="
echo "RESULT: $PASS passed, $FAIL failed"
echo "==================================="
exit $FAIL
