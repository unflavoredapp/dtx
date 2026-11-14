#!/usr/bin/env bash
# Copy server/ota/public/ to the tetherless.dev Apache docroot.
#
# Required env:
#   TETHERLESS_SSH_HOST   e.g. 198.96.93.10 or tetherless.dev
#   TETHERLESS_SSH_USER   e.g. root or dct
# Optional:
#   TETHERLESS_SSH_KEY    path to private key (otherwise ssh-agent / default key)
#   TETHERLESS_DOCROOT    default /var/www/tetherless.dev
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUB="$ROOT/public"
HOST="${TETHERLESS_SSH_HOST:?set TETHERLESS_SSH_HOST}"
USER="${TETHERLESS_SSH_USER:?set TETHERLESS_SSH_USER}"
DOCROOT="${TETHERLESS_DOCROOT:-/var/www/tetherless.dev}"
SSH=(ssh -o StrictHostKeyChecking=accept-new)
RSYNC=(rsync -avz --delete)
if [[ -n "${TETHERLESS_SSH_KEY:-}" ]]; then
  SSH+=(-i "$TETHERLESS_SSH_KEY")
  RSYNC+=(-e "ssh -i $TETHERLESS_SSH_KEY -o StrictHostKeyChecking=accept-new")
fi

[[ -f "$PUB/pack.json" ]] || { echo "missing $PUB/pack.json — run gen-pack.sh first"; exit 1; }

"${SSH[@]}" "$USER@$HOST" "mkdir -p '$DOCROOT' && chown -R www-data:www-data '$DOCROOT' 2>/dev/null || true"
"${RSYNC[@]}" "$PUB/" "$USER@$HOST:$DOCROOT/"
"${SSH[@]}" "$USER@$HOST" "chmod -R a+rX '$DOCROOT' && curl -fsS -o /dev/null -w 'pack.json HTTP %{http_code}\n' https://tetherless.dev/pack.json || true"
echo "Deployed $PUB → $USER@$HOST:$DOCROOT"
