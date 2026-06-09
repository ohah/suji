#!/usr/bin/env bash
# upload plugin 통합 e2e — multi-backend dev 를 띄워 renderer 가 실 Bun HTTP 서버에
# 디스크 파일을 multipart 업로드 / 서버 body 를 디스크로 다운로드 라운드트립 검증.
#
# 사전조건: plugins/upload/zig 빌드(suji dev 가 dev 모드에서 자동 buildByLang 하지만,
#   빌드 실패를 e2e 보다 먼저 정확히 진단하기 위해 명시적 pre-build).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/e2e/_common.sh"

( cd "$ROOT/plugins/upload/zig" && zig build )

e2e_run_test tests/e2e/plugin-upload-integration.test.ts
