import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

const TPL = join(dirname(fileURLToPath(import.meta.url)), "..", "templates");
const tpl = (name) => readFileSync(join(TPL, name), "utf8");
const die = (message) => {
  console.error("error: " + message);
  process.exit(1);
};

export const BACKENDS = new Set(["none", "zig", "rust", "go", "node", "lua", "python", "multi"]);
export const FRAMEWORKS = new Set(["react", "vue", "svelte", "solid", "preact", "vanilla", "next"]);
export const TOOLCHAINS = new Set(["vite", "rsbuild", "next"]);
export const PMS = new Set(["npm", "pnpm", "bun", "vp"]);
export const COMPOSITE_TEMPLATES = new Set([
  "react_vite",
  "vue_vite",
  "svelte_vite",
  "solid_vite",
  "preact_vite",
  "vanilla_vite",
  "react_rsbuild",
  "vue_rsbuild",
  "next_static",
]);

export const USAGE =
  "Usage: npx @suji/cli init <name> [--backend=none|zig|rust|go|node|lua|python|multi] [--frontend=react|vue|svelte|solid|preact|vanilla|next] [--toolchain=vite|rsbuild|next] [--pm=npm|pnpm|bun|vp] [--install]";

export function normalizeToolchain(value) {
  if (value === "rspack") return "rsbuild";
  return value;
}

export function normalizePackageManager(value) {
  if (value === "vz" || value === "voidzero" || value === "viteplus") return "vp";
  return value;
}

export function parseArgs(argv) {
  let cmd = argv[0];
  let rest = argv.slice(1);
  if (cmd && cmd !== "init") {
    rest = argv;
    cmd = "init";
  }
  if (cmd !== "init") die(USAGE);

  const opts = {
    name: null,
    backend: null,
    frontend: null,
    toolchain: null,
    pm: null,
    install: false,
  };

  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    const readValue = (flag) => {
      if (arg.startsWith(`${flag}=`)) return arg.slice(flag.length + 1);
      if (arg === flag) {
        i += 1;
        if (i >= rest.length) die(`${flag} 값이 필요합니다`);
        return rest[i];
      }
      return null;
    };

    const backend = readValue("--backend");
    if (backend !== null) {
      opts.backend = backend;
      continue;
    }
    const frontend = readValue("--frontend");
    if (frontend !== null) {
      opts.frontend = frontend;
      continue;
    }
    const toolchain = readValue("--toolchain");
    if (toolchain !== null) {
      opts.toolchain = normalizeToolchain(toolchain);
      continue;
    }
    const pm = readValue("--pm");
    if (pm !== null) {
      opts.pm = normalizePackageManager(pm);
      continue;
    }
    if (arg === "--install") {
      opts.install = true;
      continue;
    }
    if (arg === "--no-install") {
      opts.install = false;
      continue;
    }
    if (!arg.startsWith("-") && !opts.name) {
      opts.name = arg;
      continue;
    }
    die(`알 수 없는 인자: ${arg}`);
  }

  return opts;
}

export function toolchainsForFramework(framework) {
  if (framework === "next") return ["next"];
  if (framework === "react") return ["vite", "rsbuild", "next"];
  if (framework === "vue") return ["vite", "rsbuild"];
  return ["vite"];
}

export function resolveTemplate(frontend, toolchain) {
  if (COMPOSITE_TEMPLATES.has(frontend)) {
    const [framework, tc] = frontend === "next_static" ? ["next", "next"] : frontend.split("_");
    return templateFor(framework, tc);
  }
  if (!FRAMEWORKS.has(frontend)) die("frontend 는 react|vue|svelte|solid|preact|vanilla|next 중 하나");
  const selectedToolchain = normalizeToolchain(toolchain ?? (frontend === "next" ? "next" : "vite"));
  return templateFor(frontend, selectedToolchain);
}

export function templateFor(framework, toolchain) {
  if (!TOOLCHAINS.has(toolchain)) die("toolchain 은 vite|rsbuild|next 중 하나");

  if (toolchain === "vite") {
    if (framework === "next") die("Next.js 는 --toolchain=next 를 사용해야 합니다");
    return {
      id: `${framework}_vite`,
      framework,
      toolchain,
      dir: framework,
      distDir: "frontend/dist",
    };
  }

  if (toolchain === "rsbuild") {
    if (framework === "react" || framework === "vue") {
      return {
        id: `${framework}_rsbuild`,
        framework,
        toolchain,
        dir: `rsbuild-${framework}`,
        distDir: "frontend/dist",
      };
    }
    die("Rsbuild 템플릿은 react/vue 만 지원합니다");
  }

  if (toolchain === "next") {
    if (framework === "next" || framework === "react") {
      return {
        id: "next_static",
        framework: "next",
        toolchain,
        dir: "next",
        distDir: "frontend/out",
      };
    }
    die("Next.js 템플릿은 frontend=next 또는 frontend=react --toolchain=next 로 선택하세요");
  }

  die("지원하지 않는 frontend/toolchain 조합입니다");
}

