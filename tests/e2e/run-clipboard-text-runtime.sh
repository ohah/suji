#!/usr/bin/env bash
# Clipboard text/HTML runtime E2E — read/write/clear/has/formats.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-clipboard-text-runtime.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/clipboard-text-runtime.test.ts
