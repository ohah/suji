import { afterAll, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "../..");
const tempDirs: string[] = [];

afterAll(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
});

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-go-types-helper-"));
  tempDirs.push(dir);
  return dir;
}

function modPath(p: string): string {
  return p.replaceAll("\\", "/");
}

async function writeGoConsumer(dir: string) {
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, "go.mod"), `\
module suji-go-types-helper-e2e

go 1.26

require github.com/ohah/suji-go v0.0.0

replace github.com/ohah/suji-go => ${modPath(path.join(ROOT, "sdks", "suji-go"))}
`);

  await writeFile(path.join(dir, "main.go"), `\
package main

import (
	"fmt"

	suji "github.com/ohah/suji-go"
)

type PingRes struct {
	Msg string \`json:"msg"\`
}

type GreetReq struct {
	Name string \`json:"name"\`
}

type GreetRes struct {
	Greeting string \`json:"greeting"\`
}

type AddReq struct {
	FirstValue  int     \`json:"firstValue"\`
	SecondValue float64 \`json:"secondValue"\`
	Optional    *string \`json:"optional,omitempty"\`
	Ignored     string  \`json:"-"\`
}

type AddRes struct {
	Result int \`json:"result"\`
}

func main() {
	dts, err := suji.NewTSHandlers().
		Handler("ping", nil, PingRes{}).
		Handler("greet", GreetReq{}, GreetRes{}).
		Handler("math:add", AddReq{}, AddRes{}).
		Export()
	if err != nil {
		panic(err)
	}
	fmt.Print(dts)
}
`);
}

async function goRun(dir: string) {
  const proc = Bun.spawn(["go", "run", "."], {
    cwd: dir,
    env: {
      ...process.env,
      CGO_ENABLED: process.env.CGO_ENABLED ?? "1",
      CC: process.env.CC ?? "/usr/bin/clang",
    },
    stdout: "pipe",
    stderr: "pipe",
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, 120_000);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  return { stdout, stderr, exitCode, timedOut };
}

test("Go TSHandlers helper generates frontend module augmentation", async () => {
  const dir = await tempDir();
  await writeGoConsumer(dir);

  const result = await goRun(dir);
  if (result.timedOut || result.exitCode !== 0) {
    throw new Error(`go run failed: timedOut=${result.timedOut} exit=${result.exitCode}\n${result.stderr}`);
  }

  const dts = result.stdout;
  expect(dts).toContain("declare module '@suji/api'");
  expect(dts).toContain("interface SujiHandlers");
  expect(dts).toContain("ping: { req: void; res: PingRes };");
  expect(dts).toContain("greet: { req: GreetReq; res: GreetRes };");
  expect(dts).toContain("\"math:add\": { req: AddReq; res: AddRes };");
  expect(dts).toContain("export type PingRes =");
  expect(dts).toContain("msg: string");
  expect(dts).toContain("firstValue: number");
  expect(dts).toContain("secondValue: number");
  expect(dts).toContain("optional?: string | null");
  expect(dts).toContain("result: number");
  expect(dts).not.toContain("Ignored");
});
