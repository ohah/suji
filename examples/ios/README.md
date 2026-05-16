# Suji iOS 호스트 예제

CEF 무관 Suji 코어(`libsuji_core.a`)를 iOS 앱에 임베드하는 최소 호스트.
Swift가 `WKWebView`를 띄우고 `suji_core_*` C ABI를 호출, 프론트엔드의
`window.__suji__.invoke()` ↔ 네이티브를 왕복한다.

> 데스크톱은 CEF가 창/렌더러를 들지만, iOS에는 CEF가 안 들어간다.
> 대신 OS의 `WKWebView`가 렌더러, Suji 코어는 정적 라이브러리로 임베드된다.

## 1. 코어 정적 라이브러리 빌드

레포 루트에서 (또는 `examples/ios/build-lib.sh` 실행):

```bash
zig build lib -Dtarget=aarch64-ios -Doptimize=ReleaseSafe
mkdir -p examples/ios/Vendor
cp zig-out/lib/libsuji_core.a examples/ios/Vendor/
```

C 헤더는 레포의 [`include/suji_core.h`](../../include/suji_core.h)를 그대로 쓴다
(Xcode 프로젝트가 header search path로 참조).

## 2. Xcode 프로젝트 생성

손으로 관리하기 어려운 `.xcodeproj` 대신 [XcodeGen](https://github.com/yonaskolb/XcodeGen)
스펙(`project.yml`)으로 생성한다:

```bash
brew install xcodegen          # 최초 1회
cd examples/ios
./build-lib.sh                 # 코어 .a 빌드 + 스테이징
xcodegen generate              # project.yml → SujiIOSExample.xcodeproj
open SujiIOSExample.xcodeproj
```

시뮬레이터(arm64) 또는 디바이스 선택 후 `SujiIOSExample` 스킴 실행.

## 3. 동작

- `Sources/SujiHostViewController.swift` — `WKWebView` 호스팅, `suji_core_init()`,
  `WKScriptMessageHandler`로 JS→네이티브, `suji_core_on`으로 네이티브→JS 이벤트.
- `Sources/web/index.html` — `window.__suji__.invoke("ping")` 왕복 + 이벤트 수신
  데모 (번들러 없이 인라인 로드).
- `Sources/Suji-Bridging-Header.h` — `suji_core.h`를 Swift로 노출.

## 파일

| 파일 | 역할 |
|---|---|
| `project.yml` | XcodeGen 프로젝트 스펙 (target/링크/bridging header) |
| `build-lib.sh` | `zig build lib -Dtarget=aarch64-ios` + `.a` 스테이징 |
| `Sources/AppDelegate.swift` | UIApplication 진입 |
| `Sources/SujiHostViewController.swift` | WKWebView + C ABI 브릿지 |
| `Sources/Suji-Bridging-Header.h` | C 헤더 → Swift |
| `Sources/web/index.html` | 데모 프론트엔드 |
| `Sources/Info.plist` | 앱 메타 |

## 한계 (현재)

C ABI 표면은 `invoke/emit/on/off`만. 윈도우/clipboard/dialog 등 데스크톱
네이티브 API는 CEF 호스트 전용이라 iOS에서는 동작하지 않는다 (코어 라우팅과
이벤트, 백엔드 invoke만 검증 가능). 렌더러 eval은 호스트가 `suji_core_on`
콜백에서 `evaluateJavaScript`로 직접 펌핑한다.
