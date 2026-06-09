#!/usr/bin/env bash
# iOS 시뮬레이터 빌드+구동 스모크 — 언어별 변형이 실제로 링크·실행되는지.
#
# run.sh(호스트 하니스)가 백엔드 왕복 *정확성*을 잡는 반면, 이쪽은 실제
# iOS 시뮬레이터에서만 드러나는 회귀를 잡는다: 코어/백엔드 .a 정적 링크
# 실패, 심볼 충돌(suji_rs_*/suji_go_*/suji_zig_*), Mach-O 플랫폼 불일치,
# 기동 직후 크래시(dlopen/TLS). 좌표 탭은 디바이스 크기마다 깨지므로
# 쓰지 않는다 — 빌드 성공 + launch 후 프로세스 생존(=링크/기동 무결)을
# 어서트하고, 화면을 아티팩트로 남긴다(육안 확인용, 게이트 아님).
#
# 사용: ./ios-sim-smoke.sh [variant ...]   (기본: zig multi — Zig/Rust/Go 커버)
# 선행: brew install xcodegen, 부팅된 iOS 시뮬레이터 1대.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VARIANTS=( "$@" )
[ "${#VARIANTS[@]}" -eq 0 ] && VARIANTS=(zig multi)
ALIVE_SECS=4

command -v xcodegen >/dev/null || { echo "xcodegen 미설치 — brew install xcodegen"; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild 미발견 — Xcode 필요"; exit 1; }
UDID="$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()')"
[ -n "$UDID" ] || { echo "부팅된 시뮬레이터 없음 — Simulator.app 으로 1대 부팅 필요"; exit 1; }

OUT="$(mktemp -d)"
DD="$OUT/dd"
installed=""   # 현재 시뮬에 install 된 bundle id — 루프 중간 실패 시 trap 이 정리
trap 'rm -rf "$OUT"; [ -z "$installed" ] || xcrun simctl uninstall "$UDID" "$installed" >/dev/null 2>&1 || true' EXIT
echo "시뮬레이터 UDID=$UDID, 변형=[${VARIANTS[*]}]"

fail=0
for v in "${VARIANTS[@]}"; do
  dir="$REPO/examples/ios/$v"
  [ -d "$dir" ] || { echo "[$v] 변형 디렉토리 없음 — skip"; fail=1; continue; }
  echo "=== [$v] build-lib.sh sim ==="
  ( cd "$dir" && bash build-lib.sh sim >/dev/null ) \
    || { echo "[$v] build-lib 실패 — FAIL"; fail=1; continue; }

  # xcodegen 을 ls 보다 먼저 — .xcodeproj 는 전 변형이 .gitignore 대상이라 아무도
  # 커밋하지 않는다. xcodegen 이 생성해야 ls 가 찾는다(ls-first 면 깨끗한 트리에서 빈 proj).
  echo "=== [$v] xcodegen ==="
  ( cd "$dir" && xcodegen generate >/dev/null ) \
    || { echo "[$v] xcodegen 실패 — FAIL"; fail=1; continue; }
  proj="$(cd "$dir" && ls -d *.xcodeproj | head -1)"
  [ -n "$proj" ] || { echo "[$v] .xcodeproj 없음 — FAIL"; fail=1; continue; }
  scheme="${proj%.xcodeproj}"
  echo "=== [$v] xcodebuild ($scheme) ==="
  ( cd "$dir" && xcodebuild -project "$proj" -scheme "$scheme" -sdk iphonesimulator \
      -derivedDataPath "$DD/$v" ARCHS=arm64 build >/dev/null ) \
    || { echo "[$v] xcodebuild 실패 — FAIL"; fail=1; continue; }

  app="$(find "$DD/$v/Build/Products" -maxdepth 3 -name '*.app' | head -1)"
  [ -n "$app" ] || { echo "[$v] .app 산출물 없음 — FAIL"; fail=1; continue; }
  bid="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"

  echo "=== [$v] install + launch ($bid) ==="
  xcrun simctl install "$UDID" "$app" >/dev/null
  installed="$bid"
  xcrun simctl launch "$UDID" "$bid" | grep -qE '[0-9]+$' \
    || { echo "[$v] launch 실패 — FAIL"; xcrun simctl uninstall "$UDID" "$bid" >/dev/null 2>&1 || true; installed=""; fail=1; continue; }

  # 기동 직후 크래시(링크/TLS/dlopen) 검출: N초 후 시뮬레이터 launchd 도메인에
  # 이 앱 잡이 살아있는지(PID 컬럼이 정수 — 종료/크래시면 항목 부재 또는 '-').
  # 호스트 ps/pid 는 시뮬 게스트 pid 네임스페이스와 무관해 신뢰 불가하므로 안 씀.
  sleep "$ALIVE_SECS"
  alive="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null \
           | awk -v b="$bid" 'index($0, b) && $1 ~ /^[0-9]+$/ { print $1; exit }')"
  if [ -n "$alive" ]; then
    xcrun simctl io "$UDID" screenshot "$OUT/ios-$v.png" >/dev/null 2>&1 || true
    echo "[$v] PASS — ${ALIVE_SECS}s 생존(pid=$alive, 링크/기동 무결). 스크린샷: /tmp/ios-smoke-$v.png"
    cp "$OUT/ios-$v.png" "/tmp/ios-smoke-$v.png" 2>/dev/null || true
  else
    echo "[$v] FAIL — 기동 직후 종료(크래시 의심)"
    fail=1
  fi
  xcrun simctl terminate "$UDID" "$bid" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$bid" >/dev/null 2>&1 || true
  installed=""
done

[ "$fail" -eq 0 ] && echo "ALL PASS — 변형 전부 시뮬레이터 빌드+기동 OK" \
                   || { echo "일부 FAIL"; exit 1; }
