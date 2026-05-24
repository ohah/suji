import type { Browser, Page } from "puppeteer-core";

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export async function getMainPage(browser: Browser, timeoutMs = 10000): Promise<Page> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pages = await browser.pages();
    const main = pages.find((p) => p.url().startsWith("http://localhost"));
    if (main) return main;
    await wait(100);
  }
  throw new Error("main window (localhost) not found in puppeteer pages");
}
