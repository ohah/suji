#!/usr/bin/env node
// @suji/cli — Suji 프로젝트 스캐폴더 (npx @suji/cli init <name>).
// suji 바이너리 불요(순수 Node, 의존 0). 산출물은 src/core/init.zig 와
// 동형 — ⚠️ 단일출처는 init.zig. templates/* 는 src/templates/* 의 사본
// (drift 주의: 둘을 lockstep 유지). frontend 는 suji init(bunx create-vite)
// 과 달리 의존 0 정적 stub — README 가 Vite 교체를 안내.
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const TPL = join(dirname(fileURLToPath(import.meta.url)), "..", "templates");
const tpl = (n) => readFileSync(join(TPL, n), "utf8");
const die = (m) => { console.error("error: " + m); process.exit(1); };

const argv = process.argv.slice(2);
let cmd = argv[0];
// `create-suji <name>` 별칭: init 생략 허용.
let rest = argv.slice(1);
if (cmd && cmd !== "init") { rest = argv; cmd = "init"; }
const USAGE =
  "사용법: npx @suji/cli init <name> [--backend=zig|rust|go|multi] [--frontend=react|vue|svelte|solid|preact|vanilla]";
if (cmd !== "init") die(USAGE);

let name = null;
let backend = "rust"; // init.zig 기본값과 동일
let frontendTpl = "react"; // init.zig FrontendTemplate 기본값과 동일
for (const a of rest) {
  if (a.startsWith("--backend=")) backend = a.slice("--backend=".length);
  else if (a.startsWith("--frontend=")) frontendTpl = a.slice("--frontend=".length);
  else if (!a.startsWith("-") && !name) name = a;
}
if (!name) die("프로젝트 이름 필요: npx @suji/cli init <name>");
if (!["zig", "rust", "go", "multi"].includes(backend))
  die("backend 는 zig|rust|go|multi 중 하나");
if (!["react", "vue", "svelte", "solid", "preact", "vanilla"].includes(frontendTpl))
  die("frontend 는 react|vue|svelte|solid|preact|vanilla 중 하나");
if (existsSync(name)) die(`'${name}' 이미 존재`);

const W = (p, c) => {
  mkdirSync(dirname(join(name, p)), { recursive: true });
  writeFileSync(join(name, p), c);
};

// suji.json — init.zig writeConfig 동형(multi vs 단일 backend).
const schema =
  "https://raw.githubusercontent.com/ohah/suji/main/suji.schema.json";
const frontend =
  `"frontend": { "dir": "frontend", "dev_url": "http://localhost:5173", "dist_dir": "frontend/dist" }`;
const win =
  `"windows": [{ "name": "main", "title": "${name}", "width": 1024, "height": 768, "debug": true }]`;
const sujiJson = backend === "multi"
  ? `{
  "$schema": "${schema}",
  "app": { "name": "${name}", "version": "0.1.0" },
  ${win},
  "backends": [
    { "name": "zig", "lang": "zig", "entry": "backends/zig" },
    { "name": "rust", "lang": "rust", "entry": "backends/rust" },
    { "name": "go", "lang": "go", "entry": "backends/go" }
  ],
  ${frontend}
}
`
  : `{
  "$schema": "${schema}",
  "app": { "name": "${name}", "version": "0.1.0" },
  ${win},
  "backend": { "lang": "${backend}", "entry": "." },
  ${frontend}
}
`;
W("suji.json", sujiJson);
W(".gitignore", tpl("gitignore"));

// 백엔드 스캐폴딩 — init.zig scaffoldZig/Rust/Go 동형.
const scaffoldZig = (d) => W(join(d, "app.zig"), tpl("zig_app.zig"));
const scaffoldRust = (d) => {
  W(join(d, "Cargo.toml"), tpl("rust_cargo.toml"));
  W(join(d, "src/lib.rs"), tpl("rust_lib.rs"));
};
const scaffoldGo = (d) => {
  W(join(d, "go.mod"), `module ${name}\n\ngo 1.26\n`);
  W(join(d, "main.go"), tpl("go_main.go"));
};
if (backend === "zig") scaffoldZig("");
else if (backend === "rust") scaffoldRust("");
else if (backend === "go") scaffoldGo("");
else {
  scaffoldZig("backends/zig");
  scaffoldRust("backends/rust");
  scaffoldGo("backends/go");
}

// frontend — 의존 0 정적 stub(suji dev 가 frontend.dir 서빙). README 가
// Vite 교체 안내(suji init 의 bunx create-vite 대신).
W("frontend/index.html", `<!doctype html>
<html><head><meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${name}</title></head>
<body style="font:16px system-ui;padding:2rem">
  <h1>${name}</h1>
  <button id="ping">ping</button>
  <pre id="out">…</pre>
  <script>
    document.getElementById("ping").onclick = function () {
      suji.invoke("ping").then(function (r) {
        document.getElementById("out").textContent = JSON.stringify(r);
      });
    };
  </script>
</body></html>
`);

console.log(`✓ ${name} (${backend} + ${frontendTpl}) 생성 완료

  cd ${name}
  suji dev          # 개발 서버 (suji 바이너리 필요)

frontend/ 는 의존 0 정적 stub 입니다. Vite 로 교체하려면:
  cd ${name}/frontend && npm create vite@latest . -- --template ${frontendTpl}-ts
`);
