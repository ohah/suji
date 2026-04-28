#!/usr/bin/env bash
# 스플래시 패턴 e2e — windows.create + ready-to-show 이벤트 + close 조합으로
# 별도 코드 추가 없이 splash window 패턴이 동작함을 검증.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-splash.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/splash.test.ts
