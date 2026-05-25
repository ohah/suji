/**
 * Shell beep runtime E2E.
 *
 * Linux Actions runs this under Xvfb and verifies the GDK beep path is callable
 * repeatedly without failing the shell IPC response.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

beforeAll(async () => {
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
});

describe("shell.beep runtime APIs", () => {
  test("single beep returns success", async () => {
    const result = await core<{ success: boolean }>({ cmd: "shell_beep" });
    expect(result.success).toBe(true);
  });

  test("repeated beep calls do not break IPC", async () => {
    for (let i = 0; i < 50; i++) {
      const result = await core<{ success: boolean }>({ cmd: "shell_beep" });
      expect(result.success).toBe(true);
    }
  });
});
