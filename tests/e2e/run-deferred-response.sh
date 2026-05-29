#!/usr/bin/env bash
# Deferred-response criticals 회귀 가드 (PR #54 code-review-max 후속):
# cross-kind 라우팅(#3), close-during-defer 무crash(#1), path 라운드트립.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-deferred-response.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/deferred-response.test.ts
