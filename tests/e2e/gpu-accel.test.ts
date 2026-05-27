// GPU 가속 검증 E2E (#12 회귀 가드)
//
// 목적: --disable-gpu 스위치 제거 후 CEF 가 GPU 초기화 정상 + WebGL context 획득.
// 검증: WebGL 컨텍스트 생성 가능 + 렌더러 정보 추출(스모크). CI 헤드리스에선
// SwiftShader CPU fallback, 실 GPU 환경에선 하드웨어 (ANGLE D3D11/Metal/...).
// 어느 경우든 컨텍스트 자체는 살아 있어야 GPU 가속 패스가 정상.

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";

let browser: Browser;
let page: Page;

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  // 첫 페이지(메인 창)
  const targets = browser.targets().filter((t) => t.type() === "page");
  if (targets.length === 0) throw new Error("no page target");
  page = (await targets[0].page())!;
});

afterAll(async () => {
  await browser?.disconnect();
});

describe("GPU acceleration (#12)", () => {
  test("WebGL2 컨텍스트 획득 가능 (가속 OR SwiftShader fallback)", async () => {
    const info = await page.evaluate(() => {
      const canvas = document.createElement("canvas");
      const gl = (canvas.getContext("webgl2") ?? canvas.getContext("webgl")) as
        | WebGL2RenderingContext
        | WebGLRenderingContext
        | null;
      if (!gl) return { ok: false, why: "context null" };
      const ext = gl.getExtension("WEBGL_debug_renderer_info");
      const vendor = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
      const renderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
      const version = gl.getParameter(gl.VERSION);
      return { ok: true, vendor: String(vendor ?? ""), renderer: String(renderer ?? ""), version: String(version ?? "") };
    });

    console.log("[GPU] WebGL info:", info);

    expect(info.ok).toBe(true);
    // 어느 백엔드든 vendor/renderer 비어있지 않아야 — 진짜 컨텍스트가 살아있다는 증거
    expect((info as any).renderer.length).toBeGreaterThan(0);
  });

  test("canvas 2D context 도 정상", async () => {
    const ok = await page.evaluate(() => {
      const canvas = document.createElement("canvas");
      const ctx = canvas.getContext("2d");
      if (!ctx) return false;
      canvas.width = 32;
      canvas.height = 32;
      ctx.fillStyle = "rgb(255,0,0)";
      ctx.fillRect(0, 0, 32, 32);
      const pixel = ctx.getImageData(0, 0, 1, 1).data;
      return pixel[0] === 255 && pixel[1] === 0 && pixel[2] === 0;
    });
    expect(ok).toBe(true);
  });
});
