#!/usr/bin/env bash
# One command to run the TaskFlow sync server in Docker, then add people and pair phones.
#
#   ./deploy.sh public sync.example.com    on the internet, HTTPS by Caddy (needs a DNS name, ports 80 and 443)
#   ./deploy.sh private                    not on the internet: reach it only through Tailscale (see DEPLOY.md)
#   ./deploy.sh invite Alice               create Alice if needed and print a one-time pairing code
#   ./deploy.sh update                     pull the latest code, rebuild, restart, and reload Caddy (at least monthly)
#   ./deploy.sh reload                     reload Caddy after editing the Caddyfile (no downtime)
#   ./deploy.sh backup                     write a consistent copy of the database to ./backups
#   ./deploy.sh status | logs | stop
#   ./deploy.sh cli <args...>              run any taskflow_server command, e.g. `cli user list`
#
# Run it from anywhere; it works inside this folder. Needs Docker with the compose plugin.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }
command -v docker >/dev/null || die "Docker is not installed. See https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "The Docker compose plugin is missing. See https://docs.docker.com/compose/install/linux/"

# Which Compose profile is active is remembered here, so later commands need no arguments.
MODE_FILE=.mode
mode() { [ -f "$MODE_FILE" ] && cat "$MODE_FILE" || echo public; }
dc() { docker compose --profile "$(mode)" "$@"; }

set_env() { # set_env KEY VALUE: add or replace a line in .env
  touch .env
  if grep -q "^$1=" .env; then
    sed -i.bak "s|^$1=.*|$1=$2|" .env && rm -f .env.bak
  else
    echo "$1=$2" >> .env
  fi
}

cli() { dc exec -T taskflow taskflow_server "$@"; }

wait_ready() {
  for _ in $(seq 1 30); do
    if cli user list >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "the server did not start; run ./deploy.sh logs"
}

case "${1:-help}" in
  public)
    DOMAIN="${2:-}"
    [ -n "$DOMAIN" ] || die "usage: ./deploy.sh public sync.example.com"
    echo public > "$MODE_FILE"
    [ -f .env ] || cp .env.example .env
    set_env TASKFLOW_DOMAIN "$DOMAIN"
    set_env TASKFLOW_PUBLIC_URL "https://$DOMAIN"
    echo "==> Starting TaskFlow and Caddy for https://$DOMAIN (the first build takes a few minutes)"
    dc up -d --build
    wait_ready
    echo
    echo "Running. Make sure $DOMAIN points at this machine and ports 80 and 443 are open;"
    echo "Caddy fetches the HTTPS certificate on the first visit (give it a minute)."
    echo "Next:  ./deploy.sh invite <your name>"
    ;;
  private)
    echo private > "$MODE_FILE"
    [ -f .env ] || cp .env.example .env
    echo "==> Starting TaskFlow without any public port (the first build takes a few minutes)"
    dc up -d --build
    wait_ready
    cat <<'MSG'

Running, and reachable only from this machine (127.0.0.1:8080).
To let your own devices reach it, put this machine on Tailscale and run once:

    sudo tailscale serve --bg 8080

That prints an address like https://<machine>.<tailnet>.ts.net. Use it in the app (Settings > Sync).
Next:  ./deploy.sh invite <your name>
MSG
    ;;
  invite)
    NAME="${2:-}"
    [ -n "$NAME" ] || die "usage: ./deploy.sh invite <name>"
    cli user add "$NAME" >/dev/null 2>&1 || true # already there is fine
    cli invite "$NAME"
    echo "(works once, expires in 10 minutes. In the app: Settings > Sync)"
    ;;
  update)
    git -C ../.. pull --ff-only
    ./deploy.sh backup || true
    dc up -d --build
    wait_ready
    # Caddy does not notice a changed Caddyfile by itself (private mode has no Caddy: nothing to do then).
    dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
    docker image prune -f >/dev/null
    echo "Updated."
    ;;
  reload)
    # After editing the Caddyfile (or the landing page folder): apply it without downtime.
    dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile
    echo "Caddy reloaded."
    ;;
  backup)
    mkdir -p backups
    F="backup-$(date +%F).sqlite"
    dc exec -T taskflow taskflow_server backup "/data/$F"
    docker cp "$(dc ps -q taskflow):/data/$F" "backups/$F"
    dc exec -T taskflow rm -f "/data/$F"
    mkdir -p backups/blobs
    docker cp "$(dc ps -q taskflow):/data/blobs/." backups/blobs/ 2>/dev/null || true # attachment files
    chmod 600 "backups/$F"
    ls -1t backups/backup-*.sqlite | tail -n +15 | xargs -r rm --
    echo "Wrote $(pwd)/backups/$F and attachment files in backups/blobs"
    ;;
  status) dc ps ;;
  logs) dc logs --tail 200 -f taskflow ;;
  stop) dc down ;;
  cli) shift; cli "$@" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
