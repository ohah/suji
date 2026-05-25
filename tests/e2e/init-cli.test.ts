import { afterAll, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "../..");
const SUJI_BIN = process.platform === "win32"
  ? path.join(ROOT, "zig-out", "bin", "suji.exe")
  : path.join(ROOT, "zig-out", "bin", "suji");
const CLI_BIN = path.join(ROOT, "packages", "suji-cli", "bin", "cli.js");

const tempDirs: string[] = [];

afterAll(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-init-cli-"));
  tempDirs.push(dir);
  return dir;
}

async function run(cmd: string, args: string[], cwd: string, timeoutMs = 120_000) {
  const proc = Bun.spawn([cmd, ...args], {
    cwd,
    env: {
      ...process.env,
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

async function expectGeneratedWorkflow(projectDir: string) {
  const workflow = await readFile(path.join(projectDir, ".github", "workflows", "suji.yml"), "utf8");
  expect(workflow).toContain("name: suji");
  expect(workflow).toContain("bun run build");
  expect(workflow).toContain("zig fmt --check");
  expect(workflow).toContain("cargo build --manifest-path");
  expect(workflow).toContain("go build ./...");
  return workflow;
}

async function buildFrontend(projectDir: string) {
  const install = await run("bun", ["install"], path.join(projectDir, "frontend"));
  expectClean(install, "bun install generated frontend");
  const build = await run("bun", ["run", "build"], path.join(projectDir, "frontend"));
  expectClean(build, "bun run build generated frontend");
}

test("suji init scaffolds GitHub Actions CI template and buildable frontend", async () => {
  const dir = await tempDir();
  const project = "app-zig";

  const init = await run(SUJI_BIN, ["init", project, "--backend=zig", "--frontend=vanilla"], dir);
  expectClean(init, "suji init");

  const projectDir = path.join(dir, project);
  await expectGeneratedWorkflow(projectDir);
  await buildFrontend(projectDir);
});

test("@suji/cli scaffolds the same GitHub Actions CI template", async () => {
  const dir = await tempDir();
  const project = "app-multi";

  const init = await run("node", [CLI_BIN, "init", project, "--backend=multi", "--frontend=vanilla"], dir);
  expectClean(init, "@suji/cli init");

  const workflow = await expectGeneratedWorkflow(path.join(dir, project));
  const sourceWorkflow = await readFile(path.join(ROOT, "src", "templates", ".github", "workflows", "suji.yml"), "utf8");
  expect(workflow).toBe(sourceWorkflow);
  await buildFrontend(path.join(dir, project));
});

test("@suji/cli npm package includes hidden GitHub Actions template", async () => {
  const pack = await run("npm", ["pack", "--dry-run", "--json"], path.join(ROOT, "packages", "suji-cli"));
  expectClean(pack, "npm pack --dry-run");

  const [meta] = JSON.parse(pack.stdout);
  const paths = meta.files.map((f: { path: string }) => f.path);
  expect(paths).toContain("templates/.github/workflows/suji.yml");
});
