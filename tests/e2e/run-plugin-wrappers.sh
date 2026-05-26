#!/usr/bin/env bash
# 공식 플러그인 (state, sqlite) 의 4 언어 wrapper (JS, Node) wire-contract 검증.
# - JS wrapper: window.__suji__ bridge mock 으로 invoke channel/payload shape 검사
# - Node wrapper: globalThis.suji bridge mock 으로 동일 검사
# 실 plugin DLL 라운드트립은 `zig build test-state`/`test-sqlite` 가 별도로 검증.
# (e2e 가 아닌 unit-style 인 이유: wrapper 는 wire 한 줄짜리 thin layer, OS independent.)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
bun test plugins/state/js/src plugins/state/node/src plugins/sqlite/js/src plugins/sqlite/node/src
