/**
 * @suji/plugin-upload-node — 파일 업로드/다운로드 for Suji Node backends.
 * Wire contract 은 renderer `@suji/plugin-upload` 와 동일.
 *
 * ```ts
 * const { upload } = require('@suji/plugin-upload-node');
 * await upload.setAllowedUrls(['https://api.example.com/*']);
 * await upload.setAllowedPaths(['/srv/data']);
 * await upload.upload('https://api.example.com/u', '/srv/data/a.png', { contentType: 'image/png' });
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
      "@suji/plugin-upload-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("upload", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`upload: ${resp.error}`);
  return resp?.result;
}

export interface UploadOptions {
  fieldName?: string;
  fileName?: string;
  contentType?: string;
  id?: string;
}

export interface UploadProgress {
  id: string;
  uploaded: number;
  total: number;
  done: boolean;
}

export interface UploadResult {
  status: number;
  body: string;
}

export interface DownloadResult {
  status: number;
  bytes: number;
}

export const upload = {
  async upload(url: string, filePath: string, opts?: UploadOptions): Promise<UploadResult> {
    const data: Record<string, unknown> = { url, filePath };
    if (opts?.fieldName !== undefined) data.fieldName = opts.fieldName;
    if (opts?.fileName !== undefined) data.fileName = opts.fileName;
    if (opts?.contentType !== undefined) data.contentType = opts.contentType;
    if (opts?.id !== undefined) data.id = opts.id;
    const r = await call("upload:upload", data);
    return { status: Number(r?.status ?? 0), body: String(r?.body ?? "") };
  },
  async download(url: string, filePath: string, opts?: Pick<UploadOptions, "id">): Promise<DownloadResult> {
    const data: Record<string, unknown> = { url, filePath };
    if (opts?.id !== undefined) data.id = opts.id;
    const r = await call("upload:download", data);
    return { status: Number(r?.status ?? 0), bytes: Number(r?.bytes ?? 0) };
  },
  onProgress(cb: (p: UploadProgress) => void): () => void {
    const bridge = getBridge();
    const subId = bridge.on("upload:progress", (_ch: string, raw: string) => {
      try {
        cb(JSON.parse(raw) as UploadProgress);
      } catch {
        /* ignore malformed */
      }
    });
    return () => bridge.off(subId);
  },
  async setAllowedUrls(urls: string[]): Promise<void> {
    await call("upload:set_allowed_urls", { urls });
  },
  async getAllowedUrls(): Promise<string[]> {
    const r = await call("upload:get_allowed_urls", {});
    return (r?.urls ?? []) as string[];
  },
  async setAllowedPaths(paths: string[]): Promise<void> {
    await call("upload:set_allowed_paths", { paths });
  },
  async getAllowedPaths(): Promise<string[]> {
    const r = await call("upload:get_allowed_paths", {});
    return (r?.paths ?? []) as string[];
  },
};
