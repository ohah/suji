# Suji Android 예제 (언어별)

iOS(`examples/ios`)와 동형. 모바일은 호스트(JNI `.so`)에 백엔드를 정적/공유
링크 — "언어별"은 별도 앱이 아니라 *어떤 백엔드를 링크/등록하느냐*. Gradle
스캐폴딩 중복을 피하려 호스트(Kotlin/manifest/코어 JNI)를 [`_shared/`](./_shared)
에 두고 변형은 thin(gradle + `cpp/backends.c` + `cpp/CMakeLists.txt` + `web/`).

| 변형 | 백엔드 | 빌드 |
|---|---|---|
| [`multi/`](./multi) | Rust(`.a`) + Go(`.so`) + Kotlin 네이티브 | `multi/build-lib.sh` |
| [`rust/`](./rust) | Rust(`.a`) + Kotlin 네이티브 | `rust/build-lib.sh` |
| `go/` | (후속) Go(`.so` c-shared) | iOS go 와 동형 |
| `zig/` | (후속) Zig staticlib | iOS zig 와 동형 |

> **Go 는 Android 에서 c-archive 미지원 → `c-shared`(`.so`)**. Gradle 이
> `jniLibs/<abi>/` 의 `.so` 를 자동 패키징, CMake 는 SHARED IMPORTED 로 링크.
> Rust/Zig 는 `.a` 정적 링크. **Node**: Android NDK 로 가능하나 미배선(후속).

## 실행

```bash
cd examples/android/<variant>
ANDROID_NDK_HOME=... ./build-lib.sh        # 코어/Rust .a + Go .so 스테이징
./gradlew installDebug                     # 또는 Android Studio 로 open
```

> Gradle/Android 빌드는 사용자 Android 환경 필요(이 레포 CI/로컬에선 NDK
> 컴파일·심볼만 검증). 백엔드 메커니즘은 `tests/mobile-backends`(호스트
> 하니스, CI `mobile-backends` job)가 실증.

## 구조

- `_shared/` — `cpp/suji_jni_core.c`(코어 JNI: init/invoke/emit/on/off +
  Kotlin 핸들러 트램폴린 + 이벤트 + JNI_OnLoad 캐시), `java/`(SujiCore.kt /
  MainActivity.kt: ping/counter Kotlin 데모 + `nativeRegisterStaticBackends`
  호출), `AndroidManifest.xml`. 변형 gradle `sourceSets` 가 공유.
- `<variant>/cpp/backends.c` — `nativeRegisterStaticBackends` 가 그 변형
  백엔드만 `suji_core_register_handler` 로 등록. `(channel,json)→{"cmd":..}`
  는 `include/suji_mobile_bridge.h` 공용(iOS·verify.c 와 동일).
- 백엔드 소스: `examples/ios/backends/{rust,go,zig}` iOS·Android 공유.

API 차이: 모바일은 invoke/emit/on + 호스트 핸들러만. `windows.*`/`clipboard`/
`dialog`/플러그인 등 데스크톱 네이티브 API·플러그인은 CEF 호스트 전용.
