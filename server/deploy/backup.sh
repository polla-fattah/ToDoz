#!/usr/bin/env bash
# Writes a consistent copy of the database (safe while the server runs) and keeps the newest 14 (FR-X, SEC-13).
# Without Docker this is run nightly by cron. With Docker:
#   docker compose exec taskflow taskflow_server backup /data/backup-$(date +%F).sqlite
set -euo pipefail
DB="${TASKFLOW_DB:-/var/lib/taskflow/taskflow.sqlite}"
DEST="${TASKFLOW_BACKUPS:-/var/backups/taskflow}"
KEEP="${TASKFLOW_KEEP:-14}"
umask 077
FILE="$DEST/taskflow-$(date +%F).sqlite"
rm -f "$FILE"
TASKFLOW_DB="$DB" /opt/taskflow/bin/taskflow_server backup "$FILE"
# Optional: encrypt before copying off the machine, e.g.  age -r <your-public-key> -o "$FILE.age" "$FILE"
# Attachment files are stored by content hash and never change, so copying only the new ones is enough.
BLOBS="${TASKFLOW_BLOBS:-$(dirname "$DB")/blobs}"
if [ -d "$BLOBS" ]; then mkdir -p "$DEST/blobs" && cp -an "$BLOBS"/. "$DEST/blobs/"; fi
ls -1t "$DEST"/taskflow-*.sqlite 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --
