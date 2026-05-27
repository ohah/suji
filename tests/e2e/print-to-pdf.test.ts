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

async function startCollect<T = any>(channel: string): Promise<{ stop: (timeoutMs: number) => Promise<T[]> }> {
  const id = await page.evaluate((ch: string) => {
    const events: any[] = [];
    const off = (window as any).__suji__.on(ch, (payload: string) => {
      try {
        events.push(JSON.parse(payload));
      } catch {
        events.push(payload);
      }
    });
    const registry = ((window as any).__printToPdfE2E ||= {});
    const key = String(Math.random());
    registry[key] = { events, off };
    return key;
  }, channel);

  return {
    stop: (timeoutMs: number) =>
      page.evaluate(async ({ key, timeoutMs }: { key: string; timeoutMs: number }) => {
        await new Promise((resolve) => setTimeout(resolve, timeoutMs));
        const registry = (window as any).__printToPdfE2E;
        const collected = registry[key];
        collected.off();
        const events = collected.events;
        delete registry[key];
        return events;
      }, { key: id, timeoutMs }),
  };
}

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
    const ready = await startCollect<{ windowId: number }>("window:ready-to-show");
    const created = await core<{ windowId: number }>({
      cmd: "create_window",
      title: "print-to-pdf-e2e",
      url: "about:blank",
    });
    const pdfPath = join(tmpdir(), `suji-print-to-pdf-${randomUUID()}.pdf`);
    const readyEvents = (await ready.stop(5000)).filter((event) => event.windowId === created.windowId);
    expect(readyEvents.length).toBeGreaterThan(0);
    await new Promise((resolve) => setTimeout(resolve, 500));

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
      const ack = await core<{ from: string; cmd: string; ok: boolean; path?: string; success?: boolean }>({
        cmd: "print_to_pdf",
        windowId: created.windowId,
        path: pdfPath,
      });
      expect(ack).toEqual({ from: "zig-core", cmd: "print_to_pdf", ok: true, path: pdfPath, success: true });

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
