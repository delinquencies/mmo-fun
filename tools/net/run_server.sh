#!/usr/bin/env bash
# Start the dedicated server (headless). Extra args are passed through, e.g.
#   tools/net/run_server.sh --port=24680 --bind=0.0.0.0     # LAN (never the public internet)
set -euo pipefail
GODOT="${GODOT:-godot}"
cd "$(dirname "$0")/../../game"
exec "$GODOT" --headless --path . res://scenes/server.tscn -- "$@"
