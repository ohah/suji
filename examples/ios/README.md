# Suji iOS 예제 (언어별)

PC 예제(`examples/{rust,go,multi}-backend`)에 대응하는 iOS 호스트들.
모바일은 `suji dev`/CEF/dlopen 이 없어 **호스트 셸에 정적 링크**한다 — 그래서
"언어별"은 별도 앱이 아니라 *어떤 백엔드를 링크/등록하느냐*의 차이다.
Xcode 스캐폴딩 중복을 피하려고 호스트 소스를 [`_shared/`](./_shared)에 두고
변형은 thin(`project.yml` + `Backends.swift` + `web/`)으로 둔다.

| 변형 | 백엔드 | 빌드 |
|---|---|---|
| [`multi/`](./multi) | Rust + Go + Swift 네이티브 | `multi/build-lib.sh` |
| [`rust/`](./rust) | Rust(`.a`) + Swift 네이티브 | `rust/build-lib.sh` |
| [`go/`](./go) | Go(`.a` c-archive) + Swift 네이티브 | `go/build-lib.sh` |
| [`zig/`](./zig) | Zig staticlib(`backends/zig`) + Swift 네이티브 | `zig/build-lib.sh` |

> **Node 는 iOS 미지원** — V8 JIT 가 iOS 코드서명 샌드박스에서 금지. (정적
> 링크해도 런타임 코드 생성 불가, `--jitless` 비실용.)

## 실행

```bash
brew install xcodegen                       # 최초 1회
cd examples/ios/<variant>
./build-lib.sh                              # 코어+백엔드 .a 스테이징(Vendor/)
xcodegen generate && open *.xcodeproj       # 시뮬레이터 실행
```

## 구조

- `_shared/` — AppDelegate / SujiHostViewController(WKWebView+`suji_core_*` +
  ping/counter Swift 데모 + `demo:tick` 이벤트) / Suji-Bridging-Header.h / Info.plist.
  모든 변형이 `project.yml` 의 `sources: ../_shared` 로 공유.
- `<variant>/Backends.swift` — `registerStaticBackends()` 가 그 변형의 백엔드만
  `suji_core_register_handler` 로 등록. `(channel,json)→{"cmd":..}` 브리지 포함.
- `backends/{rust,go,zig}` — iOS·Android 공유 백엔드 소스(언어 고유 심볼
  `suji_rs_*`/`suji_go_*`/`suji_zig_*`). rust/go 메커니즘은 `tests/mobile-backends`
  가 호스트 실증(zig 백엔드는 동일 ABI, 예제 시연).

API 차이: 모바일은 invoke/emit/on + 호스트 핸들러만. `windows.*`/`clipboard`/
`dialog`/플러그인 등 데스크톱 네이티브 API·플러그인은 CEF 호스트 전용.
