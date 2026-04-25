#!/usr/bin/env bash
# Phase 2.5 __window wire injection E2E — fresh suji dev에서 단독 실행.
#
# 다른 e2e 파일과 같이 돌리면 잔재 창의 id 충돌 + puppeteer target attach 혼선이
# 발생하므로 이 스크립트가 매번 새 세션을 띄운다 (tests/e2e/_common.sh 참고).
#
# 사용:
#   ./tests/e2e/run-window-injection.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e.log}"
SUJI_TRACE_IPC=1
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/window-injection.test.ts
