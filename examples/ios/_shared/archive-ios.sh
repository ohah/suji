#!/usr/bin/env bash
# iOS 변형 archive + IPA export (배포 서명). zero-native 와 동일하게 최종
# 서명은 Xcode/xcodebuild 가 담당 — 코어/백엔드는 build-lib.sh device 가
# 정적 링크 산출만.
#
# 사용: ./archive-ios.sh <variant>            # 서명 archive+export(IPA)
#       SUJI_IOS_UNSIGNED=1 ./archive-ios.sh <variant>   # 미서명 archive 만
#                                              (Apple 계정 없이 검증용)
# env:
#   SUJI_IOS_TEAM_ID        Apple Developer Team ID (서명 시 필수)
#   SUJI_IOS_EXPORT_METHOD  app-store | ad-hoc | development (기본 development)
#
# 변형: zig|rust|go|multi (examples/ios/<variant>)
set -euo pipefail

VARIANT="${1:?사용: ./archive-ios.sh <zig|rust|go|multi>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$HERE/../$VARIANT"
[ -d "$DIR" ] || { echo "변형 디렉토리 없음: $DIR"; exit 1; }

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

( cd "$DIR" && ./build-lib.sh device )
( cd "$DIR" && xcodegen generate >/dev/null )
PROJ="$(cd "$DIR" && ls -d *.xcodeproj | head -1)"
SCHEME="${PROJ%.xcodeproj}"
ARCHIVE="$OUT/$SCHEME.xcarchive"

if [ "${SUJI_IOS_UNSIGNED:-0}" = "1" ]; then
  echo "[ios] 미서명 archive (CODE_SIGNING_ALLOWED=NO) — 검증 전용"
  ( cd "$DIR" && xcodebuild -project "$PROJ" -scheme "$SCHEME" -sdk iphoneos \
      -configuration Release -archivePath "$ARCHIVE" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive )
  echo "[ios] archive OK (미서명): $SCHEME"
  exit 0
fi

TEAM="${SUJI_IOS_TEAM_ID:?SUJI_IOS_TEAM_ID 필요(서명). 미서명 검증은 SUJI_IOS_UNSIGNED=1}"
METHOD="${SUJI_IOS_EXPORT_METHOD:-development}"

( cd "$DIR" && xcodebuild -project "$PROJ" -scheme "$SCHEME" -sdk iphoneos \
    -configuration Release -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic archive )

EXPORT_PLIST="$OUT/exportOptions.plist"
sed -e "s/__METHOD__/$METHOD/" -e "s/__TEAM_ID__/$TEAM/" \
  "$HERE/exportOptions.plist" > "$EXPORT_PLIST"

IPA_DIR="$DIR/build/ipa"
mkdir -p "$IPA_DIR"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_PLIST" -exportPath "$IPA_DIR"
echo "[ios] IPA: $IPA_DIR ($METHOD, team=$TEAM)"
