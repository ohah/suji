# @suji/cli

Suji 프로젝트 스캐폴더. **`suji` 바이너리 없이** `npx` 만으로 새 프로젝트 생성
(Tauri `create-tauri-app` 대응).

```bash
npx @suji/cli init my-app                 # 기본 backend=rust, frontend=react
npx @suji/cli init my-app --backend=zig   # zig | rust | go | multi
npx @suji/cli init my-app --frontend=vue  # react | vue | svelte | solid | preact | vanilla
# 별칭: npx create-suji my-app
```

생성물: `suji.json` · 백엔드(zig=`app.zig` / rust=`Cargo.toml`+`src/lib.rs` /
go=`go.mod`+`main.go` / multi=`backends/{zig,rust,go}`) · `.gitignore` ·
`frontend/`(`--frontend` 프레임워크의 번들 Vite 템플릿 — `invoke("ping")`/
`invoke("greet")` 데모가 스캐폴딩 백엔드와 연결되어 동작).

다음 단계:

```bash
cd my-app/frontend && bun install   # 또는 npm/pnpm install
cd .. && suji dev                   # suji 바이너리 필요 (별도 설치)
```

> ℹ️ 프론트엔드는 `src/suji.ts`(런타임 `window.__suji__` 래퍼)로 백엔드를
> 호출합니다. `@suji/api` 가 npm 에 발행되면 `import ... from "@suji/api"`
> 로 교체 가능(표면 동일, 코드 변경 0).

> ⚠️ `bin/cli.js` 산출물은 `src/core/init.zig`(로컬 `suji init`)와 **동형**이고
> `templates/*` 는 `src/templates/*` 의 사본입니다. **단일출처는 init.zig** —
> 변경 시 양쪽을 lockstep 으로 유지하세요.
