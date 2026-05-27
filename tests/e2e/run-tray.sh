#!/usr/bin/env bash
# Tray E2E — fresh suji dev에서 단독 실행.
# macOS NSStatusItem / Linux GTK StatusIcon / Windows Shell_NotifyIconW 응답 shape 검증.
# RUN_DESTRUCTIVE=1: macOS osascript로 메뉴 항목 클릭 트리거 (Accessibility 권한 필요).
#
# 사용:
#   ./tests/e2e/run-tray.sh
#   RUN_DESTRUCTIVE=1 ./tests/e2e/run-tray.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-tray.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/tray.test.ts
