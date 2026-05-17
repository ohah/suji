#!/usr/bin/env bash
# 외부 Zig 프로젝트가 suji 를 b.dependency("suji").module("suji") 로
# 소비할 수 있는지 회귀 가드. build.zig:b.addModule("suji") + 모듈
# import 그래프 + build.zig.zon .paths 가 깨지면 여기서 실패.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
rm -rf .zig-cache zig-out

zig build
# glob-safe(다중 매치 시 test 인자 폭발/ set -e 중단 회피). lib/(unix
# .dylib/.so) 또는 bin/(windows .dll) 중 하나라도 있으면 OK.
compgen -G 'zig-out/lib/libsuji_consumer.*' >/dev/null \
  || compgen -G 'zig-out/bin/suji_consumer.*' >/dev/null \
  || { echo "소비자 산출물 없음 — 패키지 소비성 깨짐"; ls -R zig-out; exit 1; }

echo "PASS — suji 패키지 소비성 OK (b.dependency.module('suji'))"
rm -rf .zig-cache zig-out
