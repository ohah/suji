/**
 * @suji/plugin-state-node 단위 테스트 — mock 브릿지로 와이어 계약 검증.
 *
 * 실행: `bun test plugins/state/node/src/index.test.ts`
 *
 * Node 백엔드는 libnode 임베디드라 dylib 로드 불가 → Rust/Go 처럼
 * BackendRegistry 하니스를 못 쓴다. 대신 `globalThis.suji` 브릿지를
 * mock 해 invoke("state", {cmd,...}) 요청 형태와 응답 언랩을 검증
 * (plugins/state/js 테스트 동형, @suji/node sdk.test 패턴).
 *
 * 요청은 raw 문자열이 아니라 parse 후 구조 비교 — JSON 키 순서는
 * Zig 백엔드(필드명 파싱)에 무의미하므로 순서에 결합하지 않는다
 * (plugins/state/js 의 object 구조 비교와 동일한 신호).
 */
import { describe, it, expect, mock, beforeEach } from "bun:test";

const mockBridge = {
  invoke: mock((_backend: string, _request: string) => Promise.resolve("{}")),
  on: mock((_channel: string, _fn: Function) => 1),
  off: mock((_subId: number) => {}),
};

(globalThis as any).suji = mockBridge;

const { state } = await import("./index");

const reply = (obj: unknown) => Promise.resolve(JSON.stringify({ from: "zig", ...(obj as object) }));

/** 마지막 invoke 호출의 backend + parse 한 요청 body (키 순서 무관). */
const lastReq = () => {
  const c = mockBridge.invoke.mock.calls.at(-1)!;
  return { backend: c[0], body: JSON.parse(c[1] as string) };
};

beforeEach(() => {
  mockBridge.invoke.mockClear();
  mockBridge.on.mockClear();
  mockBridge.off.mockClear();
});

describe("state.get", () => {
  it("invoke('state', {cmd:'state:get',key})", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { value: "yoon" } }));
    const val = await state.get("user");
    expect(lastReq()).toEqual({ backend: "state", body: { cmd: "state:get", key: "user" } });
    expect(val).toBe("yoon");
  });

  it("returns null for missing key", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { value: null } }));
    expect(await state.get("missing")).toBeNull();
  });

  it("throws on error envelope", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ error: "boom" }));
    await expect(state.get("x")).rejects.toThrow(/state: boom/);
  });
});

describe("state.set", () => {
  it("invoke('state', {cmd:'state:set',key,value})", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await state.set("user", "yoon");
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:set", key: "user", value: "yoon" },
    });
  });

  it("supports object values", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await state.set("config", { theme: "dark" });
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:set", key: "config", value: { theme: "dark" } },
    });
  });
});

describe("state.delete", () => {
  it("invoke('state', {cmd:'state:delete',key})", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await state.delete("user");
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:delete", key: "user" },
    });
  });
});

describe("state.keys", () => {
  it("returns array of keys", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { keys: ["a", "b", "c"] } }));
    expect(await state.keys()).toEqual(["a", "b", "c"]);
  });

  it("returns empty array when result has no keys", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: {} }));
    expect(await state.keys()).toEqual([]);
  });
});

describe("state.clear", () => {
  it("invoke('state', {cmd:'state:clear'}) (no scope = all)", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await state.clear();
    expect(lastReq()).toEqual({ backend: "state", body: { cmd: "state:clear" } });
  });
});

describe("state.* with scope option", () => {
  it("get with scope passes scope", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { value: "split" } }));
    await state.get("layout", { scope: "window:2" });
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:get", key: "layout", scope: "window:2" },
    });
  });

  it("set with scope passes scope", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await state.set("layout", "split", { scope: "window:2" });
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:set", key: "layout", value: "split", scope: "window:2" },
    });
  });

  it("keys with scope passes scope only", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { keys: ["a"] } }));
    await state.keys({ scope: "session:onboard" });
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:keys", scope: "session:onboard" },
    });
  });

  it("clear with scope passes scope", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await state.clear({ scope: "window:5" });
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:clear", scope: "window:5" },
    });
  });
});

