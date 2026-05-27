/**
 * @suji/plugin-http — Renderer-safe HTTP fetch for Suji apps.
 *
 * 데스크톱 `suji.http.fetch` 는 backend-only. 이 플러그인은 명시적 URL
 * allowlist 게이트로 renderer 에서도 fetch 호출 가능.
 *
 * ```ts
 * import { http } from '@suji/plugin-http';
 * await http.setAllowedUrls(["https://api.example.com/*"]);
 * const { status, body } = await http.fetch("https://api.example.com/v1/me");
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

export interface FetchOpts {
  method?: "GET" | "POST";
  body?: string;
  /** 헤더 맵. 이름이 setAllowedHeaders 로 등록된 것만 허용. 미허용 시 fetch 거부. */
  headers?: Record<string, string>;
}

export interface FetchResponse {
  status: number;
  body: string;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const resp = await getBridge().invoke(cmd, payload);
  if (resp?.error) throw new Error(`http: ${resp.error}`);
  return resp?.result ?? resp;
}

export const http = {
  async fetch(url: string, opts: FetchOpts = {}): Promise<FetchResponse> {
    const r = await call("http:fetch", {
      url,
      ...(opts.method ? { method: opts.method } : {}),
      ...(opts.body !== undefined ? { body: opts.body } : {}),
      ...(opts.headers ? { headers: opts.headers } : {}),
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

  /** 요청 헤더 이름 화이트리스트 (case-insensitive). 정책: deny-by-default —
   * 등록 안 된 이름은 fetch 거부. Cookie/Authorization 등 누출 위험 헤더는
   * 명시적 opt-in 만 허용. */
  async setAllowedHeaders(headers: string[]): Promise<void> {
    await call("http:set_allowed_headers", { headers });
  },

  async getAllowedHeaders(): Promise<string[]> {
    const r = await call("http:get_allowed_headers", {});
    return (r?.headers ?? []) as string[];
  },
};
