#!/bin/bash
# Postiz EC2 hardening: UFW, docker log rotation, backup cron.
# Idempotent - safe to re-run.
set -euo pipefail

echo "== UFW =="
sudo ufw allow 22/tcp || true
sudo ufw allow 80/tcp || true
sudo ufw allow 443/tcp || true
sudo ufw --force enable
sudo ufw status | grep -q "Status: active" && echo "ufw active"

echo "== Docker log rotation =="
if [ ! -f /etc/docker/daemon.json ]; then
  echo '{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"3"}}' | sudo tee /etc/docker/daemon.json > /dev/null
  sudo systemctl restart docker
  echo "daemon.json written + docker restarted"
else
  grep -q max-size /etc/docker/daemon.json && echo "rotation already set" || echo "WARN: daemon.json exists without max-size - fix manually"
fi

echo "== Backup cron =="
(crontab -l 2>/dev/null | grep -v postiz/scripts/backup.sh; echo "30 21 * * * cd /home/ubuntu/postiz && ./scripts/backup.sh >> /home/ubuntu/backups/cron.log 2>&1") | crontab -
crontab -l | grep backup.sh && echo "cron installed"

echo "== unattended-upgrades =="
sudo apt-get install -y unattended-upgrades > /dev/null 2>&1 && echo "installed" || echo "already"

echo "HARDENING DONE"
