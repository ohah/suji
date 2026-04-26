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

const cleanupFixture = () =>
  core({ cmd: "fs_rm", path: FIXTURE_BASE, recursive: true, force: true });

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

  await cleanupFixture();
});

afterAll(async () => {
  await cleanupFixture();
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

  test("rm: file removal + recursive tree + force not-found", async () => {
    const target_dir = `${FIXTURE_BASE}/rm-test`;
    const target_file = `${target_dir}/x.txt`;
    await core({ cmd: "fs_mkdir", path: target_dir, recursive: true });
    await core({ cmd: "fs_write_file", path: target_file, text: "x" });

    const rm_file = await core<{ success: boolean }>({ cmd: "fs_rm", path: target_file, recursive: false, force: false });
    expect(rm_file.success).toBe(true);

    const rm_missing_strict = await core<{ success: boolean; error: string }>({
      cmd: "fs_rm",
      path: target_file,
      recursive: false,
      force: false,
    });
    expect(rm_missing_strict.success).toBe(false);
    expect(rm_missing_strict.error).toBe("not_found");

    const rm_missing_force = await core<{ success: boolean }>({
      cmd: "fs_rm",
      path: target_file,
      recursive: false,
      force: true,
    });
    expect(rm_missing_force.success).toBe(true);

    const rm_tree = await core<{ success: boolean }>({ cmd: "fs_rm", path: target_dir, recursive: true, force: false });
    expect(rm_tree.success).toBe(true);

    const st = await core<{ success: boolean; error: string }>({ cmd: "fs_stat", path: target_dir });
    expect(st.success).toBe(false);
  });

  test("mkdir non-recursive on existing returns exists error", async () => {
    const dir = `${FIXTURE_BASE}/mkdir-test`;
    await core({ cmd: "fs_mkdir", path: dir, recursive: true });

    const dup = await core<{ success: boolean; error: string }>({ cmd: "fs_mkdir", path: dir, recursive: false });
    expect(dup.success).toBe(false);
    expect(dup.error).toBe("exists");

    // recursive=true는 idempotent
    const idem = await core<{ success: boolean }>({ cmd: "fs_mkdir", path: dir, recursive: true });
    expect(idem.success).toBe(true);
  });
});
