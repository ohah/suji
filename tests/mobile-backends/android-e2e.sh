#!/usr/bin/env bash
# Android 에뮬레이터 *기능* e2e — 디바이스 안에서 데스크톱과 동일한
# __suji__.core 와이어로 clipboard 실 왕복(에뮬=실 ClipboardManager → 진짜
# e2e)을 자가 검증하고 verdict 를 logcat 으로 회수·assert. iOS ios-e2e.sh 동형.
#
# 정직: 에뮬 clipboard 는 실 네이티브(진짜 e2e). dialog 탭/실 알림 표시/
#       실기기는 범위 밖(스모크/미검증, docs/PLAN.md).
#
# 사용: ./android-e2e.sh [variant]   (기본 zig)
# 선행: ~/Library/Android/sdk + 부팅된 에뮬레이터(없으면 zl_poc AVD 부팅).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
V="${1:-zig}"
dir="$REPO/examples/android/$V"
[ -d "$dir" ] || { echo "변형 디렉토리 없음: $dir"; exit 1; }

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"

# JDK 탐지 — AGP 8.5.2 는 JDK 17~21. Android Studio JBR 우선(시스템
# /usr/bin/java 는 런타임 부재 stub). brew openjdk 25 는 AGP 비호환이라 회피.
if [ -z "${JAVA_HOME:-}" ]; then
  for j in "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
           "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" \
           "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; do
    [ -n "$j" ] && [ -x "$j/bin/java" ] && { export JAVA_HOME="$j"; break; }
  done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "JDK 17~21 미발견 — JAVA_HOME 설정 필요"; exit 1; }
echo "JAVA_HOME=$JAVA_HOME"
SDK="$ANDROID_SDK_ROOT"
ADB="$SDK/platform-tools/adb"
EMU="$SDK/emulator/emulator"
[ -x "$ADB" ] || { echo "adb 미발견: $ADB"; exit 1; }
PKG="dev.suji.examples.android.$V"
ACT="dev.suji.examples.android.MainActivity"

spawned=""
trap '"$ADB" uninstall "$PKG" >/dev/null 2>&1 || true;
      [ -z "$spawned" ] || "$ADB" -s "$spawned" emu kill >/dev/null 2>&1 || true' EXIT

# 부팅된 디바이스 재사용, 없으면 AVD 부팅(zl_poc 우선).
SERIAL="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
if [ -z "$SERIAL" ]; then
  AVD="$("$SDK"/cmdline-tools/*/bin/avdmanager list avd 2>/dev/null \
        | awk -F': ' '/Name:/{print $2; exit}')"
  [ -n "$AVD" ] || { echo "AVD 없음 — 생성 필요"; exit 1; }
  echo "=== 에뮬 부팅 ($AVD) ==="
  "$EMU" -avd "$AVD" -no-window -no-snapshot -no-audio >/dev/null 2>&1 &
  spawned="$("$ADB" wait-for-device >/dev/null 2>&1; "$ADB" devices \
            | awk 'NR>1 && $2=="device"{print $1; exit}')"
  SERIAL="$spawned"
fi
echo "device=$SERIAL"
for _ in $(seq 1 60); do
  [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] \
    && break
  sleep 2
done
ABI="$("$ADB" -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')"

echo "=== build-lib.sh $ABI ==="
( cd "$dir" && ./build-lib.sh "$ABI" >/dev/null )

# AGP 8.5.2 ↔ Gradle 호환 wrapper 핀(시스템 gradle 9.x 비호환 회피).
if [ ! -x "$dir/gradlew" ]; then
  echo "=== gradle wrapper 8.9 핀 ==="
  ( cd "$dir" && gradle wrapper --gradle-version 8.9 >/dev/null )
fi
echo "=== assembleDebug ==="
( cd "$dir" && ./gradlew --console=plain :app:assembleDebug >/dev/null )
apk="$(find "$dir/app/build/outputs/apk/debug" -name '*.apk' | head -1)"
[ -n "$apk" ] || { echo "FAIL: apk 산출물 없음"; exit 1; }
# ⚠️ grep -q 는 첫 매치에서 즉시 종료 → 큰 apk(python stdlib 동봉 등)에서 unzip 이
# SIGPIPE(141)로 죽고 set -o pipefail 이 매치 성공에도 파이프라인을 실패시킨다.
# grep(no -q)로 전체를 소비해 SIGPIPE 회피.
unzip -l "$apk" | grep 'assets/e2e.html' >/dev/null || { echo "FAIL: e2e.html 미번들"; exit 1; }

echo "=== install + e2e launch ($PKG) ==="
"$ADB" -s "$SERIAL" install -r "$apk" >/dev/null
"$ADB" -s "$SERIAL" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" logcat -c
"$ADB" -s "$SERIAL" shell am start -n "$PKG/$ACT" --es suji_e2e 1 >/dev/null

echo "=== verdict 폴링 (logcat SujiE2E) ==="
line=""
for _ in $(seq 1 60); do
  line="$("$ADB" -s "$SERIAL" logcat -d -s SujiE2E:I 2>/dev/null \
          | grep -m1 'SUJI_E2E_RESULT' || true)"
  [ -n "$line" ] && break
  sleep 2
done
"$ADB" -s "$SERIAL" exec-out screencap -p > /tmp/android-e2e-"$V".png 2>/dev/null || true
[ -n "$line" ] || { echo "FAIL: verdict 미회수"; "$ADB" -s "$SERIAL" logcat -d | tail -30; exit 1; }

verdict="${line#*SUJI_E2E_RESULT }"
echo "verdict: $verdict"
echo "$verdict" | bun -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const v=JSON.parse(s);
    const bad=v.cases.filter(c=>!c.ok).map(c=>c.name);
    if(v.ok===true && v.fail===0){ console.log("Android e2e PASS — "+v.cases.length+" cases ("+v.suite+")"); process.exit(0); }
    console.log("Android e2e FAIL — "+JSON.stringify(bad)); process.exit(1);
  });'
