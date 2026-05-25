#!/usr/bin/env bash
# printToPDF E2E — real PDF file output and completion event.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-print-to-pdf.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/print-to-pdf.test.ts
