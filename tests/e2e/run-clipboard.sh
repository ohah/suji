#!/usr/bin/env bash
# Clipboard E2E — fresh suji dev에서 단독 실행.
# pbcopy/pbpaste 통해 host clipboard ↔ suji.clipboard.* round-trip.
#
# 사용:
#   ./tests/e2e/run-clipboard.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-clipboard.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/clipboard.test.ts
