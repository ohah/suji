#!/usr/bin/env bash
# WebContentsView lifecycle E2E — CEF Views probe path.
#
# 사용:
#   ./tests/e2e/run-view-lifecycle-cef-views.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export SUJI_CEF_VIEWS=1
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-view-lifecycle-cef-views.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/view-lifecycle.test.ts
