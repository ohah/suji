#!/usr/bin/env bash
# 비-macOS safeStorage 라운드트립 회귀 가드.
# - Linux : secret-tool 은 Secret Service(D-Bus + keyring) 필요 →
#           헤드리스 CI 는 dbus-run-session + gnome-keyring-daemon 으로 래핑.
# - Windows: DPAPI(데몬 불필요) — 직접 실행.
# macOS 는 cef.zig Keychain(@compileError 대상) — 호출 금지(ci 가 게이트).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
rm -rf .zig-cache zig-out

case "$(uname -s)" in
  Linux)
    # keyring unlock(빈 패스워드) 후 동일 D-Bus 세션에서 zig test.
    dbus-run-session -- bash -c '
      eval "$(printf "\n" | gnome-keyring-daemon --unlock --components=secrets)"
      zig build test
    '
    ;;
  *)
    zig build test  # Windows(Git-bash): DPAPI 직접
    ;;
esac

echo "PASS — safeStorage 라운드트립 OK ($(uname -s))"
rm -rf .zig-cache zig-out
