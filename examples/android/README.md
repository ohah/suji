# Suji Android 호스트 예제

CEF 무관 Suji 코어(`libsuji_core.a`)를 Android 앱에 임베드하는 최소 호스트.
Kotlin이 `WebView`를 띄우고, JNI `.so`가 정적 `libsuji_core.a`를 링크해
`suji_core_*` C ABI를 호출한다.

> iOS는 Swift가 C ABI를 직접 부르지만, Android는 런타임에 `.a`를 dlopen 못 한다.
> JNI 브리지(`libsujihost.so`)가 `libsuji_core.a`를 **정적 링크**하고,
> Kotlin이 `System.loadLibrary("sujihost")` 로 그 `.so` 를 로드한다.

## 1. 코어 정적 라이브러리 빌드

```bash
cd examples/android
./build-lib.sh        # zig build lib -Dtarget=<abi>-linux-android → app/src/main/cpp/libs/<abi>/
```

기본 `arm64-v8a`. `./build-lib.sh x86_64` 로 에뮬레이터용도 추가 가능.
C 헤더는 레포 [`include/suji_core.h`](../../include/suji_core.h) 를 CMake가 참조.

## 2. 빌드 & 실행

```bash
cd examples/android
./build-lib.sh
./gradlew installDebug      # 또는 Android Studio 로 open
```

## 동작

- `app/src/main/cpp/suji_jni.c` — JNI: `nativeInit/nativeInvoke/nativeEmit/nativeDestroy`
  + `nativeRegisterEvents` (suji_core_on 트램폴린 → JVM 콜백).
- `app/src/main/cpp/CMakeLists.txt` — `libsuji_core.a` 를 IMPORTED STATIC 으로
  링크해 `libsujihost.so` 생성.
- `MainActivity.kt` — `WebView` + `@JavascriptInterface` 로 JS→네이티브,
  네이티브→JS 는 `evaluateJavascript`.
- `app/src/main/assets/web/index.html` — invoke 왕복 + `demo:tick` 이벤트 데모.

## 한계 (현재)

C ABI 표면은 `invoke/emit/on/off`만. 윈도우/clipboard/dialog 등 데스크톱
네이티브 API는 CEF 호스트 전용이라 Android 에서는 동작하지 않는다.

## 파일

| 파일 | 역할 |
|---|---|
| `build-lib.sh` | `zig build lib -Dtarget=<abi>-linux-android` + `.a` 스테이징 |
| `settings.gradle` / `build.gradle` | Gradle 프로젝트 |
| `app/build.gradle` | NDK + CMake externalNativeBuild |
| `app/src/main/cpp/CMakeLists.txt` | JNI `.so` ← `libsuji_core.a` 정적 링크 |
| `app/src/main/cpp/suji_jni.c` | JNI ↔ C ABI 브리지 |
| `app/src/main/java/.../MainActivity.kt` | WebView + JS 브리지 |
| `app/src/main/assets/web/index.html` | 데모 프론트엔드 |
| `app/src/main/AndroidManifest.xml` | 앱 메타 |
