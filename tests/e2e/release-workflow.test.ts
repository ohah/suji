import { expect, test } from "bun:test";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const ROOT = path.resolve(import.meta.dir, "../..");

async function run(cmd: string, args: string[]) {
  const proc = Bun.spawn([cmd, ...args], {
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout: stdout.trim(), stderr: stderr.trim(), exitCode, combined: `${stdout}\n${stderr}` };
}

test("release version script matches build.zig.zon and rejects mismatched tags", async () => {
  const version = await run("bash", ["scripts/version.sh"]);
  expect(version.exitCode, version.combined).toBe(0);
  expect(version.stdout).toMatch(/^\d+\.\d+\.\d+$/);

  const matching = await run("bash", ["scripts/version.sh", "--check", `v${version.stdout}`]);
  expect(matching.exitCode, matching.combined).toBe(0);
  expect(matching.stdout).toContain(`v${version.stdout}`);

  const mismatched = await run("bash", ["scripts/version.sh", "--check", "v0.0.0-never"]);
  expect(mismatched.exitCode).not.toBe(0);
  expect(mismatched.stderr).toContain("버전 불일치");
});

test("release workflow dry-run builds all expected artifacts without publishing", async () => {
  const workflow = await readFile(path.join(ROOT, ".github", "workflows", "release.yml"), "utf8");

  expect(workflow).toContain("workflow_dispatch:");
  expect(workflow).toContain("default: true");
  expect(workflow).toContain("if: github.event_name == 'push' || github.event.inputs.dry_run == 'false'");
  expect(workflow).toContain("actions/upload-artifact@v4");
  expect(workflow).toContain("softprops/action-gh-release@v2");

  for (const asset of ["suji-macos-arm64", "suji-linux-x64", "suji-windows-x64"]) {
    expect(workflow).toContain(`asset: ${asset}`);
  }

  for (const target of ["aarch64-ios", "aarch64-linux-android", "x86_64-windows"]) {
    expect(workflow).toContain(`-Dtarget=${target}`);
  }

  expect(workflow).toContain("zig build lib $flags");
  expect(workflow).toContain("suji-embed-libs-$V.tar.gz");
  expect(workflow).toContain("CHECKSUMS.txt");
  expect(workflow).toContain("homebrew:");
  expect(workflow).toContain("bash scripts/homebrew-formula.sh");
  expect(workflow).toContain("name: homebrew-formula");
  expect(workflow).toContain("HOMEBREW_TAP_TOKEN");
  expect(workflow).toContain("needs: [version, cli, embed-libs, homebrew]");
});

test("homebrew formula generator emits release asset URLs and valid Ruby", async () => {
  const macosSha = "a".repeat(64);
  const linuxSha = "b".repeat(64);
  const formula = await run("bash", [
    "scripts/homebrew-formula.sh",
    "1.2.3",
    macosSha,
    linuxSha,
    "https://example.test/releases/v1.2.3",
  ]);

  expect(formula.exitCode, formula.combined).toBe(0);
  expect(formula.stdout).toContain("class Suji < Formula");
  expect(formula.stdout).toContain('version "1.2.3"');
  expect(formula.stdout).toContain("https://example.test/releases/v1.2.3/suji-macos-arm64.tar.gz");
  expect(formula.stdout).toContain("https://example.test/releases/v1.2.3/suji-linux-x64.tar.gz");
  expect(formula.stdout).toContain(`sha256 "${macosSha}"`);
  expect(formula.stdout).toContain(`sha256 "${linuxSha}"`);
  expect(formula.stdout).toContain('bin.install "suji"');

  const dir = await mkdtemp(path.join(os.tmpdir(), "suji-homebrew-formula-"));
  const formulaPath = path.join(dir, "suji.rb");
  await writeFile(formulaPath, formula.stdout);
  const ruby = await run("ruby", ["-c", formulaPath]);
  expect(ruby.exitCode, ruby.combined).toBe(0);
  expect(ruby.stdout).toContain("Syntax OK");
});

test("homebrew formula generator rejects invalid checksums", async () => {
  const bad = await run("bash", [
    "scripts/homebrew-formula.sh",
    "1.2.3",
    "not-a-sha",
    "b".repeat(64),
  ]);

  expect(bad.exitCode).not.toBe(0);
  expect(bad.stderr).toContain("invalid macOS sha256");
});
