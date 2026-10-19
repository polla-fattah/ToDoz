#!/usr/bin/env bash
# Rebuilds and restarts the server with the latest code (SEC-15: do this at least monthly).
# Docker:      git pull && docker compose -f server/deploy/compose.yaml up -d --build
# Without it:  run this script as root from the repository after git pull.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
rm -rf /tmp/taskflow_build
(cd "$ROOT/server" && dart pub get && dart build cli -t bin/taskflow_server.dart -o /tmp/taskflow_build)
/opt/taskflow/backup.sh || true
cp -a /tmp/taskflow_build/bundle/. /opt/taskflow/
systemctl restart taskflow-server
systemctl is-active taskflow-server
