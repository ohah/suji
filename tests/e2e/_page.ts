import type { Browser, Page } from "puppeteer-core";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
let coreSeq = 0;

function isMainAppUrl(url: string): boolean {
  return url.startsWith("http://localhost:5173") || url.startsWith("http://127.0.0.1:5173");
}

async function hasSujiBridge(page: Page): Promise<boolean> {
  try {
    return await page.evaluate(() => Boolean((globalThis as any).__suji__?.core));
  } catch {
    return false;
  }
}

async function waitForStableSujiBridge(page: Page, timeoutMs = 10000, stableMs = 2000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  let stableSince = 0;
  while (Date.now() < deadline) {
    const ready = await page.evaluate(() => {
      return Boolean((globalThis as any).__suji__?.core) && document.readyState === "complete";
    }).catch(() => false);

    if (ready) {
      stableSince ||= Date.now();
      if (Date.now() - stableSince >= stableMs) return true;
    } else {
      stableSince = 0;
    }
    await wait(100);
  }
  return false;
}

export async function getMainPage(browser: Browser, timeoutMs = 30000): Promise<Page> {
  const deadline = Date.now() + timeoutMs;
  let lastUrls = "";
  while (Date.now() < deadline) {
    const pages = await browser.pages();
    const appPages = pages.filter((p) => isMainAppUrl(p.url()));
    for (const page of appPages) {
      if ((await hasSujiBridge(page)) && (await waitForStableSujiBridge(page))) return page;
    }

    lastUrls = pages.map((p) => p.url() || "<empty>").join(", ");
    await wait(100);
  }
  throw new Error(`main window not found in puppeteer pages; last urls: ${lastUrls || "<none>"}`);
}

export async function callCore<T = any>(
  page: Page,
  request: Record<string, unknown>,
  timeoutMs = 30000,
): Promise<T> {
  const slot = `__suji_e2e_core_${process.pid}_${Date.now()}_${++coreSeq}`;
  await page.evaluate(
    (key, reqJson) => {
      const w = window as any;
      w[key] = { done: false };
      try {
        Promise.resolve(w.__suji__.core(reqJson)).then(
          (value) => {
            w[key] = { done: true, value };
          },
          (error) => {
            w[key] = {
              done: true,
              error: String(error?.stack || error?.message || error),
            };
          },
        );
      } catch (error) {
        w[key] = {
          done: true,
          error: String(error?.stack || error?.message || error),
        };
      }
    },
    slot,
    JSON.stringify(request),
  );

  let result: { value?: T; error?: string } | null = null;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    result = await page.evaluate((key) => {
      const value = (window as any)[key];
      return value?.done ? value : null;
    }, slot).catch(() => null) as { value?: T; error?: string } | null;
    if (result) break;
    await wait(50);
  }

  if (!result) {
    const debug = await page.evaluate((key) => {
      const w = window as any;
      const s = w.__suji__ || {};
      return {
        url: location.href,
        slot: w[key] || null,
        pending: Object.keys(s._pending || {}),
        early: Object.keys(s._early || {}),
      };
    }, slot).catch((error) => ({ error: String(error?.message || error) }));
    await page.evaluate((key) => {
      delete (window as any)[key];
    }, slot).catch(() => {});
    throw new Error(`core timeout cmd=${String(request.cmd || "<unknown>")} debug=${JSON.stringify(debug)}`);
  }

  await page.evaluate((key) => {
    delete (window as any)[key];
  }, slot).catch(() => {});

  if (result?.error) throw new Error(result.error);
  return result?.value as T;
}
