#!/usr/bin/env bash
# Phase 17-A.7 — WebContentsView 생명주기 E2E 단독 실행.
# (tests/e2e/_common.sh가 fresh suji dev 세션 라이프사이클을 처리.)
#
# 사용:
#   ./tests/e2e/run-view-lifecycle.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-view-lifecycle.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/view-lifecycle.test.ts
