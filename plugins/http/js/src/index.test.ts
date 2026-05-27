import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock(() => Promise.resolve({})),
};

(globalThis as any).window = { __suji__: mockBridge };

const { http } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
});

describe("http.fetch — channel + payload shape", () => {
  it("default GET (no method/body)", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { status: 200, body: "{}" } });
    const r = await http.fetch("https://api.x/v1");
    expect(mockBridge.invoke).toHaveBeenCalledWith("http:fetch", { url: "https://api.x/v1" });
    expect(r.status).toBe(200);
    expect(r.body).toBe("{}");
  });

  it("explicit POST + body", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { status: 201, body: "ok" } });
    await http.fetch("https://api.x/v1/items", { method: "POST", body: '{"a":1}' });
    expect(mockBridge.invoke).toHaveBeenCalledWith("http:fetch", {
      url: "https://api.x/v1/items",
      method: "POST",
      body: '{"a":1}',
    });
  });

  it("response defaults: missing status→0, missing body→''", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    const r = await http.fetch("https://api.x/");
    expect(r.status).toBe(0);
    expect(r.body).toBe("");
  });
});

describe("http allowlist", () => {
  it("setAllowedUrls passes patterns through", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await http.setAllowedUrls(["https://*.example.com/*", "https://api.x/*"]);
    expect(mockBridge.invoke).toHaveBeenCalledWith("http:set_allowed_urls", {
      urls: ["https://*.example.com/*", "https://api.x/*"],
    });
  });

  it("getAllowedUrls returns array", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { urls: ["https://*.x/*"] } });
    expect(await http.getAllowedUrls()).toEqual(["https://*.x/*"]);
  });

  it("getAllowedUrls returns empty when urls missing", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    expect(await http.getAllowedUrls()).toEqual([]);
  });
});

describe("error propagation", () => {
  it("throws when bridge returns error", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ error: "forbidden" });
    await expect(http.fetch("https://blocked/")).rejects.toThrow("http: forbidden");
  });
});

describe("http headers + allowlist", () => {
  it("fetch passes headers map", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { status: 200, body: "" } });
    await http.fetch("https://x/", { headers: { "X-Foo": "bar", Accept: "application/json" } });
    expect(mockBridge.invoke).toHaveBeenCalledWith("http:fetch", {
      url: "https://x/",
      headers: { "X-Foo": "bar", Accept: "application/json" },
    });
  });

  it("setAllowedHeaders routes array", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { ok: true } });
    await http.setAllowedHeaders(["X-Custom", "Authorization"]);
    expect(mockBridge.invoke).toHaveBeenCalledWith("http:set_allowed_headers", {
      headers: ["X-Custom", "Authorization"],
    });
  });

  it("getAllowedHeaders returns array", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: { headers: ["X-Custom"] } });
    expect(await http.getAllowedHeaders()).toEqual(["X-Custom"]);
  });

  it("getAllowedHeaders returns empty when missing", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: {} });
    expect(await http.getAllowedHeaders()).toEqual([]);
  });
});
