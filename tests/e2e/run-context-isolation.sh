#!/usr/bin/env bash
# contextIsolation E2E 단독 실행 (tests/e2e/_common.sh 가 fresh suji dev 처리).
# 사용: ./tests/e2e/run-context-isolation.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-context-isolation.log}"
source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/context-isolation.test.ts
