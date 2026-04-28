#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-system-integration.log}"
source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/system-integration.test.ts
