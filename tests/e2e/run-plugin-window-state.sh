#!/usr/bin/env bash
# window-state plugin 통합 e2e — multi-backend dev 를 띄워 renderer 가 실 CEF 창의
# bounds 를 플러그인 → 코어 window API 로 save/get/restore/clear 라운드트립 검증.
#
# 사전조건: plugins/window-state/zig 빌드(suji dev 가 dev 모드에서 자동 buildByLang
#   하지만, 빌드 실패를 e2e 보다 먼저 정확히 진단하기 위해 명시적 pre-build).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/e2e/_common.sh"

( cd "$ROOT/plugins/window-state/zig" && zig build )

e2e_run_test tests/e2e/plugin-window-state-integration.test.ts
