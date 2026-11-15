#!/usr/bin/env bash
# Slice 004 Definition of Done with real processes and two graphical clients
# (Xvfb). Session 1: both register, create characters, Alice equips the sword,
# Bob deposits apples in the chest, both leave and log out. Then the dedicated
# server AND Keeper are stopped and restarted. Session 2: both log back in and
# verify position, equipment, appearance and chest contents.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G="${GODOT:-godot}"
OUT="${1:-$ROOT/.dev/dod}"
mkdir -p "$OUT"
source "$ROOT/.dev/env"
"$ROOT/tools/db/dev_db.sh" start >/dev/null
PGPASSWORD="$(cat "$ROOT/.dev/.superuser_pw")" psql -h 127.0.0.1 -p "$PGPORT" -U postgres -q \
  -c "DROP DATABASE IF EXISTS mmo_dod WITH (FORCE)" -c "CREATE DATABASE mmo_dod OWNER mmo_keeper ENCODING 'UTF8' TEMPLATE template0"
export KEEPER_DSN="${KEEPER_DSN/dbname=mmo /dbname=mmo_dod }" KEEPER_PORT=24732 KEEPER_LOG=INFO
python3 "$ROOT/tools/keeper/keeper.py" migrate >/dev/null
PORT=24731
cd "$ROOT/game"
start_backend() {
  python3 "$ROOT/tools/keeper/keeper.py" serve >> "$OUT/keeper.log" 2>&1 & KP=$!
  sleep 1
  "$G" --headless --path . res://scenes/server.tscn -- --persistent --dev_tls --port=$PORT --stop_file="$OUT/stop" >> "$OUT/server.log" 2>&1 & SP=$!
  sleep 3
}
stop_backend() {
  touch "$OUT/stop"; for _ in $(seq 1 40); do kill -0 $SP 2>/dev/null || break; sleep 0.25; done
  kill $KP 2>/dev/null || true; sleep 0.5
}
client() {  # role
  xvfb-run -a -s "-screen 0 ${CLIENT_RES:-1280x720}x24" "$G" --rendering-driver opengl3 --path . -- --window=${CLIENT_RES:-1280x720} --connect=127.0.0.1:$PORT \
    --scenario=dod_$1 --shot_dir="$OUT/$1" --nohelp ${2:-} > "$OUT/$1.out" 2>&1
}
: > "$OUT/server.log"; : > "$OUT/keeper.log"
start_backend
client alice_1 & A=$!; sleep 2; client bob_1 & B=$!
wait $A; EA=$?; wait $B; EB=$?
echo "session 1: alice=$EA bob=$EB"
POS=$(grep SAVED_POS "$OUT/alice_1/scenario.log" | awk '{print $2","$3}')
echo "--- restarting server and Keeper ---" | tee -a "$OUT/server.log"
stop_backend
start_backend
client alice_2 "--expect_pos=$POS" & A=$!; sleep 2; client bob_2 & B=$!
wait $A; EA2=$?; wait $B; EB2=$?
echo "session 2: alice=$EA2 bob=$EB2"
stop_backend
cat "$OUT"/*/scenario.log | grep -E "PASS|FAIL|scenario"
[ $EA -eq 0 ] && [ $EB -eq 0 ] && [ $EA2 -eq 0 ] && [ $EB2 -eq 0 ]
