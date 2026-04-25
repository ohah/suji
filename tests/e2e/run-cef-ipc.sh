#!/usr/bin/env bash
# CEF IPC stress E2E — fresh suji dev에서 단독 실행.
# 200회 chain 호출 등의 stress 시나리오는 다른 e2e 잔재가 있는 세션에서
# protocolTimeout이 깨지므로 자기 세션에서 단독 실행해야 안정.
#
# 사용:
#   ./tests/e2e/run-cef-ipc.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-cef-ipc.log}"
SUJI_TRACE_IPC=1
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/cef-ipc.test.ts
