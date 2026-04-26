/**
 * File system E2E — `fs_*` core commands.
 *
 * 실행:
 *   ./tests/e2e/run-fs.sh
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

const FIXTURE_BASE = `/tmp/suji-fs-e2e-${process.pid}`;
const FIXTURE_DIR = `${FIXTURE_BASE}/nested`;
const FIXTURE_FILE = `${FIXTURE_DIR}/한글 file.txt`;

async function shellRun(cmd: string, args: string[]): Promise<{ exitCode: number }> {
  const proc = Bun.spawn([cmd, ...args]);
  await proc.exited;
  return { exitCode: proc.exitCode ?? 0 };
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

  await shellRun("rm", ["-rf", FIXTURE_BASE]);
});

afterAll(async () => {
  await shellRun("rm", ["-rf", FIXTURE_BASE]);
  await browser?.disconnect();
});

describe("fs core commands", () => {
  test("mkdir/write/read/stat/readdir round-trip", async () => {
    const mk = await core<{ success: boolean }>({ cmd: "fs_mkdir", path: FIXTURE_DIR, recursive: true });
    expect(mk.success).toBe(true);

    const wr = await core<{ success: boolean }>({
      cmd: "fs_write_file",
      path: FIXTURE_FILE,
      text: "hello\n한글",
    });
    expect(wr.success).toBe(true);

    const rd = await core<{ success: boolean; text: string }>({ cmd: "fs_read_file", path: FIXTURE_FILE });
    expect(rd.success).toBe(true);
    expect(rd.text).toBe("hello\n한글");

    const st = await core<{ success: boolean; type: string; size: number; mtime: number }>({
      cmd: "fs_stat",
      path: FIXTURE_FILE,
    });
    expect(st.success).toBe(true);
    expect(st.type).toBe("file");
    expect(st.size).toBeGreaterThan(0);
    expect(st.mtime).toBeGreaterThan(0);

    const ls = await core<{ success: boolean; entries: Array<{ name: string; type: string }> }>({
      cmd: "fs_readdir",
      path: FIXTURE_DIR,
    });
    expect(ls.success).toBe(true);
    expect(ls.entries).toContainEqual({ name: "한글 file.txt", type: "file" });
  });

  test("invalid path returns structured error", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "fs_read_file",
      path: `${FIXTURE_BASE}/missing.txt`,
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("read");
  });

  test("empty path is rejected", async () => {
    const r = await core<{ success: boolean; error: string }>({ cmd: "fs_stat", path: "" });
    expect(r.success).toBe(false);
    expect(r.error).toBe("path");
  });
});
