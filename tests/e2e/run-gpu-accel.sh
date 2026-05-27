#!/usr/bin/env bash
# GPU 가속 회귀 가드 E2E (#12). CEF 초기화 후 WebGL/Canvas2D 컨텍스트 획득
# 확인 — 가속 활성 OR SwiftShader CPU fallback 둘 다 통과.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-gpu-accel.log}"
source "$ROOT/tests/e2e/_common.sh"

e2e_run_test tests/e2e/gpu-accel.test.ts
