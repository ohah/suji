#!/usr/bin/env bash
# state plugin + JS wrapper 통합 e2e — multi-backend dev 띄워서 renderer 가
# 실제 plugin DLL 라운드트립 검증.
#
# 사전조건: plugins/state/zig 가 빌드되어 있어야 (zig build 가 자동으로 한다).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/e2e/_common.sh"

# state plugin DLL pre-build (zig 빌드는 이미 메인 build 의 일부지만 안전 가드).
( cd "$ROOT/plugins/state/zig" && zig build >/dev/null 2>&1 ) || true

e2e_run_test tests/e2e/plugin-state-integration.test.ts
