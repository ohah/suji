# Vendored lua-cjson 2.1.0

- **Source**: <https://github.com/mpx/lua-cjson/archive/refs/tags/2.1.0.tar.gz>
- **Version**: lua-cjson `2.1.0`
- **2.1.0.tar.gz sha256**: `8449f696d56edf27a318daa315d324757bf68120306fecbeb28a66b86077d8cd`
- **License**: MIT (see `LICENSE`)

## Files

- `lua_cjson.c` — JSON encode/decode 라이브러리. `luaopen_cjson`이 진입점이며
  내부에서 `fpconv_init()`을 호출해 locale 소수점 문자를 초기화한다(잘못된
  locale에서 숫자 인코딩 깨짐 방지).
- `fpconv.c` / `fpconv.h` — locale-aware double↔string 변환. libc `snprintf("%g")`
  / `strtod`만 사용한다(`USE_INTERNAL_FPCONV` 미정의 경로).
- `strbuf.c` / `strbuf.h` — 동적 문자열 버퍼.
- **제외**: `dtoa.c` / `g_fmt.c` / `dtoa_config.h` — `USE_INTERNAL_FPCONV`
  고정밀 변환 경로용. 미정의 시 `fpconv.c`가 libc 경로로 동작하므로 불필요.

## Build / 통합

`/build.zig`의 `buildLuaLibrary`가 `lua_cjson.c` + `fpconv.c` + `strbuf.c`를
vendored Lua 정적 라이브러리에 함께 컴파일한다. `src/platform/lua.zig`가
`luaL_requiref(L, "cjson", luaopen_cjson, 0)`로 등록 → Lua 백엔드에서
`require("cjson")`로 사용. `<math.h>`(isinf/isnan) 의존은 `link_libc=true`로 해소.

## Upgrade

새 태그 tarball에서 위 5개 파일 + `LICENSE`를 교체하고 버전 + sha256을 갱신한다.
`luaopen_cjson`이 `fpconv_init()`을 호출하는 버전(2.1.0+)을 유지할 것.
