/**
 * @suji/plugin-store-node — Persistent file-backed config for Suji Node backends.
 * Wire contract 은 renderer `@suji/plugin-store` 와 동일.
 *
 * ```ts
 * const { createStore } = require('@suji/plugin-store-node');
 * const settings = createStore("settings");
 * await settings.set("theme", "dark");
 * ```
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-store-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("store", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`store: ${resp.error}`);
  return resp?.result;
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

export const store: Store = createStore();
