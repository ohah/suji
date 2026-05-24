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
  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-rust-types-helper-"));
  tempDirs.push(dir);
  return dir;
}

function tomlPath(p: string): string {
  return JSON.stringify(p.replaceAll("\\", "/"));
}

async function writeRustConsumer(dir: string) {
  await mkdir(path.join(dir, "src"), { recursive: true });
  await writeFile(path.join(dir, "Cargo.toml"), `\
[package]
name = "suji-rust-types-helper-e2e"
version = "0.0.0"
edition = "2021"

[dependencies]
suji = { path = ${tomlPath(path.join(ROOT, "crates", "suji-rs"))} }
serde = { version = "1", features = ["derive"] }
`);

  await writeFile(path.join(dir, "src", "main.rs"), `\
use serde::{Deserialize, Serialize};
use suji::prelude::*;

#[derive(Type, Serialize, Deserialize)]
struct PingRes {
    msg: String,
}

#[derive(Type, Serialize, Deserialize)]
struct GreetReq {
    name: String,
}

#[derive(Type, Serialize, Deserialize)]
struct GreetRes {
    greeting: String,
}

#[derive(Type, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AddReq {
    first_value: i32,
    second_value: i32,
}

#[derive(Type, Serialize, Deserialize)]
struct AddRes {
    result: i32,
}

fn main() {
    let dts = SujiHandlers::new()
        .handler::<(), PingRes>("ping")
        .handler::<GreetReq, GreetRes>("greet")
        .handler::<AddReq, AddRes>("math:add")
        .export()
        .unwrap();
    print!("{dts}");
}
`);
}

async function cargoRun(dir: string) {
  const proc = Bun.spawn(["cargo", "run", "--quiet"], {
    cwd: dir,
    env: {
      ...process.env,
      CARGO_TERM_COLOR: "never",
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

test("Rust SujiHandlers helper generates frontend module augmentation", async () => {
  const dir = await tempDir();
  await writeRustConsumer(dir);

  const result = await cargoRun(dir);
  if (result.timedOut || result.exitCode !== 0) {
    throw new Error(`cargo run failed: timedOut=${result.timedOut} exit=${result.exitCode}\n${result.stderr}`);
  }

  const dts = result.stdout;
  expect(dts).toContain("declare module '@suji/api'");
  expect(dts).toContain("interface SujiHandlers");
  expect(dts).toContain("ping: { req: void; res: PingRes };");
  expect(dts).toContain("greet: { req: GreetReq; res: GreetRes };");
  expect(dts).toContain("\"math:add\": { req: AddReq; res: AddRes };");
  expect(dts).toContain("export type PingRes =");
  expect(dts).toContain("msg: string");
  expect(dts).toContain("export type GreetReq =");
  expect(dts).toContain("name: string");
  expect(dts).toContain("firstValue: number");
  expect(dts).toContain("secondValue: number");
});
