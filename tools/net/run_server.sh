#!/usr/bin/env bash
# Start the dedicated server (headless). Extra args are passed through, e.g.
#   tools/net/run_server.sh                              # temporary sessions (Slice 003 behaviour)
#   tools/net/run_server.sh --persistent                 # accounts + PostgreSQL (needs Keeper running)
# Client traffic is DTLS-encrypted with the development certificate in .dev/tls
# (production: --tls_cert=... --tls_key=...).
#   tools/net/run_server.sh --bind=0.0.0.0 ...           # LAN (never the public internet)
# Ctrl+C / SIGTERM request a graceful shutdown (characters saved, locks released).
set -euo pipefail
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$ROOT/.dev/env" ] && source "$ROOT/.dev/env"
mkdir -p "$ROOT/.dev/run"
STOP="$ROOT/.dev/run/server-$$.stop"
cd "$ROOT/game"
"$GODOT" --headless --path . res://scenes/server.tscn -- --stop_file="$STOP" --dev_tls "$@" &
PID=$!
graceful() {
  touch "$STOP"
  for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || exit 0; sleep 0.25; done
  echo "server did not stop in time; killing"; kill -9 "$PID" 2>/dev/null || true
}
trap graceful INT TERM
wait "$PID"
