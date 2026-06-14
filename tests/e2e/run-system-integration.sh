#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-system-integration.log}"
# app.relaunch e2e — relaunchSelf 가 graceful 종료(SIGTERM) 시 고아 프로세스를 남기지
# 않도록 실 spawn 우회(wire/success 만 검증). main.zig relaunchSelf 의 SUJI_E2E_NO_RELAUNCH
# 가드(de-elevation 의 SUJI_NO_RELAUNCH 와 분리한 e2e 전용 — ambient footgun 회피).
export SUJI_E2E_NO_RELAUNCH=1
source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/system-integration.test.ts
