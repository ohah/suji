import type { Browser, Page } from "puppeteer-core";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
let coreSeq = 0;

async function hasSujiBridge(page: Page): Promise<boolean> {
  try {
    return await page.evaluate(() => Boolean((globalThis as any).__suji__?.core));
  } catch {
    return false;
  }
}

export async function getMainPage(browser: Browser, timeoutMs = 10000): Promise<Page> {
  const deadline = Date.now() + timeoutMs;
  let lastUrls = "";
  while (Date.now() < deadline) {
    const pages = await browser.pages();
    const main = pages.find((p) => p.url().startsWith("http://localhost"));
    if (main) return main;

    for (const page of pages) {
      if (await hasSujiBridge(page)) return page;
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
      window.setTimeout(() => {
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
      }, 0);
    },
    slot,
    JSON.stringify(request),
  );

  await page.waitForFunction(
    (key) => Boolean((window as any)[key]?.done),
    { timeout: timeoutMs },
    slot,
  );

  const result = await page.evaluate((key) => {
    const w = window as any;
    const value = w[key];
    delete w[key];
    return value;
  }, slot) as { value?: T; error?: string };

  if (result?.error) throw new Error(result.error);
  return result?.value as T;
}
