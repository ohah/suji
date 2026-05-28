# @suji/cli

Suji 프로젝트 스캐폴더. `npx @suji/cli init` 또는 `npx create-suji`로
프로젝트를 만들고, 설치 후에는 `suji dev/build/types`를 npm script처럼 실행합니다.

```bash
npx @suji/cli init my-app
npx create-suji my-app

npx @suji/cli init my-app \
  --backend=zig \
  --frontend=react \
  --toolchain=vite \
  --pm=npm
```

옵션:

- `--backend=none|zig|rust|go|node|lua|multi`
- `--frontend=react|vue|svelte|solid|preact|vanilla|next`
- `--toolchain=vite|rsbuild|next` (`rspack`은 `rsbuild` 별칭)
- `--pm=npm|pnpm|bun|vp` (`vz`, `voidzero`, `viteplus`는 VoidZero Vite+ `vp` 별칭)
- `--install`은 생성 직후 `frontend/`에서 선택한 패키지 매니저 install 실행

생성물:

- 루트 `package.json` (`dev/build/types` scripts, `@suji/cli` devDependency)
- `suji.config.ts` source config + materialized `suji.json`
- `frontend.dev_url=http://localhost:12300`, `dev_command`, `build_command`
- 백엔드 템플릿 (`zig`, `rust`, `go`, `node`, `lua`, `multi`)
- `frontend/` 템플릿 (Vite, Rsbuild, Next static export)
- `.github/workflows/suji.yml`

다음 단계:

```bash
cd my-app
npm install
npm run dev
```

`--pm=vp`를 선택하면 Vite+ 명령을 사용합니다:

```bash
vp install
vp run dev
```

`bin/cli.js` 산출물은 `src/core/init.zig`(로컬 `suji init`)와 동형이고
`templates/*`는 `src/templates/*`의 사본입니다. 변경 시 양쪽을 lockstep으로
유지하세요.
