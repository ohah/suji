#!/usr/bin/env bash
# app:before-quit behavioral e2e — quit 트리거 → 백엔드 before-quit 핸들러가 종료 전
# 마커 파일 기록 → 회수 assert. (CEF 무관 검증 천장: quit 은 프로세스 종료라 puppeteer
# 직접 관측 불가 → 백엔드 동기 핸들러 + 디스크 마커로 우회.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUJI_LOG="${SUJI_LOG:-/tmp/suji-e2e-before-quit.log}"

# 백엔드(Zig)와 bun 테스트 둘 다 상속하도록 export. run 스크립트 PID 로 충돌 회피.
export SUJI_E2E_BQ_MARKER="/tmp/suji-e2e-before-quit-marker-$$"
rm -f "$SUJI_E2E_BQ_MARKER"

source "$ROOT/tests/e2e/_common.sh"
e2e_run_test tests/e2e/before-quit.test.ts
rm -f "$SUJI_E2E_BQ_MARKER" || true # 성공 경로 정리(실패 시 stale 은 다음 run 시작의 rm 이 처리)
