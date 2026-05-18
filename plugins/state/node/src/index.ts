/**
 * @suji/plugin-state-node — State Plugin for Suji Node.js backends
 *
 * KV Store with JSON file persistence. The backend counterpart of the
 * renderer `@suji/plugin-state` — same wire contract as the Rust
 * (`suji-plugin-state`) / Go (`suji-plugin-state`) wrappers: route through
 * the `state` backend with the cmd embedded in the request JSON.
 *
 * ```ts
 * const { state } = require('@suji/plugin-state-node');
 *
 * await state.set("user", { name: "yoon" });               // global
 * await state.set("layout", "split", { scope: "window:1" }); // 특정 창
 * const layout = await state.get("layout", { scope: "window:1" });
 * const cancel = state.watch("user", (val) => console.log(val));
 * ```
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
  on(channel: string, fn: (channel: string, data: string) => void): number;
  off(subId: number): void;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-state-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

/** scope: 생략하면 global. "window:N"/"session:*" 등 명시 가능. */
export interface ScopeOpt {
  scope?: string;
}

const withScope = (data: Record<string, unknown>, opt?: ScopeOpt) =>
  opt?.scope ? { ...data, scope: opt.scope } : data;

/** invoke("state", {cmd,...}) → 파싱 후 {from:"zig",result|error} 언랩 (Rust/Go 래퍼 동형). */
async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("state", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`state: ${resp.error}`);
  return resp?.result;
}

export const state = {
  async get<T = unknown>(key: string, opt?: ScopeOpt): Promise<T | null> {
    const r = await call("state:get", withScope({ key }, opt));
    return (r?.value ?? null) as T | null;
  },

  async set(key: string, value: unknown, opt?: ScopeOpt): Promise<void> {
    await call("state:set", withScope({ key, value }, opt));
  },

  async delete(key: string, opt?: ScopeOpt): Promise<void> {
    await call("state:delete", withScope({ key }, opt));
  },

  /** scope 명시 시 해당 scope의 user-key만 (prefix 제거). 미지정 시 모든 키. */
  async keys(opt?: ScopeOpt): Promise<string[]> {
    const r = await call("state:keys", opt?.scope ? { scope: opt.scope } : {});
    return r?.keys ?? [];
  },

  /** scope 지정 시 해당 scope만, 미지정/`{scope:"*"}`이면 전체. */
  async clear(opt?: ScopeOpt): Promise<void> {
    await call("state:clear", opt?.scope ? { scope: opt.scope } : {});
  },

  /**
   * 키 변경 구독 (EventBus). 반환된 함수 호출로 해제.
   * scope 미지정/`"global"` → `state:<key>`, 그 외 → `state:<scope>:<key>`
   * (renderer/Rust 래퍼와 동일 채널 규칙).
   */
  watch(key: string, callback: (value: unknown) => void, opt?: ScopeOpt): () => void {
    const channel =
      !opt?.scope || opt.scope === "global"
        ? `state:${key}`
        : `state:${opt.scope}:${key}`;
    const bridge = getBridge();
    const subId = bridge.on(channel, (_ch: string, raw: string) => {
      let data: unknown;
      try {
        data = JSON.parse(raw);
      } catch {
        data = raw;
      }
      callback(data);
    });
    return () => bridge.off(subId);
  },
};
