#!/usr/bin/env bash
# Dialog E2E — fresh suji dev에서 단독 실행.
# Linux: SUJI_E2E_LINUX_DIALOG_AUTO_CLOSE=1 설정 시 실제 GTK modal을 띄운 뒤
# GTK timeout hook으로 cancel response를 보내 CI에서 멈추지 않게 검증.
# macOS: RUN_DESTRUCTIVE=1 설정 시 실제 modal NSAlert/NSOpenPanel/NSSavePanel을
# 화면에 띄운다. 수동 dismiss 또는 osascript 자동화는 Accessibility 권한 필요.
#
# 사용:
#   ./tests/e2e/run-dialog.sh                     # static wiring only
#   SUJI_E2E_LINUX_DIALOG_AUTO_CLOSE=1 ./tests/e2e/run-dialog.sh   # Linux GTK runtime
#   RUN_DESTRUCTIVE=1 ./tests/e2e/run-dialog.sh                    # 실제 modal 수동 확인

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-dialog.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/dialog.test.ts
