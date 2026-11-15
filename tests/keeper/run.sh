#!/usr/bin/env bash
# Run Keeper DB tests on a disposable database (mmo_test) in the dev cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/.dev/env"
PGPASSWORD="$(cat "$ROOT/.dev/.superuser_pw")" psql -h 127.0.0.1 -p "$PGPORT" -U postgres -qc "DROP DATABASE IF EXISTS mmo_test WITH (FORCE)" -c "CREATE DATABASE mmo_test OWNER mmo_keeper ENCODING 'UTF8' TEMPLATE template0"
export KEEPER_DSN="${KEEPER_DSN/dbname=mmo /dbname=mmo_test }"
python3 "$ROOT/tools/keeper/keeper.py" migrate >/dev/null
python3 "$ROOT/tests/keeper/test_keeper.py"
