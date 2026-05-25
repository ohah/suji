#!/usr/bin/env bash
# Screen API runtime E2E — getAllDisplays/cursor/nearest-point.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-screen-runtime.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/screen-runtime.test.ts
