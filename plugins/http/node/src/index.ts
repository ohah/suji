/**
 * @suji/plugin-http-node — Node backend wrapper for @suji/plugin-http.
 * Wire contract 은 renderer 변형과 동일.
 *
 * ```ts
 * const { http } = require('@suji/plugin-http-node');
 * await http.setAllowedUrls(['https://api.example.com/*']);
 * const r = await http.fetch('https://api.example.com/v1');
 * ```
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-http-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("http", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`http: ${resp.error}`);
  return resp?.result;
}

export interface FetchOpts {
  method?: "GET" | "POST";
  body?: string;
}

export interface FetchResponse {
  status: number;
  body: string;
}

export const http = {
  async fetch(url: string, opts: FetchOpts = {}): Promise<FetchResponse> {
    const r = await call("http:fetch", {
      url,
      ...(opts.method ? { method: opts.method } : {}),
      ...(opts.body !== undefined ? { body: opts.body } : {}),
    });
    return {
      status: Number(r?.status ?? 0),
      body: String(r?.body ?? ""),
    };
  },

  async setAllowedUrls(urls: string[]): Promise<void> {
    await call("http:set_allowed_urls", { urls });
  },

  async getAllowedUrls(): Promise<string[]> {
    const r = await call("http:get_allowed_urls", {});
    return (r?.urls ?? []) as string[];
  },
};
