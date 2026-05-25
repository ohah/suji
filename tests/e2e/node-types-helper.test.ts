import { afterAll, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "../..");
const tempDirs: string[] = [];

afterAll(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-node-types-helper-"));
  tempDirs.push(dir);
  return dir;
}

function modPath(p: string): string {
  return p.replaceAll("\\", "/");
}

async function writeConsumer(dir: string) {
  const sujiNodeSource = modPath(path.join(ROOT, "packages", "suji-node", "src", "index.ts"));
  await writeFile(path.join(dir, "tsconfig.json"), JSON.stringify({
    compilerOptions: {
      target: "ES2020",
      module: "Node16",
      moduleResolution: "Node16",
      strict: true,
      noEmit: true,
      skipLibCheck: true,
      baseUrl: ".",
      paths: {
        "@suji/node": [sujiNodeSource],
      },
    },
    include: ["consumer.ts"],
  }, null, 2));

  await writeFile(path.join(dir, "consumer.ts"), `\
import { call, callSync, invoke, invokeSync } from "@suji/node";

declare module "@suji/node" {
  interface SujiHandlers {
    ping: { req: void; res: { msg: string } };
    greet: { req: { name: string }; res: string };
    add: { req: { a: number; b: number }; res: number };
  }
}

async function checks() {
  const ping = await invoke("zig", { cmd: "ping" });
  const msg: string = ping.msg;

  const greet = await invoke("zig", { cmd: "greet", name: "Suji" });
  const greeting: string = greet;

  const sum = await invoke("zig", { cmd: "add", a: 1, b: 2 });
  const total: number = sum;

  const called = await call("zig", "greet", { name: "Node" });
  const calledGreeting: string = called;

  const syncGreet = invokeSync("zig", { cmd: "greet", name: "Sync" });
  const syncGreeting: string = syncGreet;

  const syncCalled = callSync("zig", "ping");
  const syncMsg: string = syncCalled.msg;

  const untyped = await invoke<{ ok: boolean }>("zig", { cmd: "anything" });
  const ok: boolean = untyped.ok;

  // @ts-expect-error - greet requires name.
  const badMissing: string = await invoke("zig", { cmd: "greet" });

  // @ts-expect-error - typo does not satisfy greet request.
  const badTypo: string = await invoke("zig", { cmd: "greet", Name: "Suji" });

  // @ts-expect-error - call keeps registered command request strict.
  await call("zig", "greet");

  // @ts-expect-error - response type mismatch.
  const badRes: number = await invoke("zig", { cmd: "greet", name: "Suji" });

  void msg; void greeting; void total; void calledGreeting; void syncGreeting;
  void syncMsg; void ok; void badMissing; void badTypo; void badRes;
}

void checks;
`);
}

async function typecheck(dir: string) {
  const tsc = path.join(ROOT, "packages", "suji-node", "node_modules", "typescript", "bin", "tsc");
  const proc = Bun.spawn(["node", tsc, "-p", "tsconfig.json"], {
    cwd: dir,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, exitCode };
}

test("Node SDK SujiHandlers augmentation typechecks in an external consumer", async () => {
  const dir = await tempDir();
  await writeConsumer(dir);

  const result = await typecheck(dir);
  expect(result.exitCode, `${result.stdout}\n${result.stderr}`).toBe(0);
});
