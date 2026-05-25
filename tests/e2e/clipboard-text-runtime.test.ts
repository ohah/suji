/**
 * Clipboard text/HTML runtime E2E.
 *
 * Linux Actions runs this under Xvfb/GTK. Windows Actions runs it against the
 * Win32 clipboard (CF_UNICODETEXT + CF_HTML).
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

describe("clipboard text/HTML runtime APIs", () => {
  test("writeText/readText/has/availableFormats/clear round-trip", async () => {
    await core({ cmd: "clipboard_clear" });

    const text = "Clipboard runtime text\n한글 🚀 \\ \"";
    const write = await core<{ success: boolean }>({ cmd: "clipboard_write_text", text });
    expect(write.success).toBe(true);

    const read = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(read.text).toBe(text);

    const has = await core<{ present: boolean }>({
      cmd: "clipboard_has",
      format: "public.utf8-plain-text",
    });
    expect(has.present).toBe(true);

    const formats = await core<{ formats: string[] }>({ cmd: "clipboard_available_formats" });
    expect(Array.isArray(formats.formats)).toBe(true);
    expect(formats.formats).toContain("public.utf8-plain-text");

    const clear = await core<{ success: boolean }>({ cmd: "clipboard_clear" });
    expect(clear.success).toBe(true);
    const afterClear = await core<{ text: string }>({ cmd: "clipboard_read_text" });
    expect(afterClear.text).toBe("");
  });

  test("writeHTML/readHTML/has/availableFormats round-trip", async () => {
    await core({ cmd: "clipboard_clear" });

    const html = '<section data-suji="clipboard">Hello <b>HTML</b> 한글 🚀</section>';
    const write = await core<{ success: boolean }>({ cmd: "clipboard_write_html", html });
    expect(write.success).toBe(true);

    const read = await core<{ html: string }>({ cmd: "clipboard_read_html" });
    expect(read.html).toBe(html);

    const has = await core<{ present: boolean }>({
      cmd: "clipboard_has",
      format: "public.html",
    });
    expect(has.present).toBe(true);

    const formats = await core<{ formats: string[] }>({ cmd: "clipboard_available_formats" });
    expect(formats.formats).toContain("public.html");
  });
});
