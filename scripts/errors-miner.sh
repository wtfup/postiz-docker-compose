#!/bin/bash
# Error miner: keeps a rolling feed of error-level lines from the postiz
# container logs, so agent/Vishal can instantly see what broke and when.
# Run every 10 min via cron. Keeps 30 days. Noise (missing avatars etc.) filtered.
set -uo pipefail
LOG=/home/ubuntu/postiz/errors
mkdir -p "$LOG"
TS=$(date +%Y%m%d)
docker logs postiz --since 11m 2>&1 \
  | grep -iE "error|exception|failed|unhandled|ELIFECYCLE|AI_APICallError" \
  | grep -viE "no live upstreams|avatars/|/auth/avatars" \
  | sed "s/^/$(date '+%F %T') /" \
  >> "$LOG/errors-$TS.log"
find "$LOG" -type f -mtime +30 -delete
