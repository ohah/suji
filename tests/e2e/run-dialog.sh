#!/usr/bin/env bash
# Dialog E2E — fresh suji dev에서 단독 실행.
# RUN_DESTRUCTIVE=1 설정 시 실제 modal NSAlert/NSOpenPanel/NSSavePanel을 화면에 띄우고
# osascript로 ESC/Enter 자동 dismiss. macOS Accessibility 권한 필요.
#
# 사용:
#   ./tests/e2e/run-dialog.sh                     # static wiring only
#   RUN_DESTRUCTIVE=1 ./tests/e2e/run-dialog.sh   # 실제 modal + osascript dismiss

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-dialog.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/dialog.test.ts
