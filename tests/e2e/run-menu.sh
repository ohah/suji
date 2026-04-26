#!/usr/bin/env bash
# Menu E2E — fresh suji dev에서 단독 실행.
# RUN_DESTRUCTIVE=1: osascript로 메뉴 항목 클릭 트리거 (Accessibility 권한 필요).
#
# 사용:
#   ./tests/e2e/run-menu.sh
#   RUN_DESTRUCTIVE=1 ./tests/e2e/run-menu.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-menu.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/menu.test.ts
