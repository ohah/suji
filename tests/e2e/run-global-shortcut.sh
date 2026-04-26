#!/usr/bin/env bash
# Global shortcut E2E — fresh suji dev에서 단독 실행.
#
# 사용:
#   ./tests/e2e/run-global-shortcut.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-global-shortcut.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/global-shortcut.test.ts
