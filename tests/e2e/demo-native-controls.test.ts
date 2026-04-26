/**
 * Demo UI E2E — examples/multi-backend native API controls.
 *
 * 실행:
 *   ./tests/e2e/run-demo-native-controls.sh
 */
import { beforeAll, afterAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

const buttonLabels = [
  "Clipboard write",
  "Clipboard read",
  "Clipboard clear",
  "Beep",
  "Open URL",
  "Show /tmp",
  "MessageBox",
  "ErrorBox",
  "OpenDialog",
  "SaveDialog",
  "Tray event ON",
  "Tray create",
  "Tray menu",
  "Tray destroy",
  "Notification event ON",
  "Notification supported",
  "Notification permission",
  "Notification show",
  "Menu event ON",
  "Set app menu",
  "Reset app menu",
  "FS round-trip",
  "FS missing file",
  "Frameless 창 열기",
];

async function clickButton(label: string) {
  const clicked = await page.evaluate((text) => {
    const buttons = Array.from(document.querySelectorAll("button"));
    const button = buttons.find((b) => b.textContent?.trim() === text);
    if (!button) return false;
    (button as HTMLButtonElement).click();
    return true;
  }, label);
  expect(clicked).toBe(true);
}

async function waitForLog(fragment: string) {
  await page.waitForFunction(
    (text) => document.body.textContent?.includes(text),
    { timeout: 15000 },
    fragment,
  );
}

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  const pages = await browser.pages();
  expect(pages.length).toBeGreaterThan(0);
  page = pages[0];
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("multi-backend demo native controls", () => {
  test("renders every manual native API control", async () => {
    const text = await page.evaluate(() => document.body.textContent ?? "");
    for (const label of buttonLabels) {
      expect(text).toContain(label);
    }
  });

  test("safe controls are wired to core and produce output", async () => {
    await clickButton("FS round-trip");
    await waitForLog("[fs-roundtrip]");
    await waitForLog('"success":true');

    await clickButton("FS missing file");
    await waitForLog("[fs-missing]");
    await waitForLog('"success":false');

    await clickButton("Notification supported");
    await waitForLog("[notification-supported]");

    await clickButton("Menu event ON");
    await waitForLog("menu:click listener ON");

    await clickButton("Tray event ON");
    await waitForLog("tray:menu-click listener ON");
  });

  test("drag region CSS is present in computed styles", async () => {
    const region = await page.$(".drag-demo");
    expect(region).not.toBeNull();
    const drag = await page.evaluate((el) => getComputedStyle(el as Element).getPropertyValue("-webkit-app-region"), region);
    expect(drag).toBe("drag");
  });
});
