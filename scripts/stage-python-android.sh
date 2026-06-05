#!/usr/bin/env bash
# Android embedded CPython staging — iOS 와 달리 prebuilt CPython 3.13 Android 가
# 없어서(PEP 738 공식 지원이나 python-build-standalone/BeeWare 3.13 Android 미배포)
# **소스에서 NDK 크로스빌드**한다(official Android/android.py). ~/.suji/python-android/
# <ver>/<abi> 에 lib(libpython3.13.so + stdlib)/include 를 정리.
#
# ⚠️ 길다(build-python 부트스트랩 + cross host-python, 20~40분) + android.py 가
# 지정 NDK(Android/android-env.sh ndk_version)를 sdkmanager 로 설치한다. iOS
# stage-python-ios.sh(prebuilt 다운로드)와 비대칭은 Android 생태계 사정.
#
# 사전: ANDROID_HOME(SDK), JAVA_HOME 또는 java(PATH), curl. 멱등(이미 있으면 skip).
# env override: PYTHON_VERSION(3.13.13), ANDROID_ABI(arm64-v8a)
# 사용: ./scripts/stage-python-android.sh

set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.13.13}"
ABI="${ANDROID_ABI:-arm64-v8a}"
case "$ABI" in
  arm64-v8a) HOST_TRIPLE="aarch64-linux-android" ;;
  x86_64)    HOST_TRIPLE="x86_64-linux-android" ;;
  *) echo "지원 abi: arm64-v8a | x86_64" >&2; exit 1 ;;
esac

DEST="${HOME}/.suji/python-android/${PYTHON_VERSION}/${ABI}"
if [ -f "${DEST}/lib/libpython3.13.so" ]; then
  echo "[stage-python-android] already staged: ${DEST}/lib/libpython3.13.so"
  exit 0
fi

: "${ANDROID_HOME:?ANDROID_HOME(SDK 경로) 필요}"
command -v curl >/dev/null || { echo "curl 필요" >&2; exit 1; }
if [ -z "${JAVA_HOME:-}" ] && ! command -v java >/dev/null; then
  echo "java(JDK) 필요 — JAVA_HOME 설정 또는 java on PATH" >&2; exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "[stage-python-android] downloading CPython ${PYTHON_VERSION} source"
curl -fsSL "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" -o "$work/py.tgz"
tar -xzf "$work/py.tgz" -C "$work"
SRC="$work/Python-${PYTHON_VERSION}"

echo "[stage-python-android] cross-building (NDK, ~20-40분) — android.py"
( cd "$SRC/Android"
  python3 android.py configure-build
  python3 android.py make-build
  python3 android.py configure-host "$HOST_TRIPLE"
  python3 android.py make-host "$HOST_TRIPLE" )

PFX="$SRC/cross-build/${HOST_TRIPLE}/prefix"
[ -f "$PFX/lib/libpython3.13.so" ] || { echo "[stage-python-android] FAILED — libpython 미생성" >&2; exit 1; }

mkdir -p "$DEST"
cp -R "$PFX/lib" "$DEST/lib"
cp -R "$PFX/include" "$DEST/include"
echo "[stage-python-android] staged: ${DEST}"
