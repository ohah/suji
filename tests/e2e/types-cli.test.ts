import { afterAll, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "../..");
const EXAMPLE = path.join(ROOT, "examples", "zig-backend");
const SUJI_BIN = process.platform === "win32"
  ? path.join(ROOT, "zig-out", "bin", "suji.exe")
  : path.join(ROOT, "zig-out", "bin", "suji");

const tempDirs: string[] = [];

afterAll(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-types-cli-"));
  tempDirs.push(dir);
  return dir;
}

async function runTypes(args: string[] = []) {
  const proc = Bun.spawn([SUJI_BIN, "types", ...args], {
    cwd: EXAMPLE,
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
  }, 30_000);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);

  return { stdout, stderr, exitCode, timedOut, combined: `${stdout}\n${stderr}` };
}

function expectCleanExit(result: Awaited<ReturnType<typeof runTypes>>) {
  if (result.timedOut || result.exitCode !== 0) {
    throw new Error(`suji types failed: timedOut=${result.timedOut} exit=${result.exitCode}\n${result.combined}`);
  }
}

function expectZigExampleSchema(dts: string) {
  expect(dts).toContain("declare module '@suji/api'");
  expect(dts).toContain("interface SujiHandlers");
  expect(dts).toContain("ping: { req: void; res: { msg: string } };");
  expect(dts).toContain("greet: { req: { name: string }; res: { msg: string; greeting: string } };");
  expect(dts).toContain("add: { req: { a: number; b: number }; res: { result: number } };");
}

test("suji types prints Zig .schema() declarations to stdout", async () => {
  const result = await runTypes();
  expectCleanExit(result);
  expect(result.stderr).not.toContain("생성할 schema 없음");
  expectZigExampleSchema(result.stdout);
});

test("suji types --out writes the same declarations to a file", async () => {
  const dir = await tempDir();
  const outPath = path.join(dir, "suji-handlers.d.ts");

  const result = await runTypes(["--out", outPath]);
  expectCleanExit(result);
  expect(result.stdout).toBe("");
  expect(result.stderr).toContain("[suji types] →");

  const dts = await readFile(outPath, "utf8");
  expectZigExampleSchema(dts);
});
