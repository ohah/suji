#!/usr/bin/env bash
# Android embedded Node.js staging — libnode.so + node embedding headers 를
# ~/.suji/node-android/<ver>/<abi> 에 lib/include 로 정리.
#
# 1순위: build-libnode.yml 가 만든 release asset(libnode-v<ver> android-<arch>)
#        다운로드 — 데스크톱 libnode staging 동형(end-user 머신엔 prebuilt 만,
#        Docker/NDK 불요). build-libnode.yml 을 workflow_dispatch 로 1회 빌드해두면
#        이후엔 모두 다운로드.
# 2순위(폴백): 소스 크로스빌드. ⚠️ V8 의 cross host-tool(mksnapshot/torque)이 Linux
#        를 가정하므로 **Linux x86_64 host(CI ubuntu)** 가 필요하다(macOS host 는
#        framework/SDK/archive 패치 다발 — 정직 경계). 그래서 소스 빌드는 CI 전제.
#
# 사전: curl. (소스 폴백 시 ANDROID_NDK_HOME, python3, make, g++)
# env override: NODE_VERSION(24.14.1), ANDROID_ABI(arm64-v8a), SUJI_REPO(ohah/suji)
# 사용: bash scripts/stage-node-android.sh
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.14.1}"
ABI="${ANDROID_ABI:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) DEST_CPU="arm64"; ASSET_ARCH="arm64" ;;
  x86_64)    DEST_CPU="x86_64"; ASSET_ARCH="x86_64" ;;
  *) echo "지원 abi: arm64-v8a | x86_64" >&2; exit 1 ;;
esac

DEST="${HOME}/.suji/node-android/${NODE_VERSION}/${ABI}"
if [ -f "${DEST}/lib/libnode.so" ]; then
  echo "[stage-node-android] already staged: ${DEST}/lib/libnode.so"
  exit 0
fi
command -v curl >/dev/null || { echo "curl 필요" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$DEST/lib" "$DEST/include"

# 1순위 — prebuilt release asset (build-libnode.yml 산출).
REPO_SLUG="${SUJI_REPO:-ohah/suji}"
ASSET="libnode-${NODE_VERSION}-android-${ASSET_ARCH}.tar.gz"
ASSET_URL="https://github.com/${REPO_SLUG}/releases/download/libnode-v${NODE_VERSION}/${ASSET}"
if curl -fSL "$ASSET_URL" -o "$work/pkg.tar.gz" 2>/dev/null; then
  echo "[stage-node-android] downloaded prebuilt: $ASSET_URL"
  mkdir -p "$work/ex"
  tar xzf "$work/pkg.tar.gz" -C "$work/ex"
  cp "$work/ex/libnode.so" "$DEST/lib/libnode.so"
  cp -R "$work/ex/include/." "$DEST/include/"
  echo "[stage-node-android] staged (prebuilt): $DEST"
  ls -1 "$DEST/lib"
  exit 0
fi

echo "[stage-node-android] prebuilt 없음 → 소스 크로스빌드 폴백"
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME(NDK 경로) 필요 — 소스 빌드}"
command -v python3 >/dev/null || { echo "python3 필요" >&2; exit 1; }
case "$(uname -s)" in
  Linux) ;;
  *) echo "[stage-node-android] ⚠️ 비-Linux host($(uname -s)) — V8 host-tool 가정상 Linux(CI ubuntu) 필요. host build 실패 가능(정직 경계)." >&2 ;;
esac

echo "[stage-node-android] downloading Node ${NODE_VERSION} source"
curl -fSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.gz" -o "$work/node.tgz"
tar -xzf "$work/node.tgz" -C "$work"
SRC="$work/node-v${NODE_VERSION}"

echo "[stage-node-android] cross-building libnode.so (NDK, ~30-60분)"
( cd "$SRC"
  # android-configure 는 python(exec python3 "$0") — source 금지(run 블록을 python 으로
  # 재실행해 깨진다). 직접 실행 + configure 호출에 --shared 주입(android_configure.py 는
  # 3 인자 고정 + configure 를 --shared 없이 호출). DEST_CPU 는 arm64(arm64-v8a).
  sed -i 's| --cross-compiling")| --cross-compiling --shared --without-npm --without-corepack")|' android_configure.py
  ./android-configure "$ANDROID_NDK_HOME" 26 "$DEST_CPU"
  make -j"$(nproc)" )

LIB="$(ls "$SRC/out/Release/lib/libnode.so."* "$SRC/out/Release/libnode.so."* 2>/dev/null | head -1)"
[ -n "$LIB" ] || { echo "[stage-node-android] FAILED — libnode.so 미생성(out/Release)" >&2; exit 1; }
cp "$LIB" "$DEST/lib/libnode.so"
# build-libnode.yml Package 와 동형 — uv/ 하위(uv/unix.h 등)까지 복사해야
# bridge.cc 의 #include <uv.h>(→ uv/unix.h) 가 풀린다(top-level *.h 만 복사하면
# uv/ 하위 누락 → NDK clang++ 컴파일 실패). v8 도 -R 로 전체.
cp -R "$SRC"/deps/v8/include/* "$DEST/include/" 2>/dev/null || true
cp -R "$SRC"/deps/uv/include/* "$DEST/include/" 2>/dev/null || true
for h in node.h node_version.h node_api.h node_api_types.h js_native_api.h js_native_api_types.h; do
  cp "$SRC/src/$h" "$DEST/include/" 2>/dev/null || true
done
echo "[stage-node-android] staged (source): ${DEST}"
ls -1 "$DEST/lib"
