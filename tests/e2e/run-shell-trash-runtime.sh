#!/usr/bin/env bash
# Shell trash runtime E2E — shell.trashItem filesystem round-trip.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-shell-trash-runtime.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/shell-trash-runtime.test.ts
