#!/usr/bin/env bash
# webRequest URL filter e2e — blocklist 등록 후 fetch가 차단되는지 검증.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-web-request.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/web-request.test.ts
