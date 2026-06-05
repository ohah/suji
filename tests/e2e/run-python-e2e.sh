#!/usr/bin/env bash
# Python 백엔드 E2E — embedded CPython 3.13 (python-build-standalone) + GIL.
# examples/python-backend 에서 fresh `suji dev` 를 띄우고 frontend invoke() ↔
# Python handler 왕복 + json parse/serialize + send/on 이벤트를 검증한다.
#
# Python 백엔드는 ~/.suji/python/<ver> 에 libpython 이 staging 되어 있으면
# build.zig 가 auto-detect 해서 활성화한다(-Dpython 플래그 불요). 러너가
# scripts/stage-python.sh 로 staging 을 보장한 뒤 _common.sh 라이프사이클을 탄다.
#
# 사용:
#   ./tests/e2e/run-python-e2e.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-python.log}"
SUJI_TRACE_IPC=1
export EXAMPLE_DIR="$ROOT/examples/python-backend"

# 사전조건: portable CPython staging(멱등 — 이미 있으면 skip) + auto-detect 빌드.
bash "$ROOT/scripts/stage-python.sh"
( cd "$ROOT" && zig build )

source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/python-invoke.test.ts
