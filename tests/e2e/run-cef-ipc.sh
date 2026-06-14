#!/usr/bin/env bash
# CEF IPC stress E2E — fresh suji dev에서 단독 실행.
# 200회 chain 호출 등의 stress 시나리오는 다른 e2e 잔재가 있는 세션에서
# protocolTimeout이 깨지므로 자기 세션에서 단독 실행해야 안정.
#
# 사용:
#   ./tests/e2e/run-cef-ipc.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-cef-ipc.log}"
SUJI_TRACE_IPC=1

# cef-ipc.test.ts 의 "lua backend" 블록이 multi-backend 예제의 lua 백엔드를 호출하므로
# -Dlua 로 빌드해야 한다(기본 빌드는 lua off → lua 백엔드 미가용 → lua 테스트 실패).
# vendored Lua 정적 링크라 시스템 의존 없음. run-lua-e2e.sh 와 동형.
( cd "$ROOT" && zig build -Dlua )

source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/cef-ipc.test.ts
