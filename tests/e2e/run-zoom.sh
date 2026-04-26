#!/usr/bin/env bash
# Phase 4-B Zoom E2E — fresh suji dev에서 단독 실행.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-zoom.log}"
source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/zoom.test.ts
