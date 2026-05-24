#!/usr/bin/env bash
# `suji types` CLI E2E.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-types-cli.log}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) SUJI_BIN="$ROOT/zig-out/bin/suji.exe" ;;
  *) SUJI_BIN="$ROOT/zig-out/bin/suji" ;;
esac

[ -x "$SUJI_BIN" ] || { echo "suji binary not found at $SUJI_BIN — run 'zig build' first"; exit 1; }

cd "$ROOT"
rm -f "$SUJI_LOG"
bun test tests/e2e/types-cli.test.ts --timeout 60000 2>&1 | tee "$SUJI_LOG"
