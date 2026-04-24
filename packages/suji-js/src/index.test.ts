import { describe, it, expect, mock, beforeEach } from "bun:test";

// __suji__ 브릿지 모킹
const mockBridge = {
  invoke: mock(() => Promise.resolve({ msg: "pong" })),
  on: mock((event: string, cb: Function) => {
    const cancel = mock(() => {});
    return cancel;
  }),
  emit: mock(() => Promise.resolve()),
  chain: mock(() => Promise.resolve({ chain: true })),
  fanout: mock(() => Promise.resolve({ fanout: true })),
  core: mock(() => Promise.resolve({ core: true })),
  off: mock(() => {}),
};

(globalThis as any).window = { __suji__: mockBridge };

// 모듈 import (window.__suji__ 설정 후)
const { invoke, on, once, send, off, fanout, chain } = await import("./index");

beforeEach(() => {
  mockBridge.invoke.mockClear();
  mockBridge.on.mockClear();
  mockBridge.emit.mockClear();
  mockBridge.chain.mockClear();
  mockBridge.fanout.mockClear();
  mockBridge.off.mockClear();
});

describe("invoke", () => {
  it("calls bridge with channel only", async () => {
    await invoke("ping");
    expect(mockBridge.invoke).toHaveBeenCalledTimes(1);
  });

  it("calls bridge with channel and data", async () => {
    await invoke("greet", { name: "Suji" });
    expect(mockBridge.invoke).toHaveBeenCalledTimes(1);
  });

  it("calls bridge with target option", async () => {
    await invoke("greet", { name: "Suji" }, { target: "rust" });
    expect(mockBridge.invoke).toHaveBeenCalledTimes(1);
  });

  it("returns result", async () => {
    mockBridge.invoke.mockResolvedValueOnce({ result: 42 });
    const result = await invoke<{ result: number }>("add", { a: 1, b: 2 });
    expect(result.result).toBe(42);
  });
});

describe("on", () => {
  it("registers listener and returns cancel function", () => {
    const cancel = on("test-event", () => {});
    expect(mockBridge.on).toHaveBeenCalledTimes(1);
    expect(typeof cancel).toBe("function");
  });

  it("passes callback to bridge", () => {
    const cb = () => {};
    on("test-event", cb);
    expect(mockBridge.on).toHaveBeenCalledWith("test-event", cb);
  });
});

describe("once", () => {
  it("registers listener", () => {
    once("one-shot", () => {});
    expect(mockBridge.on).toHaveBeenCalledTimes(1);
  });

  it("auto-cancels after first call", () => {
    let cancelCalled = false;
    const mockCancel = () => { cancelCalled = true; };
    mockBridge.on.mockReturnValueOnce(mockCancel);

    let receivedData: unknown = null;
    const cb = (data: unknown) => { receivedData = data; };
    once("one-shot", cb);

    // on()에 전달된 래퍼 콜백을 가져와서 호출
    const wrapper = mockBridge.on.mock.calls[0][1] as Function;
    wrapper("test-data");

    expect(receivedData).toBe("test-data");
    expect(cancelCalled).toBe(true);
  });
});

describe("send", () => {
  it("calls bridge emit with JSON stringified data (no target → broadcast)", () => {
    send("click", { button: "save" });
    expect(mockBridge.emit).toHaveBeenCalledTimes(1);
    expect(mockBridge.emit).toHaveBeenCalledWith("click", '{"button":"save"}', undefined);
  });

  it("handles null data", () => {
    send("ping", null);
    expect(mockBridge.emit).toHaveBeenCalledWith("ping", "{}", undefined);
  });

  it("handles undefined data", () => {
    send("ping", undefined);
    expect(mockBridge.emit).toHaveBeenCalledWith("ping", "{}", undefined);
  });

  it("forwards {to: winId} as third argument (webContents.send)", () => {
    send("toast", { text: "saved" }, { to: 2 });
    expect(mockBridge.emit).toHaveBeenCalledWith("toast", '{"text":"saved"}', 2);
  });
});

describe("off", () => {
  it("calls bridge off", () => {
    off("test-event");
    expect(mockBridge.off).toHaveBeenCalledWith("test-event");
  });
});

describe("fanout", () => {
  it("joins backends and stringifies request", async () => {
    await fanout(["zig", "rust", "go"], "ping");
    expect(mockBridge.fanout).toHaveBeenCalledTimes(1);
    expect(mockBridge.fanout).toHaveBeenCalledWith("zig,rust,go", '{"cmd":"ping"}');
  });

  it("includes data in request", async () => {
    await fanout(["rust", "go"], "greet", { name: "Suji" });
    expect(mockBridge.fanout).toHaveBeenCalledWith("rust,go", '{"cmd":"greet","name":"Suji"}');
  });
});

describe("chain", () => {
  it("calls bridge chain with stringified request", async () => {
    await chain("rust", "go", "relay", { msg: "hello" });
    expect(mockBridge.chain).toHaveBeenCalledTimes(1);
    expect(mockBridge.chain).toHaveBeenCalledWith("rust", "go", '{"cmd":"relay","msg":"hello"}');
  });
});

describe("error handling", () => {
  it("throws when bridge not available", async () => {
    const original = (window as any).__suji__;
    (window as any).__suji__ = undefined;

    try {
      await invoke("ping");
      expect(true).toBe(false); // should not reach
    } catch (e: any) {
      expect(e.message).toContain("Suji bridge not available");
    }

    (window as any).__suji__ = original;
  });
});
