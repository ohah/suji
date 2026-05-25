/**
 * Frameless drag-region E2E.
 *
 * Verifies the CEF Views path keeps draggable titlebar regions native while
 * preserving `no-drag` controls inside the titlebar.
 */
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page, type Target, type CDPSession } from "puppeteer-core";
import { readFileSync } from "node:fs";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;

type CoreResponse = {
  from?: string;
  cmd: string;
  windowId?: number;
  success?: boolean;
};

const coreCall = <T extends CoreResponse = CoreResponse>(request: object): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request,
  ) as Promise<T>;

async function waitForNewPageTarget(excluded: Set<Target>, timeoutMs = 5000): Promise<Target> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const cand = browser.targets().find((t) => t.type() === "page" && !excluded.has(t));
    if (cand) return cand;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`new page target not discovered within ${timeoutMs}ms`);
}

async function elementCenter(session: CDPSession, selector: string): Promise<{ x: number; y: number }> {
  const result = await session.send("Runtime.evaluate", {
    expression: `JSON.stringify(document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect())`,
    returnByValue: true,
  });
  const rect = JSON.parse(result.result.value as string);
  return {
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
  };
}

async function clickAt(session: CDPSession, x: number, y: number): Promise<void> {
  await session.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
  await session.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
  await session.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
}

async function waitForLogIncludesAfter(path: string, offset: number, needle: string, timeoutMs = 5000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const log = readFileSync(path, "utf8").slice(offset);
    if (log.includes(needle)) return log;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return readFileSync(path, "utf8").slice(offset);
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

describe("CEF Views frameless drag region", () => {
  test("native drag regions are applied and no-drag controls remain clickable", async () => {
    const logPath = process.env.SUJI_LOG;
    expect(logPath).toBeTruthy();
    expect(readFileSync(logPath!, "utf8")).toContain("CEF Views path enabled");
    const logOffset = readFileSync(logPath!, "utf8").length;

    const html = `<!doctype html>
      <meta charset="utf-8" />
      <style>
        body { margin: 0; font-family: system-ui, sans-serif; }
        .drag {
          height: 64px;
          display: flex;
          align-items: center;
          gap: 12px;
          padding: 8px 12px;
          background: #1f2937;
          -webkit-app-region: drag;
          app-region: drag;
        }
        #drag-hotspot {
          width: 96px;
          height: 40px;
          background: #60a5fa;
          -webkit-app-region: drag;
          app-region: drag;
        }
        #probe {
          width: 96px;
          height: 40px;
          -webkit-app-region: no-drag;
          app-region: no-drag;
        }
      </style>
      <div class="drag">
        <div id="drag-hotspot" onclick="document.body.dataset.dragClicked='yes'"></div>
        <button id="probe" onclick="document.body.dataset.buttonClicked='yes'">probe</button>
      </div>`;

    const excluded = new Set<Target>(browser.targets().filter((t) => t.type() === "page"));
    const created = await coreCall({
      cmd: "create_window",
      title: "frameless-drag-region-e2e",
      url: "about:blank",
      width: 420,
      height: 180,
      frame: false,
    });
    expect(created.windowId).toBeGreaterThan(0);

    const target = await waitForNewPageTarget(excluded);
    const session = await target.createCDPSession();

    try {
      await session.send("Runtime.evaluate", {
        expression: `document.open();document.write(${JSON.stringify(html)});document.close();`,
        awaitPromise: true,
      });
      await session.send("Runtime.evaluate", {
        expression: "new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
        awaitPromise: true,
      });
      const log = await waitForLogIncludesAfter(logPath!, logOffset, "[suji:drag-region]", 5000);
      expect(log).toContain("views_window=true");
      expect(log).toContain("applied_to_cef_views=true");

      const buttonPoint = await elementCenter(session, "#probe");
      await clickAt(session, buttonPoint.x, buttonPoint.y);
      const buttonClicked = await session.send("Runtime.evaluate", {
        expression: "document.body.dataset.buttonClicked ?? ''",
        returnByValue: true,
      });
      expect(buttonClicked.result.value).toBe("yes");
    } finally {
      await session.detach().catch(() => {});
      if (created.windowId) {
        await coreCall({ cmd: "destroy_window", windowId: created.windowId }).catch(() => undefined);
      }
    }
  });
});
