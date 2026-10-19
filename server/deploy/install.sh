#!/usr/bin/env bash
# Installs the TaskFlow sync server as a systemd service on Debian/Ubuntu (no Docker).
# Run as root from the repository.
#
#   Public, HTTPS by Caddy:   sudo TASKFLOW_DOMAIN=sync.example.com bash server/deploy/install.sh
#   Private (Tailscale):      sudo TASKFLOW_MODE=private bash server/deploy/install.sh
#
# Settings (Google Calendar, public address) go in /etc/taskflow/taskflow.env, see DEPLOY.md.
set -euo pipefail

MODE="${TASKFLOW_MODE:-public}"
DOMAIN="${TASKFLOW_DOMAIN:-}"
if [ "$MODE" = public ] && [ -z "$DOMAIN" ]; then
  echo "Set TASKFLOW_DOMAIN (e.g. TASKFLOW_DOMAIN=sync.example.com), or TASKFLOW_MODE=private." >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==> Installing packages"
apt-get update
PKGS="ca-certificates curl gettext-base sqlite3"
[ "$MODE" = public ] && PKGS="$PKGS caddy"
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends $PKGS || {
  echo "A package could not be installed (Caddy is not in every package list: see https://caddyserver.com/docs/install)" >&2; exit 1; }

if ! command -v dart >/dev/null; then
  echo "==> Dart is needed once, to build the server. Install it from https://dart.dev/get-dart and run this again." >&2
  exit 1
fi

echo "==> Building the server"
rm -rf /tmp/taskflow_build
(cd "$ROOT/server" && dart pub get && dart build cli -t bin/taskflow_server.dart -o /tmp/taskflow_build)

id taskflow >/dev/null 2>&1 || useradd --system --home /var/lib/taskflow --shell /usr/sbin/nologin taskflow
install -d -o taskflow -g taskflow -m 700 /var/lib/taskflow /var/backups/taskflow
install -d /opt/taskflow
cp -a /tmp/taskflow_build/bundle/. /opt/taskflow/
install -m 644 "$ROOT/server/deploy/taskflow-server.service" /etc/systemd/system/taskflow-server.service

# Optional settings file, kept readable by root and the service only (it holds the Google secret).
install -d -m 750 -o root -g taskflow /etc/taskflow
if [ ! -f /etc/taskflow/taskflow.env ]; then
  install -m 640 -o root -g taskflow "$ROOT/server/deploy/.env.example" /etc/taskflow/taskflow.env
  [ "$MODE" = public ] && sed -i "s|^TASKFLOW_DOMAIN=.*|TASKFLOW_DOMAIN=$DOMAIN|; s|^TASKFLOW_PUBLIC_URL=.*|TASKFLOW_PUBLIC_URL=https://$DOMAIN|" /etc/taskflow/taskflow.env
fi

if [ "$MODE" = public ]; then
  echo "==> Configuring Caddy for $DOMAIN"
  TASKFLOW_DOMAIN="$DOMAIN" envsubst '${TASKFLOW_DOMAIN}' < "$ROOT/server/deploy/Caddyfile.host" > /etc/caddy/Caddyfile
fi

echo "==> Nightly backup"
install -m 755 "$ROOT/server/deploy/backup.sh" /opt/taskflow/backup.sh
cat > /etc/cron.d/taskflow-backup <<CRON
17 3 * * * taskflow /opt/taskflow/backup.sh
CRON

systemctl daemon-reload
systemctl enable --now taskflow-server
if [ "$MODE" = public ]; then systemctl reload caddy || systemctl restart caddy; fi

TF="sudo -u taskflow TASKFLOW_DB=/var/lib/taskflow/taskflow.sqlite /opt/taskflow/bin/taskflow_server"
cat <<MSG

Done. Next:
  $TF user add Alice
  $TF invite Alice
MSG
if [ "$MODE" = public ]; then
  echo "Then enter https://$DOMAIN and the code in the app (Settings > Sync)."
else
  cat <<'MSG'
The server listens only on this machine (127.0.0.1:8080). Put the machine on Tailscale and run once:
  sudo tailscale serve --bg 8080
then use the https://<machine>.<tailnet>.ts.net address it prints in the app (Settings > Sync).
MSG
fi
