#!/usr/bin/env bash
# Demo UI E2E — examples/multi-backend native API controls.
#
# 사용:
#   ./tests/e2e/run-demo-native-controls.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-demo-native-controls.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/demo-native-controls.test.ts
