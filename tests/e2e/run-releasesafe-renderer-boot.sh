#!/usr/bin/env bash
# #60 part 2 회귀 가드 — Windows ReleaseSafe/ReleaseFast 렌더러 V8 stack-overflow.
#
# 이 버그는 **최적화 빌드 전용**(Debug 는 인라인이 없어 통과)이라, 일반 e2e
# (zig build = Debug)로는 못 잡는다. 따라서 여기서 ReleaseSafe 를 명시적으로
# 빌드한 뒤 렌더러가 window.__suji__ 를 바인딩하는지(=V8 컨텍스트 생성 성공)를
# 검증한다. 재발 시 getMainPage 가 타임아웃으로 실패 → CI red.
#
# 사용: bash tests/e2e/run-releasesafe-renderer-boot.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-rs-renderer-boot.log}"

echo "[#60 guard] Building ReleaseSafe (the optimization mode that exposed the bug)..."
( cd "$ROOT" && zig build -Doptimize=ReleaseSafe )

source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/releasesafe-renderer-boot.test.ts