export function packageManagerField(pm) {
  if (pm === "vp") return "pnpm@latest";
  return `${pm}@latest`;
}

export function runCommand(pm, script) {
  if (pm === "npm") return `npm run ${script}`;
  if (pm === "pnpm") return `pnpm run ${script}`;
  if (pm === "bun") return `bun run ${script}`;
  return `vp run ${script}`;
}

export function installCommand(pm) {
  if (pm === "npm") return "npm install";
  if (pm === "pnpm") return "pnpm install";
  if (pm === "bun") return "bun install";
  return "vp install";
}

export async function promptMissing(opts) {
  const interactive = process.stdin.isTTY && process.stdout.isTTY;
  if (!interactive) {
    opts.name ??= null;
    opts.backend ??= "zig";
    opts.frontend ??= "react";
    opts.toolchain ??= opts.frontend === "next" ? "next" : "vite";
    opts.pm ??= "npm";
    return opts;
  }

  const rl = createInterface({ input, output });
  try {
    const ask = async (message, choices, fallback) => {
      const suffix = choices?.length ? ` (${choices.join("/")})` : "";
      while (true) {
        const raw = (await rl.question(`${message}${suffix} [${fallback}]: `)).trim();
        const value = raw || fallback;
        if (!choices || choices.includes(value)) return value;
        console.error(`  use one of: ${choices.join(", ")}`);
      }
    };

    opts.name ??= await ask("Project name", null, "suji-app");
    opts.backend ??= await ask("Backend", [...BACKENDS], "zig");
    if (!BACKENDS.has(opts.backend)) die("backend 는 none|zig|rust|go|node|lua|python|multi 중 하나");

    opts.frontend ??= await ask("Frontend", [...FRAMEWORKS], "react");
    if (!FRAMEWORKS.has(opts.frontend) && !COMPOSITE_TEMPLATES.has(opts.frontend)) {
      die("frontend 는 react|vue|svelte|solid|preact|vanilla|next 중 하나");
    }

    const frontendForTools = opts.frontend === "next_static" ? "next" : opts.frontend.split("_")[0];
    const toolchains = toolchainsForFramework(frontendForTools);
    opts.toolchain ??= await ask("Toolchain", toolchains, frontendForTools === "next" ? "next" : toolchains[0]);

    opts.pm ??= normalizePackageManager(await ask("Package manager", ["npm", "pnpm", "bun", "vp", "vz"], "npm"));
    opts.install ||= (await ask("Install frontend dependencies now", ["no", "yes"], "no")) === "yes";
  } finally {
    rl.close();
  }

  return opts;
}

export function write(projectName, relPath, content) {
  mkdirSync(dirname(join(projectName, relPath)), { recursive: true });
  writeFileSync(join(projectName, relPath), content);
}

export function backendLabel(backend) {
  return (
    {
      none: "없음 (frontend-only)",
      zig: "Zig",
      rust: "Rust",
      go: "Go",
      node: "Node.js",
      lua: "Lua",
      python: "Python",
      multi: "Zig · Rust · Go (multi)",
    }[backend] ?? backend
  );
}

// AGENTS.md / CLAUDE.md 템플릿 토큰 치환 (src/templates 와 byte-identical).
export function renderAgentDoc(tplName, name, backend, pm) {
  return tpl(tplName)
    .replaceAll("__NAME__", name)
    .replaceAll("__BACKEND__", backendLabel(backend))
    .replaceAll("__INSTALL__", installCommand(pm))
    .replaceAll("__DEV__", runCommand(pm, "dev"))
    .replaceAll("__BUILD__", runCommand(pm, "build"));
}

export function rootPackageJson(name, pm) {
  return `${JSON.stringify({
    name,
    version: "0.1.0",
    private: true,
    type: "module",
    packageManager: packageManagerField(pm),
    scripts: {
      dev: "suji dev",
      build: "suji build",
      types: "suji types --out frontend/src/suji.generated.d.ts",
    },
    devDependencies: {
      "@suji/cli": "^0.1.0",
    },
  }, null, 2)}\n`;
}

export function sujiJson(name, backend, template, pm) {
  const base = {
    $schema: "https://raw.githubusercontent.com/ohah/suji/main/suji.schema.json",
    app: { name, version: "0.1.0" },
    windows: [{ name: "main", title: name, width: 1024, height: 768, debug: true }],
  };
  const frontend = {
    dir: "frontend",
    dev_url: "http://localhost:12300",
    dev_command: runCommand(pm, "dev"),
    build_command: runCommand(pm, "build"),
    dist_dir: template.distDir,
  };

  if (backend === "none") {
    return `${JSON.stringify({ ...base, frontend }, null, 2)}\n`;
  }

  if (backend === "multi") {
    return `${JSON.stringify({
      ...base,
      backends: [
        { name: "zig", lang: "zig", entry: "backends/zig" },
        { name: "rust", lang: "rust", entry: "backends/rust" },
        { name: "go", lang: "go", entry: "backends/go" },
        { name: "lua", lang: "lua", entry: "backends/lua" },
        { name: "python", lang: "python", entry: "backends/python" },
      ],
      frontend,
    }, null, 2)}\n`;
  }

  const entry = backend === "node"
    ? "backends/node"
    : backend === "lua"
      ? "backends/lua"
      : backend === "python"
        ? "backends/python"
        : ".";
  return `${JSON.stringify({
    ...base,
    backend: { lang: backend, entry },
    frontend,
  }, null, 2)}\n`;
}

