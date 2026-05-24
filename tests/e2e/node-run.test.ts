import { afterAll, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "../..");
const SUJI_BIN = process.platform === "win32"
  ? path.join(ROOT, "zig-out", "bin", "suji.exe")
  : path.join(ROOT, "zig-out", "bin", "suji");

const tempDirs: string[] = [];

afterAll(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function makeNodeRunFixture(source: string): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-node-run-"));
  tempDirs.push(dir);

  const scopeDir = path.join(dir, "node_modules", "@suji");
  await mkdir(scopeDir, { recursive: true });
  await symlink(
    path.join(ROOT, "packages", "suji-node"),
    path.join(scopeDir, "node"),
    process.platform === "win32" ? "junction" : "dir",
  );

  await writeFile(path.join(dir, "main.js"), source, "utf8");
  return dir;
}

async function runSuji(args: string[]) {
  const proc = Bun.spawn([SUJI_BIN, ...args], {
    cwd: ROOT,
    env: { ...process.env, SUJI_LOG_LEVEL: "error" },
    stdout: "pipe",
    stderr: "pipe",
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, 20_000);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);

  return { stdout, stderr, exitCode, timedOut, combined: `${stdout}\n${stderr}` };
}

test("suji run main.js executes embedded Node.js with @suji/node bridge", async () => {
  const dir = await makeNodeRunFixture(`
    const { platform, quit } = require('@suji/node');
    console.log('NODE_RUN_OK:' + platform());
    setTimeout(() => quit(), 0);
  `);

  const result = await runSuji(["run", path.join(dir, "main.js")]);
  expect(result.timedOut).toBe(false);
  expect(result.exitCode).toBe(0);
  expect(result.combined).toContain("[suji-node] run:");
  expect(result.combined).toMatch(/NODE_RUN_OK:(macos|linux|windows)/);
});

test("suji run <dir> resolves <dir>/main.js", async () => {
  const dir = await makeNodeRunFixture(`
    const { platform, quit } = require('@suji/node');
    console.log('NODE_RUN_DIR_OK:' + platform());
    setTimeout(() => quit(), 0);
  `);

  const result = await runSuji(["run", dir]);
  expect(result.timedOut).toBe(false);
  expect(result.exitCode).toBe(0);
  expect(result.combined).toMatch(/NODE_RUN_DIR_OK:(macos|linux|windows)/);
});
