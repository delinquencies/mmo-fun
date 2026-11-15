#!/usr/bin/env bash
# Slice 004 acceptance: fresh test database, Keeper and the dedicated server as
# real processes (started/stopped/killed by the test), PostgreSQL stopped and
# started for the outage test. Requires tools/db/dev_db.sh init once.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
source "$ROOT/.dev/env"
"$ROOT/tools/db/dev_db.sh" start >/dev/null
export MMO_TEST_DB=mmo_test
PGPASSWORD="$(cat "$ROOT/.dev/.superuser_pw")" psql -h 127.0.0.1 -p "$PGPORT" -U postgres -q \
  -c "DROP DATABASE IF EXISTS mmo_test WITH (FORCE)" -c "CREATE DATABASE mmo_test OWNER mmo_keeper ENCODING 'UTF8' TEMPLATE template0"
export KEEPER_DSN="${KEEPER_DSN/dbname=mmo /dbname=mmo_test }"
export KEEPER_PORT=24722 KEEPER_LOG=WARNING
export PGPASSWORD="$MMO_DB_PASSWORD"
python3 "$ROOT/tools/keeper/keeper.py" migrate >/dev/null
export PERSIST_LOG_DIR="$ROOT/.dev/test-logs"
mkdir -p "$PERSIST_LOG_DIR"
cd "$ROOT/game"
"$GODOT" --headless --path . --script res://tests/persist_tests.gd
