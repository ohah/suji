/**
 * @suji/plugin-store — Persistent file-backed config (electron-store 동등).
 *
 * state 와 차이: store 는 persistent **config** (atomic write), 여러 이름의 store
 * 인스턴스. state 는 ephemeral KV with scope.
 *
 * ```ts
 * import { createStore } from '@suji/plugin-store';
 *
 * const settings = createStore("settings");  // <appdata>/suji-app/store/settings.json
 * await settings.set("theme", "dark");
 * const theme = await settings.get<string>("theme");
 * await settings.delete("oldKey");
 * const keys = await settings.keys();
 * await settings.clear();
 * ```
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

async function call(channel: string, data: Record<string, unknown>): Promise<any> {
  const resp = await getBridge().invoke(channel, data);
  if (resp?.error) throw new Error(`store: ${resp.error}`);
  return resp?.result ?? resp;
}

export interface Store {
  get<T = unknown>(key: string): Promise<T | null>;
  set(key: string, value: unknown): Promise<void>;
  has(key: string): Promise<boolean>;
  delete(key: string): Promise<void>;
  clear(): Promise<void>;
  keys(): Promise<string[]>;
  size(): Promise<number>;
  getPath(): Promise<string>;
}

/** name 미지정 시 "config" 사용. 각 name 별 독립 파일/state. */
export function createStore(name: string = "config"): Store {
  return {
    async get<T = unknown>(key: string): Promise<T | null> {
      const r = await call("store:get", { name, key });
      return (r?.value ?? null) as T | null;
    },
    async set(key: string, value: unknown): Promise<void> {
      await call("store:set", { name, key, value });
    },
    async has(key: string): Promise<boolean> {
      const r = await call("store:has", { name, key });
      return Boolean(r?.has);
    },
    async delete(key: string): Promise<void> {
      await call("store:delete", { name, key });
    },
    async clear(): Promise<void> {
      await call("store:clear", { name });
    },
    async keys(): Promise<string[]> {
      const r = await call("store:keys", { name });
      return (r?.keys ?? []) as string[];
    },
    async size(): Promise<number> {
      const r = await call("store:size", { name });
      return Number(r?.size ?? 0);
    },
    async getPath(): Promise<string> {
      const r = await call("store:get_path", { name });
      return String(r?.path ?? "");
    },
  };
}

/** 편의: default "config" store 직접 사용. */
export const store: Store = createStore();
