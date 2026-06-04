#!/usr/bin/env bash
# Lua 백엔드 E2E — vendored Lua 5.4 + bundled cjson.
# examples/lua-backend 에서 fresh `suji dev` 를 띄우고 frontend invoke() ↔ Lua
# handler 왕복 + cjson encode/decode 를 검증한다.
#
# Lua 백엔드는 `-Dlua` 빌드에서만 동작(기본 빌드는 lua off)하므로, 러너가
# 직접 `zig build -Dlua` 로 바이너리를 보장한 뒤 _common.sh 라이프사이클을 탄다.
#
# 사용:
#   ./tests/e2e/run-lua-e2e.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-lua.log}"
SUJI_TRACE_IPC=1
export EXAMPLE_DIR="$ROOT/examples/lua-backend"

# 사전조건: -Dlua 로 빌드(vendored Lua 정적 링크라 시스템 의존 없음).
( cd "$ROOT" && zig build -Dlua )

source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/lua-invoke.test.ts
