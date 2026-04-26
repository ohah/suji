#!/usr/bin/env bash
# Shell E2E — fresh suji dev에서 단독 실행.
# RUN_DESTRUCTIVE=1 설정 시 valid URL/path 케이스도 실행 (브라우저/Finder/비프 발생).
#
# 사용:
#   ./tests/e2e/run-shell.sh                    # invalid-input 위주, 부수효과 없음
#   RUN_DESTRUCTIVE=1 ./tests/e2e/run-shell.sh  # 전체 (브라우저 탭 + Finder + beep)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-shell.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/shell.test.ts
