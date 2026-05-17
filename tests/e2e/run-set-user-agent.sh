#!/usr/bin/env bash
# set-user-agent E2E 단독 실행 (tests/e2e/_common.sh 가 fresh suji dev 라이프사이클 처리).
# 사용: ./tests/e2e/run-set-user-agent.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-set-user-agent.log}"
source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/set-user-agent.test.ts
