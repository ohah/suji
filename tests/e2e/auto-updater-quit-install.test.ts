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

async function waitForReplacement(target: string, expected: Buffer, source: string, helper: string) {
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    if (fs.existsSync(target) && fs.readFileSync(target).equals(expected) && !fs.existsSync(source)) {
      expect(fs.existsSync(helper)).toBe(false);
      return;
    }
    await wait(100);
  }
  throw new Error(`quitAndInstall helper did not replace target within timeout: ${target}`);
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
  test("staged artifact replaces target after app quits", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "suji-updater-quit-install-"));
    const source = path.join(dir, "staged.bin");
    const target = path.join(dir, "current.bin");
    const helperPath = `${source}.quit-install.sh`;
    const oldPayload = Buffer.from("old app bytes");
    const newPayload = Buffer.from("new app bytes from quitAndInstall");
    fs.writeFileSync(target, oldPayload);
    fs.writeFileSync(source, newPayload);
    const expected = createHash("sha256").update(newPayload).digest("hex");

    const result = await page.evaluate(async (artifact, options) => {
      return (window as any).__suji_sdk__.autoUpdater.quitAndInstall(artifact, options);
    }, {
      success: true,
      path: source,
      sha256: expected,
      size: newPayload.length,
    }, {
      target,
      relaunch: false,
    }) as {
      success: boolean;
      path: string;
      target: string;
      helperPath: string;
      relaunch: boolean;
    };

    expect(result.success).toBe(true);
    expect(result.path).toBe(source);
    expect(result.target).toBe(target);
    expect(result.helperPath).toBe(helperPath);
    expect(result.relaunch).toBe(false);

    await browser?.disconnect();
    browser = undefined;
    await waitForReplacement(target, newPayload, source, helperPath);
  });
});
