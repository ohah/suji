#!/usr/bin/env bash
# Shell openExternal runtime E2E — Linux GIO x-scheme-handler round-trip.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-shell-open-external-runtime.log}"
SUJI_E2E_XDG_HOME="${SUJI_E2E_XDG_HOME:-$(mktemp -d /tmp/suji-e2e-xdg.XXXXXX)}"
export XDG_DATA_HOME="$SUJI_E2E_XDG_HOME/data"
export XDG_CONFIG_HOME="$SUJI_E2E_XDG_HOME/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/shell-open-external-runtime.test.ts
