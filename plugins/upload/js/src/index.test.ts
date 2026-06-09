import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
  on: mock((_event: string, _cb: (d: unknown) => void) => () => {}),
};

(globalThis as any).window = { __suji__: mockBridge };

const { upload } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
  mockBridge.on.mockClear();
});

describe("upload.upload wire", () => {
  it("url + filePath + opts pass through", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { status: 200, body: "ok" } });
    const r = await upload.upload("https://x/u", "~/a.png", {
      fieldName: "f",
      fileName: "a.png",
      contentType: "image/png",
      id: "j1",
    });
    expect(mockBridge.invoke).toHaveBeenCalledWith("upload:upload", {
      url: "https://x/u",
      filePath: "~/a.png",
      fieldName: "f",
      fileName: "a.png",
      contentType: "image/png",
      id: "j1",
    });
    expect(r).toEqual({ status: 200, body: "ok" });
  });

  it("omits undefined opts", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { status: 201, body: "" } });
    await upload.upload("https://x/u", "/tmp/a");
    expect(mockBridge.invoke).toHaveBeenCalledWith("upload:upload", { url: "https://x/u", filePath: "/tmp/a" });
  });
});

describe("upload.download wire", () => {
  it("returns status + bytes", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { status: 200, bytes: 4096 } });
    const r = await upload.download("https://x/f", "/tmp/out", { id: "j2" });
    expect(mockBridge.invoke).toHaveBeenCalledWith("upload:download", { url: "https://x/f", filePath: "/tmp/out", id: "j2" });
    expect(r).toEqual({ status: 200, bytes: 4096 });
  });
});

describe("allowlists", () => {
  it("setAllowedUrls / getAllowedUrls", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await upload.setAllowedUrls(["https://x/*"]);
    expect(mockBridge.invoke).toHaveBeenCalledWith("upload:set_allowed_urls", { urls: ["https://x/*"] });

    mockBridge.invoke.mockResolvedValueOnce({ result: { urls: ["https://x/*"] } });
    expect(await upload.getAllowedUrls()).toEqual(["https://x/*"]);
  });

  it("setAllowedPaths / getAllowedPaths", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await upload.setAllowedPaths(["~/Documents"]);
    expect(mockBridge.invoke).toHaveBeenCalledWith("upload:set_allowed_paths", { paths: ["~/Documents"] });

    mockBridge.invoke.mockResolvedValueOnce({ result: { paths: ["~/Documents"] } });
    expect(await upload.getAllowedPaths()).toEqual(["~/Documents"]);
  });
});

describe("onProgress", () => {
  it("subscribes to upload:progress and forwards payload", () => {
    let received: any = null;
    const unsub = upload.onProgress((p) => {
      received = p;
    });
    expect(mockBridge.on).toHaveBeenCalledWith("upload:progress", expect.any(Function));
    // 브리지가 호출하는 콜백을 직접 실행해 forward 확인.
    const cb = mockBridge.on.mock.calls.at(-1)![1] as (d: unknown) => void;
    cb({ id: "j1", uploaded: 10, total: 10, done: true });
    expect(received).toEqual({ id: "j1", uploaded: 10, total: 10, done: true });
    expect(typeof unsub).toBe("function");
  });
});

describe("error propagation", () => {
  it("throws on bridge error", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "forbidden url" });
    await expect(upload.upload("https://x/u", "/tmp/a")).rejects.toThrow("upload: forbidden url");
  });
});
