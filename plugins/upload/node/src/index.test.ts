import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve('{"result":{}}')),
  on: mock((_ch: string, _fn: (c: string, d: string) => void) => 7),
  off: mock((_id: number) => {}),
};

(globalThis as any).suji = mockBridge;

const { upload } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
  mockBridge.on.mockClear();
  mockBridge.off.mockClear();
});

function lastCall(): { backend: string; payload: Record<string, unknown> } {
  const args = mockBridge.invoke.mock.calls.at(-1)!;
  return { backend: args[0] as string, payload: JSON.parse(args[1] as string) };
}

describe("upload Node — routing + wire", () => {
  it("upload routes to 'upload' backend with cmd", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"status":200,"body":"ok"}}');
    const r = await upload.upload("https://x/u", "/srv/a.png", { contentType: "image/png", id: "j1" });
    const { backend, payload } = lastCall();
    expect(backend).toBe("upload");
    expect(payload).toEqual({ cmd: "upload:upload", url: "https://x/u", filePath: "/srv/a.png", contentType: "image/png", id: "j1" });
    expect(r).toEqual({ status: 200, body: "ok" });
  });

  it("download returns status + bytes", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"status":200,"bytes":2048}}');
    const r = await upload.download("https://x/f", "/srv/out");
    expect(lastCall().payload).toEqual({ cmd: "upload:download", url: "https://x/f", filePath: "/srv/out" });
    expect(r).toEqual({ status: 200, bytes: 2048 });
  });

  it("allowlist setters route", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await upload.setAllowedPaths(["/srv/data"]);
    expect(lastCall().payload).toEqual({ cmd: "upload:set_allowed_paths", paths: ["/srv/data"] });
  });
});

describe("onProgress (node bridge on/off)", () => {
  it("subscribes, parses raw, returns off()", () => {
    let received: any = null;
    const unsub = upload.onProgress((p) => {
      received = p;
    });
    expect(mockBridge.on).toHaveBeenCalledWith("upload:progress", expect.any(Function));
    const fn = mockBridge.on.mock.calls.at(-1)![1] as (c: string, d: string) => void;
    fn("upload:progress", '{"id":"j1","uploaded":5,"total":5,"done":true}');
    expect(received).toEqual({ id: "j1", uploaded: 5, total: 5, done: true });
    unsub();
    expect(mockBridge.off).toHaveBeenCalledWith(7);
  });
});

describe("error propagation", () => {
  it("throws on bridge error", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"error":"forbidden path"}');
    await expect(upload.download("https://x/f", "/etc/passwd")).rejects.toThrow("upload: forbidden path");
  });
});
