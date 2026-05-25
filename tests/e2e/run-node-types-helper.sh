#!/usr/bin/env bash
# Node SDK SujiHandlers type augmentation external-consumer E2E.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-node-types-helper.log}"

cd "$ROOT"
if [ ! -x packages/suji-node/node_modules/typescript/bin/tsc ]; then
  (cd packages/suji-node && npm install --include=dev --ignore-scripts)
fi

rm -f "$SUJI_LOG"
bun test tests/e2e/node-types-helper.test.ts --timeout 60000 2>&1 | tee "$SUJI_LOG"
