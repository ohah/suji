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

  test("stat: mtime은 ms 단위 (Date.now() 근방, ns 아님)", async () => {
    const file = `${FIXTURE_BASE}/mtime-test.txt`;
    await core({ cmd: "fs_mkdir", path: FIXTURE_BASE, recursive: true });
    const before = Date.now();
    await core({ cmd: "fs_write_file", path: file, text: "x" });
    const after = Date.now();

    const st = await core<{ success: boolean; mtime: number }>({ cmd: "fs_stat", path: file });
    expect(st.success).toBe(true);
    // ms 단위면 Date.now() ± 약간의 오차 안에 들어와야 함.
    // ns 단위였다면 1e6배 큰 값이라 이 범위를 벗어남.
    expect(st.mtime).toBeGreaterThanOrEqual(before - 5000);
    expect(st.mtime).toBeLessThanOrEqual(after + 5000);
    // ns 명시적 차단: 13자리 (현재) ms vs 16자리 ns.
    expect(st.mtime.toString().length).toBeLessThanOrEqual(14);
  });

  test("readdir: directory entry는 type=directory", async () => {
    const root = `${FIXTURE_BASE}/readdir-test`;
    await core({ cmd: "fs_mkdir", path: `${root}/subdir`, recursive: true });
    await core({ cmd: "fs_write_file", path: `${root}/file.txt`, text: "x" });

    const ls = await core<{ success: boolean; entries: Array<{ name: string; type: string }> }>({
      cmd: "fs_readdir",
      path: root,
    });
    expect(ls.success).toBe(true);
    expect(ls.entries).toContainEqual({ name: "subdir", type: "directory" });
    expect(ls.entries).toContainEqual({ name: "file.txt", type: "file" });
  });

  test("rm: nested directory tree 재귀 삭제", async () => {
    const root = `${FIXTURE_BASE}/rm-tree`;
    await core({ cmd: "fs_mkdir", path: `${root}/a/b/c`, recursive: true });
    await core({ cmd: "fs_write_file", path: `${root}/a/file1.txt`, text: "1" });
    await core({ cmd: "fs_write_file", path: `${root}/a/b/file2.txt`, text: "2" });
    await core({ cmd: "fs_write_file", path: `${root}/a/b/c/file3.txt`, text: "3" });

    const rmRes = await core<{ success: boolean }>({
      cmd: "fs_rm",
      path: root,
      recursive: true,
      force: false,
    });
    expect(rmRes.success).toBe(true);

    const st = await core<{ success: boolean; error: string }>({ cmd: "fs_stat", path: root });
    expect(st.success).toBe(false);
  });

  test("rm: recursive=false on non-empty directory returns error (not is_dir or rm)", async () => {
    const dir = `${FIXTURE_BASE}/rm-nonempty`;
    await core({ cmd: "fs_mkdir", path: dir, recursive: true });
    await core({ cmd: "fs_write_file", path: `${dir}/x.txt`, text: "x" });

    const r = await core<{ success: boolean; error: string }>({
      cmd: "fs_rm",
      path: dir,
      recursive: false,
      force: false,
    });
    expect(r.success).toBe(false);
    // deleteFile on directory → IsDir 또는 일반 rm 에러.
    expect(["is_dir", "rm"]).toContain(r.error);

    // cleanup
    await core({ cmd: "fs_rm", path: dir, recursive: true, force: false });
  });

  test("readFile/writeFile unicode (한글 + emoji) round-trip", async () => {
    const file = `${FIXTURE_BASE}/unicode.txt`;
    await core({ cmd: "fs_mkdir", path: FIXTURE_BASE, recursive: true });
    const content = "한글 테스트 🎉 emoji + special \"quote\" \\backslash";

    await core({ cmd: "fs_write_file", path: file, text: content });
    const r = await core<{ success: boolean; text: string }>({ cmd: "fs_read_file", path: file });
    expect(r.success).toBe(true);
    expect(r.text).toBe(content);
  });

  // === Path safety / sandbox 검증 ===
  // 이 example은 suji.json에 `fs.allowedRoots: ["*"]` (escape hatch). 따라서 일반
  // path는 모두 통과. 단 `..` traversal은 모든 mode에 항상 차단 (security-critical).

  test("sandbox: `..` path traversal은 [\"*\"] mode에서도 항상 차단", async () => {
    const r = await core<{ success: boolean; error: string }>({
      cmd: "fs_read_file",
      path: `${FIXTURE_BASE}/../../etc/passwd`,
    });
    expect(r.success).toBe(false);
    expect(r.error).toBe("forbidden");
  });
});
