#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RIG_TEST_BASH="$BASH"
python3 "$ROOT_DIR/tests/audit_regressions.py"
