#!/usr/bin/env node
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

const binName = process.platform === "win32" ? "suji.exe" : "suji";
const packageRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);

function nativePackageName() {
  const platform = process.platform;
  const arch = process.arch;
  if (platform === "darwin" && arch === "arm64") return "@suji/suji-darwin-arm64";
  if (platform === "darwin" && arch === "x64") return "@suji/suji-darwin-x64";
  if (platform === "linux" && arch === "x64") return "@suji/suji-linux-x64";
  if (platform === "linux" && arch === "arm64") return "@suji/suji-linux-arm64";
  if (platform === "win32" && arch === "x64") return "@suji/suji-win32-x64";
  if (platform === "win32" && arch === "arm64") return "@suji/suji-win32-arm64";
  return null;
}

function candidates() {
  const list = [];
  if (process.env.SUJI_NATIVE_BIN) list.push(process.env.SUJI_NATIVE_BIN);
  list.push(join(packageRoot, "..", "..", "zig-out", "bin", binName));

  const pkg = nativePackageName();
  if (pkg) {
    try {
      list.push(require.resolve(`${pkg}/bin/${binName}`));
    } catch {
      try {
        list.push(require.resolve(`${pkg}/${binName}`));
      } catch {}
    }
  }
  return list;
}

const binary = candidates().find((path) => existsSync(path));
if (!binary) {
  console.error(
    "error: suji native binary not found. Set SUJI_NATIVE_BIN or install the matching @suji/suji-* package.",
  );
  process.exit(1);
}

const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status ?? 0);
