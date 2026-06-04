# Vendored Lua 5.4

- **Source**: <https://github.com/lua/lua/archive/refs/tags/v5.4.8.tar.gz>
  (lua.org 공식 tarball과 동일한 소스 트리. 빌드 환경에서 www.lua.org 접속이
  막혀 GitHub 공식 미러를 사용)
- **Version**: Lua `5.4.8` (`LUA_VERSION_*` in `lua.h`)
- **v5.4.8.tar.gz sha256**: `d85b70a65f43c5d2254944d58d625e822c8e2e10d9c6a3bd9b5b657e46376a19`
- **License**: MIT (see copyright notice in `lua.h`)

## Files

- `onelua.c` — Lua의 공식 amalgamation. `-DMAKE_LIB`로 컴파일하면
  `lua.c`(stand-alone 인터프리터)·`luac.c`(바이트코드 컴파일러)를 제외하고
  **라이브러리 + 표준 라이브러리만** 단일 translation unit으로 빌드한다
  (SQLite `sqlite3.c` amalgamation과 동형). `/build.zig`의 `buildLuaLibrary`가
  이 파일 하나만 `addCSourceFile`로 컴파일한다.
- 나머지 `.c`(`lapi.c` … `lzio.c`, 라이브러리 포함) — `onelua.c`가 `#include`로
  끌어쓰므로 디렉토리에 함께 있어야 한다. 직접 컴파일하지는 않는다.
- 헤더(`lua.h luaconf.h lualib.h lauxlib.h` + 내부 헤더) — `@cImport` 및
  `onelua.c` 컴파일에 필요.
- **제외**: `lua.c`(인터프리터 main), `luac.c`(컴파일러 main),
  `ltests.c`/`ltests.h`(내부 테스트 훅) — 임베드 라이브러리에 불필요.

## Platform / build

플랫폼 feature 매크로(`LUA_USE_MACOSX`/`LUA_USE_LINUX`)는 `luaconf.h`를 패치하지
않고 `/build.zig`가 컴파일러 `-D`로 주입한다(업그레이드 시 diff 0). 정적 링크이며
`LUA_BUILD_AS_DLL`은 **정의하지 않는다**(Windows에서 `__declspec(dllimport)`
미해소 방지).

## Upgrade

새 태그 tarball을 받아 `lua.c`/`luac.c`/`ltests.*`를 제외한 `src/*.c`·`*.h`를
교체하고 위 버전 + sha256을 갱신한다.