export function scaffoldBackend(projectName, backend, name) {
  const W = (relPath, content) => write(projectName, relPath, content);
  const scaffoldZig = (dir) => W(join(dir, "app.zig"), tpl("zig_app.zig"));
  const scaffoldRust = (dir) => {
    W(join(dir, "Cargo.toml"), tpl("rust_cargo.toml"));
    W(join(dir, "src/lib.rs"), tpl("rust_lib.rs"));
  };
  const scaffoldGo = (dir) => {
    W(join(dir, "go.mod"), `module ${name}\n\ngo 1.26\n`);
    W(join(dir, "main.go"), tpl("go_main.go"));
  };
  const scaffoldNode = (dir) => {
    W(join(dir, "package.json"), tpl("node_package.json"));
    W(join(dir, "main.js"), tpl("node_main.js"));
  };
  const scaffoldLua = (dir) => W(join(dir, "main.lua"), tpl("lua_main.lua"));
  const scaffoldPython = (dir) => W(join(dir, "main.py"), tpl("python_main.py"));

  if (backend === "none") return;
  if (backend === "zig") return scaffoldZig("");
  if (backend === "rust") return scaffoldRust("");
  if (backend === "go") return scaffoldGo("");
  if (backend === "node") return scaffoldNode("backends/node");
  if (backend === "lua") return scaffoldLua("backends/lua");
  if (backend === "python") return scaffoldPython("backends/python");

  scaffoldZig("backends/zig");
  scaffoldRust("backends/rust");
  scaffoldGo("backends/go");
  // lua/python 임베드 런타임은 채널을 router 에 자동 등록하므로(rust/go raw dylib 과
  // 달리) zig 의 ping/greet 와 충돌하지 않게 네임스페이스 채널 템플릿을 쓴다.
  W(join("backends/lua", "main.lua"), tpl("multi_lua_main.lua"));
  W(join("backends/python", "main.py"), tpl("multi_python_main.py"));
}

export function scaffoldFrontend(projectName, template) {
  cpSync(join(TPL, "frontend", template.dir), join(projectName, "frontend"), {
    recursive: true,
    filter: (source) => !source.includes(`${sep}node_modules${sep}`) && !source.endsWith(".lock"),
  });
}

export function installFrontend(projectName, pm) {
  const command = installCommand(pm).split(" ");
  const result = spawnSync(command[0], command.slice(1), {
    cwd: join(projectName, "frontend"),
    stdio: "inherit",
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

export async function runInitCli(argv = process.argv.slice(2)) {
  const opts = await promptMissing(parseArgs(argv));
  if (!opts.name) die("프로젝트 이름 필요: npx @suji/cli init <name>");
  if (!BACKENDS.has(opts.backend)) die("backend 는 none|zig|rust|go|node|lua|python|multi 중 하나");
  opts.pm = normalizePackageManager(opts.pm);
  if (!PMS.has(opts.pm)) die("pm 은 npm|pnpm|bun|vp 중 하나");
  if (opts.toolchain) opts.toolchain = normalizeToolchain(opts.toolchain);

  const template = resolveTemplate(opts.frontend, opts.toolchain);
  if (existsSync(opts.name)) die(`'${opts.name}' already exists`);

  mkdirSync(opts.name);
  write(opts.name, "package.json", rootPackageJson(opts.name, opts.pm));
  const configJson = sujiJson(opts.name, opts.backend, template, opts.pm);
  write(opts.name, "suji.json", configJson);
  write(opts.name, ".gitignore", tpl("gitignore"));
  write(opts.name, ".github/workflows/suji.yml", tpl(".github/workflows/suji.yml"));
  write(opts.name, "AGENTS.md", renderAgentDoc("AGENTS.md", opts.name, opts.backend, opts.pm));
  write(opts.name, "CLAUDE.md", renderAgentDoc("CLAUDE.md", opts.name, opts.backend, opts.pm));
  scaffoldBackend(opts.name, opts.backend, opts.name);
  scaffoldFrontend(opts.name, template);
  if (opts.install) installFrontend(opts.name, opts.pm);

  console.log(`✓ ${opts.name} (${opts.backend} + ${template.framework}/${template.toolchain}, ${opts.pm}) created

  cd ${opts.name}
  ${installCommand(opts.pm)}
  ${runCommand(opts.pm, "dev")}
`);
}
