#!/usr/bin/env bash
set -euo pipefail

cd /home/micu/poker
set -a
. ./.env
set +a

curl -fsS "http://127.0.0.1:${PORT}/health"
curl -fsS "https://poker.micutu.com/health"
systemctl is-active --quiet micupoker.service
echo
echo "micupoker deployment checks passed"
