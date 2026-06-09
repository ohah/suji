/**
 * @suji/plugin-upload — 파일 업로드(multipart/form-data) / 다운로드(→디스크).
 *
 * http 플러그인이 문자열 body 만 다루는 것과 달리, 디스크 파일을 직접 전송/수신한다
 * (바이너리를 JS 메모리에 올리지 않음). URL + 파일경로 둘 다 deny-by-default allowlist.
 *
 * ```ts
 * import { upload } from '@suji/plugin-upload';
 *
 * await upload.setAllowedUrls(['https://api.example.com/*']);
 * await upload.setAllowedPaths(['~/Documents/myapp']);
 *
 * const unsub = upload.onProgress((p) => console.log(p.uploaded, '/', p.total));
 * const res = await upload.upload('https://api.example.com/u', '~/Documents/myapp/a.png',
 *   { fieldName: 'file', fileName: 'a.png', contentType: 'image/png', id: 'job1' });
 * await upload.download('https://api.example.com/f/1', '~/Documents/myapp/out.bin', { id: 'job2' });
 * unsub();
 * ```
 *
 * 정직 경계: 전송은 bounded(파일 ≤ 64MB) in-memory — 코어가 std.http.Client.fetch 만
 *   쓰고 low-level streaming 미사용이라 mid-stream progress 불가. 완료 이벤트만 발화.
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
  on(event: string, cb: (data: unknown) => void): () => void;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

async function call(channel: string, data: Record<string, unknown>): Promise<any> {
  const resp = await getBridge().invoke(channel, data);
  if (resp?.error) throw new Error(`upload: ${resp.error}`);
  return resp?.result ?? resp;
}

export interface UploadOptions {
  /** multipart 폼 필드명. 기본 "file". */
  fieldName?: string;
  /** 서버에 전달할 파일명. 기본 "upload". */
  fileName?: string;
  /** 파일 MIME. 기본 "application/octet-stream". */
  contentType?: string;
  /** progress 이벤트 상관용 id. */
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
  /** 디스크 파일을 multipart/form-data 로 POST. */
  async upload(url: string, filePath: string, opts?: UploadOptions): Promise<UploadResult> {
    const data: Record<string, unknown> = { url, filePath };
    if (opts?.fieldName !== undefined) data.fieldName = opts.fieldName;
    if (opts?.fileName !== undefined) data.fileName = opts.fileName;
    if (opts?.contentType !== undefined) data.contentType = opts.contentType;
    if (opts?.id !== undefined) data.id = opts.id;
    const r = await call("upload:upload", data);
    return { status: Number(r?.status ?? 0), body: String(r?.body ?? "") };
  },
  /** URL 을 GET 해 디스크 파일로 저장. */
  async download(url: string, filePath: string, opts?: Pick<UploadOptions, "id">): Promise<DownloadResult> {
    const data: Record<string, unknown> = { url, filePath };
    if (opts?.id !== undefined) data.id = opts.id;
    const r = await call("upload:download", data);
    return { status: Number(r?.status ?? 0), bytes: Number(r?.bytes ?? 0) };
  },
  /** 완료 progress 이벤트 구독. 반환 함수로 해제. */
  onProgress(cb: (p: UploadProgress) => void): () => void {
    return getBridge().on("upload:progress", (data) => cb(data as UploadProgress));
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
