#!/usr/bin/env bash
# Rust SDK TypeScript SujiHandlers helper E2E.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-rust-types-helper.log}"

cd "$ROOT"
rm -f "$SUJI_LOG"
bun test tests/e2e/rust-types-helper.test.ts --timeout 180000 2>&1 | tee "$SUJI_LOG"
