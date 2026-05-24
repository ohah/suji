#!/usr/bin/env bash
# Window lifecycle E2E — CEF Views probe path.
#
# 사용:
#   ./tests/e2e/run-window-lifecycle-events-cef-views.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export SUJI_CEF_VIEWS=1
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-window-lifecycle-events-cef-views.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/window-lifecycle-events.test.ts
