#!/usr/bin/env bash
# Start Keeper with the development configuration from .dev/env.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/.dev/env"
exec python3 "$ROOT/tools/keeper/keeper.py" serve
