/**
 * autoUpdater quitAndInstall E2E.
 *
 * This intentionally exits the running Suji app, so keep it in its own runner.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser | undefined;
let page: Page;

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function run(cmd: string, args: string[], cwd?: string) {
  const proc = Bun.spawn([cmd, ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) {
    throw new Error(`${cmd} ${args.join(" ")} failed (${code})\n${stdout}\n${stderr}`);
  }
}

async function waitForReplacement(verifyPath: string, expected: Buffer, source: string, helper: string) {
  const deadline = Date.now() + 12000;
  let replaced = false;
  while (Date.now() < deadline) {
    replaced = fs.existsSync(verifyPath) && fs.readFileSync(verifyPath).equals(expected) && !fs.existsSync(source);
    if (replaced && !fs.existsSync(helper)) {
      return;
    }
    await wait(100);
  }
  if (replaced) {
    throw new Error(`quitAndInstall helper replaced target but did not clean up: ${helper}`);
  }
  throw new Error(`quitAndInstall helper did not replace target within timeout: ${verifyPath}`);
}

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(30000);

  const sdkSrc = fs.readFileSync(
    path.resolve(__dirname, "../../packages/suji-js/dist/index.js"),
    "utf-8",
  );
  await page.evaluate(async (code) => {
    const blob = new Blob([code], { type: "text/javascript" });
    const url = URL.createObjectURL(blob);
    try {
      const m = await import(/* @vite-ignore */ url);
      (window as any).__suji_sdk__ = m;
    } finally {
      URL.revokeObjectURL(url);
    }
  }, sdkSrc);
});

afterAll(async () => {
  try {
    await browser?.disconnect();
  } catch {}
});

describe.skipIf(process.platform === "win32")("autoUpdater.quitAndInstall", () => {
  test("prepared artifact replaces target after app quits", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-updater-quit-install-"));
    const stageDir = path.join(dir, "stage");
    const oldPayload = Buffer.from("old app bytes");
    const newPayload = Buffer.from("new app bytes from prepared quitAndInstall");

    let artifact: string;
    let target: string;
    let verifyPath: string;
    let format: "zip" | "appimage";

    if (process.platform === "darwin") {
      const stagedApp = path.join(dir, "Staged Suji.app");
      const targetApp = path.join(dir, "Current Suji.app");
      fs.mkdirSync(path.join(stagedApp, "Contents"), { recursive: true });
      fs.mkdirSync(path.join(targetApp, "Contents"), { recursive: true });
      fs.writeFileSync(path.join(stagedApp, "Contents", "payload.txt"), newPayload);
      fs.writeFileSync(path.join(targetApp, "Contents", "payload.txt"), oldPayload);
      artifact = path.join(dir, "staged.zip");
      target = targetApp;
      verifyPath = path.join(targetApp, "Contents", "payload.txt");
      format = "zip";
      await run("ditto", ["-c", "-k", "--keepParent", stagedApp, artifact]);
    } else {
      artifact = path.join(dir, "staged.AppImage");
      target = path.join(dir, "current.AppImage");
      verifyPath = target;
      format = "appimage";
      fs.writeFileSync(artifact, newPayload, { mode: 0o644 });
      fs.writeFileSync(target, oldPayload, { mode: 0o755 });
    }

    const artifactBytes = fs.readFileSync(artifact);
    const expected = createHash("sha256").update(artifactBytes).digest("hex");

    const prepared = await page.evaluate(async (artifactInfo, options) => {
      return (window as any).__suji_sdk__.autoUpdater.prepareInstall(artifactInfo, options);
    }, {
      success: true,
      path: artifact,
      sha256: expected,
      size: artifactBytes.length,
    }, {
      target,
      stageDir,
      format,
    }) as {
      success: boolean;
      path: string;
      source: string;
      target: string;
      stageDir: string;
      format: string;
      action: string;
      requiresQuitAndInstall: boolean;
    };

    expect(prepared.success).toBe(true);
    expect(prepared.target).toBe(target);
    expect(prepared.stageDir).toBe(stageDir);
    expect(prepared.action).toBe("quitAndInstall");
    expect(prepared.requiresQuitAndInstall).toBe(true);
    expect(fs.existsSync(prepared.path)).toBe(true);

    const result = await page.evaluate(async (preparedInfo, options) => {
      return (window as any).__suji_sdk__.autoUpdater.quitAndInstall(preparedInfo, options);
    }, prepared, {
      relaunch: false,
    }) as {
      success: boolean;
      path: string;
      target: string;
      helperPath: string;
      relaunch: boolean;
    };

    expect(result.success).toBe(true);
    expect(result.path).toBe(prepared.path);
    expect(result.target).toBe(target);
    expect(result.relaunch).toBe(false);

    await browser?.disconnect();
    browser = undefined;
    await waitForReplacement(verifyPath, newPayload, prepared.path, result.helperPath);
  });
});
