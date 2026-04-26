#!/usr/bin/env bash
# Phase 5-C Notification E2E — fresh suji dev에서 단독 실행.
# 주의: suji dev (loose binary)는 Bundle ID 없어 isSupported() false. 실제 알림은 .app 번들 manual.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-notification.log}"
source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/notification.test.ts
