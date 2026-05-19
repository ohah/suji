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
`frontend/index.html`(의존 0 정적 stub).

다음 단계:

```bash
cd my-app
suji dev      # suji 바이너리 필요 (별도 설치)
```

`frontend/` 는 빠른 시작용 정적 stub 입니다. Vite 로 교체(`--frontend` 값에
맞춰 안내됨, 기본 `react-ts`):

```bash
cd my-app/frontend && npm create vite@latest . -- --template react-ts
```

> ⚠️ `bin/cli.js` 산출물은 `src/core/init.zig`(로컬 `suji init`)와 **동형**이고
> `templates/*` 는 `src/templates/*` 의 사본입니다. **단일출처는 init.zig** —
> 변경 시 양쪽을 lockstep 으로 유지하세요.
