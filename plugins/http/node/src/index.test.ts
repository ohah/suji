import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve('{"result":{}}')),
};

(globalThis as any).suji = mockBridge;

const { http } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

function lastPayload(): Record<string, unknown> {
  return JSON.parse(mockBridge.invoke.mock.calls.at(-1)![1] as string);
}

describe("http.fetch Node — channel + payload shape", () => {
  it("default GET (no method/body)", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"status":200,"body":"ok"}}');
    const r = await http.fetch("https://api.x/v1");
    const args = mockBridge.invoke.mock.calls.at(-1)!;
    expect(args[0]).toBe("http");
    expect(lastPayload()).toEqual({ cmd: "http:fetch", url: "https://api.x/v1" });
    expect(r.status).toBe(200);
    expect(r.body).toBe("ok");
  });

  it("POST + body", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"status":201,"body":""}}');
    await http.fetch("https://api.x/v1", { method: "POST", body: '{"a":1}' });
    expect(lastPayload()).toEqual({
      cmd: "http:fetch",
      url: "https://api.x/v1",
      method: "POST",
      body: '{"a":1}',
    });
  });

  it("setAllowedUrls + getAllowedUrls", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await http.setAllowedUrls(["https://api.x/*"]);
    expect(lastPayload()).toEqual({ cmd: "http:set_allowed_urls", urls: ["https://api.x/*"] });

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"urls":["a","b"]}}');
    expect(await http.getAllowedUrls()).toEqual(["a", "b"]);
  });

  it("error propagation", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"error":"forbidden"}');
    await expect(http.fetch("https://blocked/")).rejects.toThrow("http: forbidden");
  });

  it("malformed JSON resp gracefully degrades to defaults", async () => {
    mockBridge.invoke.mockResolvedValueOnce("not json");
    const r = await http.fetch("https://x/");
    expect(r.status).toBe(0);
    expect(r.body).toBe("");
  });

  it("fetch passes headers map", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"status":200,"body":""}}');
    await http.fetch("https://x/", { headers: { "X-Foo": "bar" } });
    expect(lastPayload()).toEqual({ cmd: "http:fetch", url: "https://x/", headers: { "X-Foo": "bar" } });
  });

  it("setAllowedHeaders + getAllowedHeaders", async () => {
    mockBridge.invoke.mockResolvedValueOnce('{"result":{"ok":true}}');
    await http.setAllowedHeaders(["X-A"]);
    expect(lastPayload()).toEqual({ cmd: "http:set_allowed_headers", headers: ["X-A"] });

    mockBridge.invoke.mockResolvedValueOnce('{"result":{"headers":["X-A"]}}');
    expect(await http.getAllowedHeaders()).toEqual(["X-A"]);
  });
});
