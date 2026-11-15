#!/usr/bin/env bash
# One dedicated server + two clients on this computer. Ctrl+C stops everything.
set -euo pipefail
GODOT="${GODOT:-godot}"
HERE="$(dirname "$0")"
GODOT="$GODOT" "$HERE/run_server.sh" --port=24680 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1.5
GODOT="$GODOT" GODOT_ARGS="--position 0,40 --resolution 960x600" "$HERE/run_client.sh" Alice 127.0.0.1 24680 &
GODOT="$GODOT" GODOT_ARGS="--position 970,40 --resolution 960x600" "$HERE/run_client.sh" Bob 127.0.0.1 24680 &
wait
