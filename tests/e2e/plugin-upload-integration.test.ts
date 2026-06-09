/**
 * 공식 upload 플러그인 통합 e2e (실 HTTP 서버 + 실 디스크 파일).
 *
 * 검증 범위:
 *   1. renderer __suji__.invoke('upload:upload') → 플러그인이 디스크 파일을 읽어
 *      multipart/form-data 로 실 서버에 POST → 서버가 받은 바이트/내용 일치
 *   2. 'upload:download' → 실 서버 GET → 디스크 파일로 저장 → 내용 일치
 *   3. URL/PATH allowlist deny-by-default (allowlist 밖 → forbidden)
 *   4. upload:progress 완료 이벤트 발화
 *
 * Wrapper wire shape 은 `bun test plugins/upload/{js,node}/src` 가 별도 검증.
 * 이 파일은 REAL plugin DLL ↔ std.http ↔ 파일 I/O 통합만 검사(unit 은 network 없이
 * allowlist/SSRF/traversal 표면만 커버).
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let browser: Browser;
let page: Page;
let server: ReturnType<typeof Bun.serve>;
let port = 0;
let lastUpload: { bytes: number; name: string | null; content: string } | null = null;

let tmpDir = "";
let srcFile = "";
let dlFile = "";
const SRC_CONTENT = "SUJI-UPLOAD-PAYLOAD-" + "x".repeat(500);
const DL_CONTENT = "SUJI-DOWNLOAD-BODY-" + "y".repeat(300);

const inv = <T = any>(channel: string, payload?: unknown): Promise<T> =>
  page.evaluate(
    (r) => (window as unknown as { __suji__: { invoke: (c: string, d?: unknown) => unknown } }).__suji__
      .invoke(r.channel as string, r.payload as unknown),
    { channel, payload },
  ) as Promise<T>;

beforeAll(async () => {
  tmpDir = mkdtempSync(join(tmpdir(), "suji-upload-"));
  srcFile = join(tmpDir, "src.bin");
  dlFile = join(tmpDir, "out.bin");
  writeFileSync(srcFile, SRC_CONTENT);

  server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/upload" && req.method === "POST") {
        const fd = await req.formData();
        const f = fd.get("file") as File | null;
        const buf = f ? await f.arrayBuffer() : new ArrayBuffer(0);
        lastUpload = { bytes: buf.byteLength, name: f?.name ?? null, content: Buffer.from(buf).toString() };
        return new Response(JSON.stringify({ ok: true, received: buf.byteLength }), { status: 200 });
      }
      if (url.pathname === "/file" && req.method === "GET") {
        return new Response(DL_CONTENT, { status: 200 });
      }
      return new Response("not found", { status: 404 });
    },
  });
  port = server.port;

  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(15000);
  await page.waitForFunction(() => typeof (window as any).__suji__ !== "undefined", { timeout: 10000 });

  // allowlist 설정 + progress 수집기 등록.
  await inv("upload:set_allowed_urls", { urls: [`http://localhost:${port}/*`] });
  await inv("upload:set_allowed_paths", { paths: [tmpDir] });
  await page.evaluate(() => {
    (window as any).__up_progress = [];
    (window as unknown as { __suji__: { on: (e: string, cb: (d: unknown) => void) => unknown } }).__suji__
      .on("upload:progress", (d) => (window as any).__up_progress.push(d));
  });
});

afterAll(async () => {
  try {
    server?.stop(true);
  } catch {}
  try {
    rmSync(tmpDir, { recursive: true, force: true });
  } catch {}
  await browser?.disconnect();
});

describe("upload plugin: live HTTP + disk round-trip", () => {
  test("upload sends the disk file as multipart; server receives exact bytes", async () => {
    const r = await inv<{ result?: { status?: number; body?: string }; error?: string }>("upload:upload", {
      url: `http://localhost:${port}/upload`,
      filePath: srcFile,
      fieldName: "file",
      fileName: "src.bin",
      contentType: "application/octet-stream",
      id: "j1",
    });
    expect(r?.error).toBeUndefined();
    expect(r?.result?.status).toBe(200);
    expect(lastUpload).not.toBeNull();
    expect(lastUpload!.bytes).toBe(SRC_CONTENT.length);
    expect(lastUpload!.content).toBe(SRC_CONTENT);
    expect(lastUpload!.name).toBe("src.bin");
  });

  test("upload:progress completion event fired", async () => {
    // 이벤트는 invoke 응답 직전 발화 — 짧게 폴링.
    let events: any[] = [];
    for (let i = 0; i < 20; i++) {
      events = await page.evaluate(() => (window as any).__up_progress ?? []);
      if (events.length > 0) break;
      await new Promise((res) => setTimeout(res, 100));
    }
    const j1 = events.find((e) => e?.id === "j1");
    expect(j1).toBeDefined();
    expect(j1.done).toBe(true);
    expect(j1.total).toBe(SRC_CONTENT.length);
  });

  test("download writes server body to disk", async () => {
    const r = await inv<{ result?: { status?: number; bytes?: number }; error?: string }>("upload:download", {
      url: `http://localhost:${port}/file`,
      filePath: dlFile,
      id: "j2",
    });
    expect(r?.error).toBeUndefined();
    expect(r?.result?.status).toBe(200);
    expect(r?.result?.bytes).toBe(DL_CONTENT.length);
    expect(existsSync(dlFile)).toBe(true);
    expect(readFileSync(dlFile, "utf8")).toBe(DL_CONTENT);
  });

  test("allowlist deny — url outside allowlist is forbidden", async () => {
    const r = await inv<{ result?: unknown; error?: string }>("upload:download", {
      url: "http://evil.example/x",
      filePath: dlFile,
    });
    expect(JSON.stringify(r)).toContain("forbidden url");
  });

  test("allowlist deny — path outside allowlist is forbidden", async () => {
    const r = await inv<{ result?: unknown; error?: string }>("upload:download", {
      url: `http://localhost:${port}/file`,
      filePath: "/etc/suji-should-not-write",
    });
    expect(JSON.stringify(r)).toContain("forbidden path");
  });
});
