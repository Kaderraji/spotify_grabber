#!/usr/bin/env bash
# Start the grabber API on this PC.
#
# Uses spotdl's own Python environment because it already ships fastapi and
# uvicorn, so nothing extra needs installing.
set -euo pipefail

cd "$(dirname "$0")"

SPOTDL_PY="${SPOTDL_PY:-$HOME/.local/share/uv/tools/spotdl/bin/python}"
if [[ ! -x "$SPOTDL_PY" ]]; then
  echo "spotdl python not found at $SPOTDL_PY" >&2
  echo "install spotdl first, or point SPOTDL_PY at its venv python" >&2
  exit 1
fi

export GRABBER_PORT="${GRABBER_PORT:-8787}"
export GRABBER_HOST="${GRABBER_HOST:-0.0.0.0}"

echo "grabber listening on http://$(hostname -I | awk '{print $1}'):$GRABBER_PORT"
exec "$SPOTDL_PY" -m uvicorn grabber:app --host "$GRABBER_HOST" --port "$GRABBER_PORT"
