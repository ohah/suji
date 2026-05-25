/**
 * printToPDF E2E — CEF callback completion + real PDF file output.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, readFileSync, statSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: object): Promise<T> =>
  page.evaluate((req) => (window as any).__suji__.core(JSON.stringify(req)), request) as Promise<T>;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(10000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("print_to_pdf", () => {
  test("writes a real PDF and emits completion for the requested path", async () => {
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "print-to-pdf-e2e",
      url: "about:blank",
    });
    const pdfPath = join(tmpdir(), `suji-print-to-pdf-${randomUUID()}.pdf`);

    const finished = page.evaluate((path) =>
      new Promise<{ path?: string; success?: boolean }>((resolve) => {
        const off = (window as any).__suji__.on("window:pdf-print-finished", (data: any) => {
          if (data.path === path) {
            off();
            resolve({ path: data.path, success: data.success });
          }
        });
      }), pdfPath) as Promise<{ path?: string; success?: boolean }>;

    try {
      const ack = await core<{ from: string; cmd: string; windowId: number; ok: boolean }>({
        cmd: "print_to_pdf",
        windowId: created.windowId,
        path: pdfPath,
      });
      expect(ack).toEqual({ from: "zig-core", cmd: "print_to_pdf", windowId: created.windowId, ok: true });

      const result = await Promise.race([
        finished,
        new Promise<{ path?: string; success?: boolean }>((resolve) =>
          setTimeout(() => resolve({ path: undefined, success: undefined }), 15000),
        ),
      ]);
      expect(result).toEqual({ path: pdfPath, success: true });
      expect(existsSync(pdfPath)).toBe(true);
      expect(statSync(pdfPath).size).toBeGreaterThan(4);
      expect(readFileSync(pdfPath).subarray(0, 5).toString("ascii")).toBe("%PDF-");
    } finally {
      await core({ cmd: "destroy_window", windowId: created.windowId }).catch(() => undefined);
      if (existsSync(pdfPath)) unlinkSync(pdfPath);
    }
  });
});
