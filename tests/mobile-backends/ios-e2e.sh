#!/usr/bin/env bash
# iOS 시뮬레이터 *기능* e2e — ios-sim-smoke.sh(빌드+생존)와 달리, 디바이스
# 안에서 데스크톱과 동일한 __suji__.core 와이어로 clipboard 실 왕복(시뮬=실
# UIPasteboard → 진짜 e2e)을 자가 검증하고 verdict 를 회수·assert 한다.
#
# 흐름: build-lib→xcodegen→xcodebuild → SUJI_E2E 모드로 launch(e2e.html) →
#       앱 데이터컨테이너 Documents/suji-e2e-report.json 폴링 → ok&&fail==0 assert.
# 정직: 시뮬레이터 clipboard 는 실 네이티브(진짜 e2e). dialog 탭/실 알림
#       표시/실기기는 범위 밖(스모크/미검증, docs/PLAN.md).
#
# 사용: ./ios-e2e.sh [variant]   (기본 zig)
# 선행: xcodegen, 부팅된 iOS 시뮬레이터 1대.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
V="${1:-zig}"
dir="$REPO/examples/ios/$V"
[ -d "$dir" ] || { echo "변형 디렉토리 없음: $dir"; exit 1; }

command -v xcodegen >/dev/null || { echo "xcodegen 미설치"; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild 미발견"; exit 1; }
UDID="$(xcrun simctl list devices booted | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()')"
[ -n "$UDID" ] || { echo "부팅된 시뮬레이터 없음"; exit 1; }

OUT="$(mktemp -d)"
installed=""
trap 'rm -rf "$OUT"; [ -z "$installed" ] || xcrun simctl uninstall "$UDID" "$installed" >/dev/null 2>&1 || true' EXIT
echo "시뮬레이터 UDID=$UDID, 변형=$V"

echo "=== build-lib.sh sim ==="
( cd "$dir" && bash build-lib.sh sim >/dev/null )
# xcodegen 을 proj 계산(ls)보다 먼저 — .xcodeproj 는 전 변형이 .gitignore 대상이라
# 아무도 커밋하지 않는다(전부 project.yml 만). xcodegen 이 생성해야 ls 가 찾으므로
# 깨끗한 체크아웃에서 ls-first 면 proj 가 비어 xcodebuild 가 모호하게 실패한다.
echo "=== xcodegen ==="
( cd "$dir" && xcodegen generate >/dev/null )
proj="$(cd "$dir" && ls -d *.xcodeproj | head -1)"
[ -n "$proj" ] || { echo "FAIL: .xcodeproj 없음 (xcodegen 실패?)"; exit 1; }
scheme="${proj%.xcodeproj}"
echo "=== xcodebuild ($scheme) ==="
( cd "$dir" && xcodebuild -project "$proj" -scheme "$scheme" -sdk iphonesimulator \
    -derivedDataPath "$OUT/dd" ARCHS=arm64 build >/dev/null )

app="$(find "$OUT/dd/Build/Products" -maxdepth 3 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "FAIL: .app 산출물 없음"; exit 1; }
bid="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
# e2e.html 번들 포함 확인 (project.yml 의 web 소스그룹이 자동 포함하나 결정적 확인).
[ -e "$app/e2e.html" ] || [ -e "$app/web/e2e.html" ] \
  || { echo "FAIL: e2e.html 미번들"; exit 1; }

echo "=== install + e2e launch ($bid) ==="
xcrun simctl install "$UDID" "$app" >/dev/null
installed="$bid"
xcrun simctl privacy "$UDID" grant notifications "$bid" >/dev/null 2>&1 || true
# SIMCTL_CHILD_* 는 simctl 이 앱 환경으로 전달 → 호스트가 e2e.html 로드.
SIMCTL_CHILD_SUJI_E2E=1 xcrun simctl launch --terminate-running-process "$UDID" "$bid" \
  | grep -qE '[0-9]+$' || { echo "FAIL: launch"; exit 1; }

echo "=== verdict 폴링 (앱 데이터컨테이너) ==="
report=""
for _ in $(seq 1 60); do
  cont="$(xcrun simctl get_app_container "$UDID" "$bid" data 2>/dev/null || true)"
  if [ -n "$cont" ] && [ -f "$cont/Documents/suji-e2e-report.json" ]; then
    report="$(cat "$cont/Documents/suji-e2e-report.json")"
    break
  fi
  sleep 2
done
xcrun simctl io "$UDID" screenshot "$OUT/ios-e2e.png" >/dev/null 2>&1 \
  && cp "$OUT/ios-e2e.png" /tmp/ios-e2e-"$V".png 2>/dev/null || true
[ -n "$report" ] || { echo "FAIL: verdict 미회수(60x2s 타임아웃)"; exit 1; }

echo "verdict: $report"
echo "$report" | bun -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const v=JSON.parse(s);
    const bad=v.cases.filter(c=>!c.ok).map(c=>c.name);
    if(v.ok===true && v.fail===0){ console.log("iOS e2e PASS — "+v.cases.length+" cases ("+v.suite+")"); process.exit(0); }
    console.log("iOS e2e FAIL — "+JSON.stringify(bad)); process.exit(1);
  });'
