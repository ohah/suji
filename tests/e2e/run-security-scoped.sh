#!/usr/bin/env bash
# Security-scoped bookmarks E2E — fresh suji dev에서 단독 실행.
# 전 케이스 비파괴 자동화 (RUN_DESTRUCTIVE 불요).
#
# 사용:
#   ./tests/e2e/run-security-scoped.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-security-scoped.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/security-scoped.test.ts
