#!/usr/bin/env bash
# Start a game client that connects straight away.
#   tools/net/run_client.sh Alice                 # localhost
#   tools/net/run_client.sh Bob 192.168.1.20      # LAN server
set -euo pipefail
GODOT="${GODOT:-godot}"
NAME="${1:-Adventurer}"; HOST="${2:-127.0.0.1}"; PORT="${3:-24680}"
shift $(( $# < 3 ? $# : 3 ))
cd "$(dirname "$0")/../../game"
# GODOT_ARGS: engine options such as "--position 0,40 --resolution 960x600"
exec "$GODOT" ${GODOT_ARGS:-} --path . -- --connect="$HOST:$PORT" --name="$NAME" "$@"
