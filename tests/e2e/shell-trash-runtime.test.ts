/**
 * Shell trash runtime E2E.
 *
 * Linux Actions runs this under Xvfb/dbus and verifies GIO `g_file_trash`
 * changes filesystem state instead of returning the old stub response.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;
const baseDir = path.join(os.homedir(), `.suji-shell-trash-e2e-${process.pid}-${Date.now()}`);

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

beforeAll(async () => {
  fs.rmSync(baseDir, { recursive: true, force: true });
  fs.mkdirSync(baseDir, { recursive: true });

  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  fs.rmSync(baseDir, { recursive: true, force: true });
  await browser?.disconnect();
});

describe("shell.trashItem runtime APIs", () => {
  test("existing file moves to Trash and disappears from original path", async () => {
    const target = path.join(baseDir, "file with spaces 한글.txt");
    fs.writeFileSync(target, "trash me");
    expect(fs.existsSync(target)).toBe(true);

    const result = await core<{ success: boolean }>({ cmd: "shell_trash_item", path: target });
    expect(result.success).toBe(true);
    expect(fs.existsSync(target)).toBe(false);
  });

  test("missing path returns false", async () => {
    const missing = path.join(baseDir, "missing.txt");
    fs.rmSync(missing, { force: true });

    const result = await core<{ success: boolean }>({ cmd: "shell_trash_item", path: missing });
    expect(result.success).toBe(false);
  });
});
