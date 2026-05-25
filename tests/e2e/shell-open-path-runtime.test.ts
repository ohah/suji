/**
 * Shell openPath runtime E2E.
 *
 * Linux Actions registers a temporary MIME type + desktop handler and verifies
 * GIO launches it for `shell.openPath`.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const runId = `${process.pid}-${Date.now()}`;
const extension = `sujiopenpath${process.pid}`;
const mimeType = `application/x-suji-openpath-${runId}`;
const baseDir = path.join(os.tmpdir(), `suji-openpath-e2e-${runId}`);
const markerPath = path.join(baseDir, "marker.txt");
const scriptPath = path.join(baseDir, "handler.sh");
const mimeXmlPath = path.join(baseDir, "suji-openpath.xml");
const targetPath = path.join(baseDir, `target.${extension}`);
const dataHome = process.env.XDG_DATA_HOME ?? path.join(baseDir, "xdg-data");
const appsDir = path.join(dataHome, "applications");
const desktopId = `suji-openpath-${runId}.desktop`;
const desktopPath = path.join(appsDir, desktopId);

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

function shSingleQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function hasCommand(name: string): boolean {
  try {
    execFileSync("sh", ["-lc", `command -v ${name}`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function requireCommand(name: string): void {
  if (!hasCommand(name)) throw new Error(`${name} is required for Linux openPath E2E`);
}

function registerLinuxMimeHandler(): void {
  requireCommand("xdg-mime");
  fs.rmSync(baseDir, { recursive: true, force: true });
  fs.mkdirSync(baseDir, { recursive: true });
  fs.mkdirSync(appsDir, { recursive: true });

  fs.writeFileSync(
    scriptPath,
    `#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s' "$1" > ${shSingleQuote(markerPath)}\n`,
  );
  fs.chmodSync(scriptPath, 0o755);

  fs.writeFileSync(
    mimeXmlPath,
    [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">',
      `  <mime-type type="${mimeType}">`,
      "    <comment>Suji openPath E2E</comment>",
      `    <glob pattern="*.${extension}"/>`,
      "  </mime-type>",
      "</mime-info>",
      "",
    ].join("\n"),
  );

  execFileSync("xdg-mime", ["install", "--mode", "user", "--novendor", mimeXmlPath], {
    stdio: "ignore",
  });
  if (hasCommand("update-mime-database")) {
    execFileSync("update-mime-database", [path.join(dataHome, "mime")], { stdio: "ignore" });
  }

  fs.writeFileSync(
    desktopPath,
    [
      "[Desktop Entry]",
      "Type=Application",
      `Name=Suji openPath E2E ${runId}`,
      `Exec=${scriptPath} %u`,
      "NoDisplay=true",
      "Terminal=false",
      `MimeType=${mimeType};`,
      "",
    ].join("\n"),
  );
  if (hasCommand("update-desktop-database")) {
    execFileSync("update-desktop-database", [appsDir], { stdio: "ignore" });
  }
  execFileSync("xdg-mime", ["default", desktopId, mimeType], { stdio: "ignore" });
}

async function waitForMarker(expected: string): Promise<void> {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (fs.existsSync(markerPath)) {
      expect(fs.readFileSync(markerPath, "utf8")).toBe(expected);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`openPath handler marker was not written: ${markerPath}`);
}

beforeAll(async () => {
  if (process.platform === "linux") {
    registerLinuxMimeHandler();
  } else {
    fs.rmSync(baseDir, { recursive: true, force: true });
    fs.mkdirSync(baseDir, { recursive: true });
  }

  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
  fs.rmSync(desktopPath, { force: true });
  fs.rmSync(baseDir, { recursive: true, force: true });
});

describe("shell.openPath runtime APIs", () => {
  test("missing path returns false", async () => {
    const result = await core<{ success: boolean }>({
      cmd: "shell_open_path",
      path: path.join(baseDir, "missing-file.txt"),
    });
    expect(result.success).toBe(false);
  });

  test.skipIf(process.platform !== "linux")(
    "Linux launches registered MIME handler through GIO",
    async () => {
      fs.writeFileSync(targetPath, "open me");
      fs.rmSync(markerPath, { force: true });

      const result = await core<{ success: boolean }>({ cmd: "shell_open_path", path: targetPath });
      expect(result.success).toBe(true);
      await waitForMarker(pathToFileURL(targetPath).href);
    },
  );
});
