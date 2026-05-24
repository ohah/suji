import type { Browser, Page } from "puppeteer-core";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

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
