import { afterAll, expect, test } from "bun:test";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "../..");
const SUJI_BIN = process.platform === "win32"
  ? path.join(ROOT, "zig-out", "bin", "suji.exe")
  : path.join(ROOT, "zig-out", "bin", "suji");
const CLI_BIN = path.join(ROOT, "packages", "suji-cli", "bin", "cli.js");
const SUJI_JS_BIN = path.join(ROOT, "packages", "suji-cli", "bin", "suji.js");

const tempDirs: string[] = [];

afterAll(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-init-cli-"));
  tempDirs.push(dir);
  return dir;
}

async function run(
  cmd: string,
  args: string[],
  cwd: string,
  timeoutMs = 180_000,
  env: Record<string, string | undefined> = {},
) {
  const proc = Bun.spawn([cmd, ...args], {
    cwd,
    env: {
      ...process.env,
      ...env,
      SUJI_LOG_LEVEL: "error",
    },
    stdout: "pipe",
    stderr: "pipe",
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, timeoutMs);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  return { stdout, stderr, exitCode, timedOut, combined: `${stdout}\n${stderr}` };
}

function expectClean(result: Awaited<ReturnType<typeof run>>, label: string) {
  expect(result.timedOut, `${label} timed out\n${result.combined}`).toBe(false);
  expect(result.exitCode, `${label} failed\n${result.combined}`).toBe(0);
}

async function readJson<T>(file: string): Promise<T> {
  return JSON.parse(await readFile(file, "utf8")) as T;
}

async function expectGeneratedWorkflow(projectDir: string) {
  const workflow = await readFile(path.join(projectDir, ".github", "workflows", "suji.yml"), "utf8");
  expect(workflow).toContain("name: suji");
  expect(workflow).toContain("bun run build");
  expect(workflow).toContain("zig fmt --check");
  expect(workflow).toContain("cargo build --manifest-path");
  expect(workflow).toContain("go build ./...");
  return workflow;
}

async function expectAgentDocs(projectDir: string, backendNeedle: string) {
  const agents = await readFile(path.join(projectDir, "AGENTS.md"), "utf8");
  expect(agents).toContain(backendNeedle);
  expect(agents).toContain("https://ohah.github.io/suji/llms.txt");
  const claude = await readFile(path.join(projectDir, "CLAUDE.md"), "utf8");
  expect(claude).toContain("@AGENTS.md");
}

async function buildFrontend(projectDir: string) {
  const install = await run("bun", ["install"], path.join(projectDir, "frontend"));
  expectClean(install, "bun install generated frontend");
  const build = await run("bun", ["run", "build"], path.join(projectDir, "frontend"));
  expectClean(build, "bun run build generated frontend");
}

test("suji init scaffolds 12300 npm-command config and buildable frontend", async () => {
  const dir = await tempDir();
  const project = "app-zig";

  const init = await run(SUJI_BIN, [
    "init",
    project,
    "--backend=zig",
    "--frontend=vanilla",
    "--toolchain=vite",
    "--pm=npm",
  ], dir);
  expectClean(init, "suji init");

  const projectDir = path.join(dir, project);
  const suji = await readJson<any>(path.join(projectDir, "suji.json"));
  expect(suji.frontend.dev_url).toBe("http://localhost:12300");
  expect(suji.frontend.dev_command).toBe("npm run dev");
  expect(suji.frontend.build_command).toBe("npm run build");
  expect(suji.backend).toEqual({ lang: "zig", entry: "." });
  await expectGeneratedWorkflow(projectDir);
  await expectAgentDocs(projectDir, "Zig");
  await buildFrontend(projectDir);
});

test("@suji/cli scaffolds multi backend rsbuild project", async () => {
  const dir = await tempDir();
  const project = "app-rsbuild";

  const init = await run("node", [
    CLI_BIN,
    "init",
    project,
    "--backend=multi",
    "--frontend=react",
    "--toolchain=rsbuild",
    "--pm=pnpm",
  ], dir);
  expectClean(init, "@suji/cli init");

  const projectDir = path.join(dir, project);
  const workflow = await expectGeneratedWorkflow(projectDir);
  const sourceWorkflow = await readFile(path.join(ROOT, "src", "templates", ".github", "workflows", "suji.yml"), "utf8");
  expect(workflow).toBe(sourceWorkflow);

  const suji = await readJson<any>(path.join(projectDir, "suji.json"));
  expect(suji.frontend.dev_command).toBe("pnpm run dev");
  expect(suji.frontend.build_command).toBe("pnpm run build");
  expect(suji.frontend.dist_dir).toBe("frontend/dist");
  expect(suji.backends.map((b: any) => b.lang)).toEqual(["zig", "rust", "go", "lua", "python"]);
  // lua/python 임베드 런타임은 router 자동 등록이라 zig 의 ping/greet 와 충돌하지
  // 않도록 네임스페이스 채널 템플릿이 스캐폴드돼야 한다(중복 등록 → auto-routing 차단 방지).
  const luaMain = await readFile(path.join(projectDir, "backends", "lua", "main.lua"), "utf8");
  expect(luaMain).toContain('suji.handle("lua-ping"');
  const pyMain = await readFile(path.join(projectDir, "backends", "python", "main.py"), "utf8");
  expect(pyMain).toContain('suji.handle("python-ping"');
  await expectAgentDocs(projectDir, "(multi)");
  await buildFrontend(projectDir);
});

test("@suji/cli supports VoidZero Vite+ runner aliases", async () => {
  const dir = await tempDir();
  const project = "app-next-vp";

  const init = await run("node", [
    CLI_BIN,
    "init",
    project,
    "--backend=none",
    "--frontend=next",
    "--toolchain=next",
    "--pm=vz",
  ], dir);
  expectClean(init, "@suji/cli init next/vp");

  const projectDir = path.join(dir, project);
  const suji = await readJson<any>(path.join(projectDir, "suji.json"));
  const pkg = await readJson<any>(path.join(projectDir, "package.json"));
  expect(suji.backend).toBeUndefined();
  expect(suji.backends).toBeUndefined();
  expect(suji.frontend.dev_url).toBe("http://localhost:12300");
  expect(suji.frontend.dev_command).toBe("vp run dev");
  expect(suji.frontend.build_command).toBe("vp run build");
  expect(suji.frontend.dist_dir).toBe("frontend/out");
  expect(pkg.packageManager).toBe("pnpm@latest");
  await buildFrontend(projectDir);
});

test("@suji/cli scaffolds node, lua, and python backend entries without root package conflicts", async () => {
  const dir = await tempDir();

  const nodeInit = await run("node", [
    CLI_BIN,
    "init",
    "app-node",
    "--backend=node",
    "--frontend=vanilla",
    "--pm=bun",
  ], dir);
  expectClean(nodeInit, "@suji/cli node init");

  const nodeDir = path.join(dir, "app-node");
  const nodeSuji = await readJson<any>(path.join(nodeDir, "suji.json"));
  const rootPkg = await readJson<any>(path.join(nodeDir, "package.json"));
  const backendPkg = await readJson<any>(path.join(nodeDir, "backends", "node", "package.json"));
  expect(nodeSuji.backend).toEqual({ lang: "node", entry: "backends/node" });
  expect(rootPkg.devDependencies["@suji/cli"]).toBe("^0.1.0");
  expect(backendPkg.dependencies["@suji/node"]).toBe("^0.1.0");

  const luaInit = await run("node", [
    CLI_BIN,
    "init",
    "app-lua",
    "--backend=lua",
    "--frontend=vanilla",
  ], dir);
  expectClean(luaInit, "@suji/cli lua init");

  const luaSuji = await readJson<any>(path.join(dir, "app-lua", "suji.json"));
  expect(luaSuji.backend).toEqual({ lang: "lua", entry: "backends/lua" });
  expect(await readFile(path.join(dir, "app-lua", "backends", "lua", "main.lua"), "utf8")).toContain("suji.handle");

  const pythonInit = await run("node", [
    CLI_BIN,
    "init",
    "app-python",
    "--backend=python",
    "--frontend=vanilla",
  ], dir);
  expectClean(pythonInit, "@suji/cli python init");

  const pythonSuji = await readJson<any>(path.join(dir, "app-python", "suji.json"));
  expect(pythonSuji.backend).toEqual({ lang: "python", entry: "backends/python" });
  expect(await readFile(path.join(dir, "app-python", "backends", "python", "main.py"), "utf8")).toContain("suji.handle");
});

const frontendCases = [
  ["react", "vite"],
  ["vue", "vite"],
  ["svelte", "vite"],
  ["solid", "vite"],
  ["preact", "vite"],
  ["vanilla", "vite"],
  ["react", "rsbuild"],
  ["vue", "rsbuild"],
] as const;

for (const [frontend, toolchain] of frontendCases) {
  test(`@suji/cli generated ${frontend}/${toolchain} frontend builds`, async () => {
    const dir = await tempDir();
    const project = `app-${frontend}-${toolchain}`;

    const init = await run("node", [
      CLI_BIN,
      "init",
      project,
      "--backend=none",
      `--frontend=${frontend}`,
      `--toolchain=${toolchain}`,
    ], dir);
    expectClean(init, `@suji/cli ${frontend}/${toolchain} init`);
    await buildFrontend(path.join(dir, project));
  });
}

test("@suji/cli suji bin launches resolved native binary", async () => {
  const dir = await tempDir();
  const fakeBin = path.join(dir, "fake-suji");
  await writeFile(fakeBin, "#!/bin/sh\necho fake-suji \"$@\"\n");
  await chmod(fakeBin, 0o755);

  const result = await run("node", [SUJI_JS_BIN, "--version"], ROOT, 30_000, {
    SUJI_NATIVE_BIN: fakeBin,
  });
  expectClean(result, "suji js launcher");
  expect(result.stdout).toContain("fake-suji --version");
});

test("@suji/cli suji launcher reads static suji.json config", async () => {
  const dir = await tempDir();
  await writeFile(path.join(dir, "suji.json"), JSON.stringify({
    app: { name: "Static JSON Config", version: "1.0.0" },
    frontend: { dev_url: "http://localhost:12300" },
  }));

  const result = await run("node", [SUJI_JS_BIN, "types"], dir, 30_000, {
    SUJI_NATIVE_BIN: SUJI_BIN,
  });
  expectClean(result, "native static config through suji launcher");
  expect(result.stderr).toContain("[suji types] 생성할 schema 없음");
  expect(result.stderr).not.toContain("Error: suji.json not found");
});

test("@suji/cli npm package includes bins and hidden GitHub Actions template", async () => {
  const pack = await run("npm", ["pack", "--dry-run", "--json"], path.join(ROOT, "packages", "suji-cli"));
  expectClean(pack, "npm pack --dry-run");

  const [meta] = JSON.parse(pack.stdout);
  const paths = meta.files.map((f: { path: string }) => f.path);
  expect(paths).toContain("bin/cli.js");
  expect(paths).toContain("bin/suji.js");
  expect(paths).toContain("lib/init.js");
  expect(paths).toContain("index.js");
  expect(paths).toContain("index.d.ts");
  expect(paths).toContain("templates/.github/workflows/suji.yml");
  expect(paths).toContain("templates/frontend/rsbuild-react/package.json");
  expect(paths).toContain("templates/frontend/next/package.json");
});
