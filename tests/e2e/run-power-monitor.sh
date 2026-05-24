#!/usr/bin/env bash
# powerMonitor E2E — fresh suji dev에서 단독 실행.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-power-monitor.log}"
export SUJI_E2E_POWER_MONITOR_TEST_HOOK=1
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/power-monitor.test.ts
