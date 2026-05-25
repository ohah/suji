#!/usr/bin/env bash
# CEF Views frameless drag-region E2E.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export SUJI_CEF_VIEWS=1
export SUJI_TRACE_DRAG_REGION=1
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-frameless-drag-region.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/frameless-drag-region.test.ts