describe("state.watch", () => {
  it("subscribes to state:{key} (no scope)", () => {
    const cancel = state.watch("user", () => {});
    expect(mockBridge.on).toHaveBeenCalledTimes(1);
    expect(mockBridge.on.mock.calls[0][0]).toBe("state:user");
    expect(typeof cancel).toBe("function");
  });

  it("scope=window:N → state:window:N:{key}", () => {
    state.watch("layout", () => {}, { scope: "window:3" });
    expect(mockBridge.on.mock.calls[0][0]).toBe("state:window:3:layout");
  });

  it("scope=global falls back to legacy state:{key}", () => {
    state.watch("user", () => {}, { scope: "global" });
    expect(mockBridge.on.mock.calls[0][0]).toBe("state:user");
  });

  it("cancel() calls bridge.off", () => {
    const cancel = state.watch("user", () => {});
    cancel();
    expect(mockBridge.off).toHaveBeenCalledTimes(1);
  });

  it("delivers parsed JSON to callback", () => {
    let received: unknown;
    state.watch("user", (v) => {
      received = v;
    });
    const handler = mockBridge.on.mock.calls[0][1] as (c: string, d: string) => void;
    handler("state:user", JSON.stringify({ name: "yoon" }));
    expect(received).toEqual({ name: "yoon" });
  });

  it("scope=session:* uses state:<scope>:<key>", () => {
    state.watch("step", () => {}, { scope: "session:onboard" });
    expect(mockBridge.on.mock.calls[0][0]).toBe("state:session:onboard:step");
  });

  it("cancel() passes the exact subId returned by bridge.on to off", () => {
    mockBridge.on.mockReturnValueOnce(42);
    const cancel = state.watch("user", () => {});
    cancel();
    expect(mockBridge.off).toHaveBeenCalledWith(42);
  });

  it("delivers raw string when payload is not JSON", () => {
    let received: unknown;
    state.watch("user", (v) => {
      received = v;
    });
    const handler = mockBridge.on.mock.calls[0][1] as (c: string, d: string) => void;
    handler("state:user", "not-json");
    expect(received).toBe("not-json");
  });
});

// ============================================
// 복잡 경계 — 값 타입 다양성 / 에러 전파 / malformed / 브릿지 부재
// ============================================

describe("state.set value type fidelity", () => {
  it.each([
    ["number", 42],
    ["boolean", true],
    ["null", null],
    ["array", [1, "a", { k: 2 }]],
    ["nested object", { a: { b: [true, null] } }],
    ["empty string", ""],
  ])("preserves %s value verbatim in wire body", async (_label, value) => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { ok: true } }));
    await state.set("k", value as unknown);
    expect(lastReq()).toEqual({ backend: "state", body: { cmd: "state:set", key: "k", value } });
  });
});

describe("state.get type passthrough", () => {
  it("returns nested object as-is (generic T)", async () => {
    const obj = { profile: { name: "yoon", tags: ["a", "b"] } };
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { value: obj } }));
    expect(await state.get<typeof obj>("u")).toEqual(obj);
  });

  it.each([
    ["zero", 0],
    ["false", false],
    ["empty string", ""],
  ])("returns falsy-but-present %s verbatim (not coerced to null)", async (_label, v) => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { value: v } }));
    expect(await state.get("k")).toBe(v);
  });
});

describe("error envelope propagates on every mutator", () => {
  it.each([
    ["set", () => state.set("k", 1)],
    ["delete", () => state.delete("k")],
    ["keys", () => state.keys()],
    ["clear", () => state.clear()],
  ])("%s rejects on {error}", async (_label, op) => {
    mockBridge.invoke.mockReturnValueOnce(reply({ error: "denied" }));
    await expect(op()).rejects.toThrow(/state: denied/);
  });
});

describe("scope='global' is forwarded verbatim (Rust get_in/set_in parity)", () => {
  it("get forwards scope:'global' (not stripped)", async () => {
    mockBridge.invoke.mockReturnValueOnce(reply({ result: { value: 1 } }));
    await state.get("k", { scope: "global" });
    expect(lastReq()).toEqual({
      backend: "state",
      body: { cmd: "state:get", key: "k", scope: "global" },
    });
  });
});

describe("malformed / empty bridge response (js-sibling parity: graceful, no throw)", () => {
  it.each(["not-json", "", "null"])("get → null when response is %p", async (raw) => {
    mockBridge.invoke.mockReturnValueOnce(Promise.resolve(raw));
    expect(await state.get("k")).toBeNull();
  });

  it("keys → [] when response has no parseable result", async () => {
    mockBridge.invoke.mockReturnValueOnce(Promise.resolve("garbage"));
    expect(await state.keys()).toEqual([]);
  });

  it("set does not throw when response is empty", async () => {
    mockBridge.invoke.mockReturnValueOnce(Promise.resolve(""));
    await expect(state.set("k", 1)).resolves.toBeUndefined();
  });
});

describe("bridge absent", () => {
  it("throws a state-node-scoped error (not a generic one)", async () => {
    const saved = (globalThis as any).suji;
    (globalThis as any).suji = undefined;
    try {
      await expect(state.get("k")).rejects.toThrow(/@suji\/plugin-state-node: bridge not available/);
      expect(() => state.watch("k", () => {})).toThrow(
        /@suji\/plugin-state-node: bridge not available/,
      );
    } finally {
      (globalThis as any).suji = saved;
    }
  });
});
