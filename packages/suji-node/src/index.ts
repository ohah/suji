/**
 * @suji/node — Suji Desktop Framework Node.js Backend SDK
 *
 * libnode 임베딩 환경에서 사용. globalThis.suji를 타입 안전하게 래핑.
 *
 * ```ts
 * import { handle, invoke, invokeSync, send } from '@suji/node';
 *
 * handle('ping', () => ({ msg: 'pong' }));
 *
 * handle('greet', (data) => ({
 *   greeting: `Hello ${data.name}!`
 * }));
 *
 * // 크로스 호출 (핸들러 내부 — 동기)
 * handle('call-zig', () => {
 *   const result = invokeSync('zig', { cmd: 'ping' });
 *   return { from: 'node', result };
 * });
 *
 * // 이벤트 발신
 * send('my-event', { msg: 'hello from Node.js' });
 * ```
 */

// ============================================
// Types
// ============================================

/** IPC 요청의 sender 창 컨텍스트 (Electron event.sender/BrowserWindow 대응). */
export interface InvokeEvent {
  window: {
    id: number;
    /** 익명 창이면 null. */
    name: string | null;
    /** sender 창의 main frame URL (로드 전/빈 페이지면 null). */
    url: string | null;
    /** sender frame이 main frame인지 (false면 iframe). wire에서 주입 안 됐으면 null. */
    is_main_frame: boolean | null;
  };
}

/**
 * 1-arity: 기존 `(data) => result` — 호환.
 * 2-arity: `(data, event) => result` — Zig SDK의 `fn(Request, InvokeEvent)` 대응.
 */
export type HandlerFn<TReq = unknown, TRes = unknown> =
  | ((data: TReq) => TRes)
  | ((data: TReq, event: InvokeEvent) => TRes);

interface SujiBridge {
  handle(channel: string, fn: (data: string, event: InvokeEvent) => string): void;
  invoke(backend: string, request: string): Promise<string>;
  invokeSync(backend: string, request: string): string;
  send(channel: string, data: string): void;
  /** Electron webContents.send 대응. 구버전 core는 이 필드가 없을 수 있음. */
  sendTo?(windowId: number, channel: string, data: string): void;
  on(channel: string, fn: (channel: string, data: string) => void): number;
  off(subId: number): void;
  register(channel: string): void;
  quit(): void;
  platform(): string;
}

// ============================================
// Bridge access
// ============================================

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      '@suji/node: bridge not available. This module must run inside a Suji app (libnode embedding).'
    );
  }
  return bridge;
}

// ============================================
// Handler registration
// ============================================

/**
 * 핸들러 등록 — 프론트엔드/다른 백엔드에서 이 채널로 호출 가능
 *
 * 콜백은 파싱된 객체를 받고, 반환값은 자동으로 JSON.stringify됨.
 * 문자열을 반환하면 그대로 전달.
 *
 * @example
 * handle('ping', () => ({ msg: 'pong' }));
 * handle('greet', (data) => ({ hello: data.name }));
 */
export function handle<TReq = unknown, TRes = unknown>(
  channel: string,
  handler: HandlerFn<TReq, TRes>,
): void {
  getBridge().handle(channel, (raw: string, event: InvokeEvent) => {
    let data: TReq;
    try {
      data = JSON.parse(raw);
    } catch {
      data = raw as unknown as TReq;
    }

    // 핸들러 arity: 1이면 event 생략 (기존 시그니처 호환), 2면 같이 전달.
    // bridge.cc가 event 객체를 항상 두 번째 인자로 넘기므로 arity가 유일한 분기 기준.
    const result = handler.length >= 2
      ? (handler as (d: TReq, e: InvokeEvent) => TRes)(data, event)
      : (handler as (d: TReq) => TRes)(data);

    if (typeof result === 'string') return result;
    return JSON.stringify(result);
  });
}

// ============================================
// Cross-backend invocation
// ============================================

/**
 * 사용자 핸들러 타입 declaration. @suji/api와 동일 SujiHandlers 패턴 — 사용자가
 * declaration merging으로 채우면 invoke/invokeSync가 cmd/req/res를 추론.
 *
 * frontend/backend 양쪽이 같은 SujiHandlers를 채우려면 보통 root에 단일 .d.ts 두고
 * 두 패키지 각각 augment.
 *
 * ```ts
 * declare module '@suji/node' {
 *   interface SujiHandlers {
 *     ping: { req: void; res: { msg: string } };
 *     greet: { req: { name: string }; res: string };
 *   }
 * }
 * ```
 */
export interface SujiHandlers {}

/**
 * 다른 백엔드 비동기 호출 (Promise 반환, event loop 비블록). untyped — type-safe는
 * `call` 사용. 핸들러 밖에서 사용. 핸들러 안에서는 invokeSync.
 *
 * @example
 * const result = await invoke('zig', { cmd: 'ping' });
 */
export async function invoke<T = unknown>(
  backend: string,
  request: Record<string, unknown> = {},
): Promise<T> {
  const raw = await getBridge().invoke(backend, JSON.stringify(request));
  try {
    return JSON.parse(raw) as T;
  } catch {
    return raw as unknown as T;
  }
}

/**
 * 다른 백엔드 동기 호출 (핸들러 내부용). untyped — type-safe는 `callSync`.
 *
 * event loop을 블록하므로 핸들러 안에서만 사용할 것.
 *
 * @example
 * handle('call-zig', () => {
 *   const result = invokeSync('zig', { cmd: 'ping' });
 *   return { from: 'node', result };
 * });
 */
export function invokeSync<T = unknown>(
  backend: string,
  request: Record<string, unknown> = {},
): T {
  const raw = getBridge().invokeSync(backend, JSON.stringify(request));
  try {
    return JSON.parse(raw) as T;
  } catch {
    return raw as unknown as T;
  }
}

/** SujiHandlers 등록된 cmd만 typed (req/res 추론). */
type CallArgs<K extends keyof SujiHandlers & string> =
  SujiHandlers[K] extends { req: infer R }
    ? [R] extends [void | undefined]
      ? []
      : [data: R]
    : [data?: Record<string, unknown>];

type CallRes<K extends keyof SujiHandlers & string> =
  SujiHandlers[K] extends { res: infer R } ? R : unknown;

/**
 * Type-safe `invoke` wrapper — SujiHandlers 등록된 cmd만 호출 가능.
 *
 * @example
 * declare module '@suji/node' {
 *   interface SujiHandlers {
 *     greet: { req: { name: string }; res: string };
 *   }
 * }
 * const greeting = await call('zig', 'greet', { name: 'Suji' });  // res: string 추론
 */
export async function call<K extends keyof SujiHandlers & string>(
  backend: string,
  cmd: K,
  ...args: CallArgs<K>
): Promise<CallRes<K>> {
  const data = args[0];
  return invoke<CallRes<K>>(backend, { cmd, ...(data ?? {}) });
}

/** sync 변형 — 핸들러 내부용. */
export function callSync<K extends keyof SujiHandlers & string>(
  backend: string,
  cmd: K,
  ...args: CallArgs<K>
): CallRes<K> {
  const data = args[0];
  return invokeSync<CallRes<K>>(backend, { cmd, ...(data ?? {}) });
}

// ============================================
// Events
// ============================================

/**
 * 이벤트 발신 — 프론트엔드로 전달
 *
 * @example
 * send('data-updated', { items: [1, 2, 3] });
 */
export function send(channel: string, data: unknown = {}): void {
  getBridge().send(channel, JSON.stringify(data));
}

/**
 * 특정 창에만 이벤트 전달 (Electron `webContents.send` 대응).
 * 대상 창이 닫혔거나 bridge가 구버전이면 silent no-op.
 *
 * @example
 * sendTo(2, 'toast', { text: 'saved' });
 */
export function sendTo(windowId: number, channel: string, data: unknown = {}): void {
  const bridge = getBridge();
  if (!bridge.sendTo) return;
  bridge.sendTo(windowId, channel, JSON.stringify(data));
}

// ============================================
// Channel registration
// ============================================

/**
 * 이벤트 수신 — 프론트엔드/다른 백엔드에서 발신한 이벤트를 수신
 *
 * @returns 구독 해제 함수
 *
 * @example
 * const cancel = on('data-updated', (data) => {
 *   console.log('received:', data);
 * });
 * // 나중에 해제
 * cancel();
 */
export function on<T = unknown>(
  channel: string,
  callback: (data: T) => void,
): () => void {
  const subId = getBridge().on(channel, (_ch: string, raw: string) => {
    let data: T;
    try {
      data = JSON.parse(raw) as T;
    } catch {
      data = raw as unknown as T;
    }
    callback(data);
  });

  return () => off(subId);
}

/**
 * 이벤트 구독 해제
 */
export function off(subId: number): void {
  getBridge().off(subId);
}

/**
 * 이벤트 한 번만 수신
 *
 * @returns 구독 해제 함수
 */
export function once<T = unknown>(
  channel: string,
  callback: (data: T) => void,
): () => void {
  let subId: number;
  subId = getBridge().on(channel, (_ch: string, raw: string) => {
    getBridge().off(subId);
    let data: T;
    try {
      data = JSON.parse(raw) as T;
    } catch {
      data = raw as unknown as T;
    }
    callback(data);
  });

  return () => getBridge().off(subId);
}

/**
 * 채널을 수동으로 등록 (자동 라우팅 테이블에 추가)
 *
 * handle()은 자동으로 register하지 않음 (bridge.cc에서 별도 관리).
 * 명시적으로 코어 라우팅 테이블에 등록해야 할 때 사용.
 */
export function register(channel: string): void {
  getBridge().register(channel);
}

// ============================================
// Electron 호환 API — quit / platform
// ============================================

/**
 * 앱 종료 요청 (Electron `app.quit()` 호환).
 *
 * 주로 `on('window:all-closed', ...)` 핸들러에서 플랫폼 확인 후 호출:
 *
 * ```ts
 * on('window:all-closed', () => {
 *   if (platform() !== PLATFORM_MACOS) quit();
 * });
 * ```
 */
export function quit(): void {
  getBridge().quit();
}

/**
 * 현재 플랫폼 이름 — `"macos"` | `"linux"` | `"windows"` | `"other"`.
 * Electron `process.platform` 대응 (Suji는 `"darwin"` 대신 `"macos"`).
 */
export function platform(): string {
  return getBridge().platform();
}

/** 플랫폼 상수 — `platform()` 반환값과 비교할 때 사용. Suji는 macOS/Linux/Windows만 지원. */
export const PLATFORM_MACOS = 'macos';
export const PLATFORM_LINUX = 'linux';
export const PLATFORM_WINDOWS = 'windows';

// ============================================
// windows API — Phase 4-A 백엔드 SDK
// Frontend `@suji/api` windows.* 와 동일한 cmd JSON 형식. invoke('__core__', ...) 경유.
// 핸들러 밖에서는 await windows.X(); 핸들러 안에서는 sync 필요 시 invokeSync('__core__', {cmd:..., ...}) 직접 사용.
// ============================================

export type TitleBarStyle = 'default' | 'hidden' | 'hiddenInset';

export interface WindowOptions {
  title?: string;
  url?: string;
  /** WM 등록 이름 (singleton 키). 동일 name이 이미 있으면 기존 창 id 반환. */
  name?: string;
  width?: number;
  height?: number;
  /** 초기 위치 (px). 0/생략 시 OS cascade 자동 배치. */
  x?: number;
  y?: number;
  /** 부모 창 id 직접 지정 (parent보다 우선). */
  parentId?: number;
  parent?: string;
  frame?: boolean;
  transparent?: boolean;
  backgroundColor?: string;
  titleBarStyle?: TitleBarStyle;
  resizable?: boolean;
  alwaysOnTop?: boolean;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
  fullscreen?: boolean;
}

export interface CreateWindowResponse {
  cmd: 'create_window';
  from: 'zig-core';
  windowId: number;
}

export interface WindowOpResponse {
  cmd: string;
  from: 'zig-core';
  windowId: number;
  ok: boolean;
}

export interface GetUrlResponse extends WindowOpResponse {
  cmd: 'get_url';
  url: string | null;
}

export interface IsLoadingResponse extends WindowOpResponse {
  cmd: 'is_loading';
  loading: boolean;
}

export interface IsDevToolsOpenedResponse extends WindowOpResponse {
  cmd: 'is_dev_tools_opened';
  opened: boolean;
}

export interface ZoomLevelResponse extends WindowOpResponse {
  cmd: 'get_zoom_level';
  level: number;
}

export interface ZoomFactorResponse extends WindowOpResponse {
  cmd: 'get_zoom_factor';
  factor: number;
}

export interface SetBoundsArgs {
  x?: number;
  y?: number;
  width?: number;
  height?: number;
}

export const windows = {
  /** suji.json `windows[]`와 동일한 옵션 셋 — frame/transparent/parent/x/y/etc. 모두 런타임 지정 가능. */
  create(opts: WindowOptions = {}): Promise<CreateWindowResponse> {
    return invoke<CreateWindowResponse>('__core__', { cmd: 'create_window', ...opts });
  },
  loadURL(windowId: number, url: string): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'load_url', windowId, url });
  },
  reload(windowId: number, ignoreCache = false): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'reload', windowId, ignoreCache });
  },
  /** fire-and-forget — 결과 회신 없음. 결과 필요 시 JS에서 `suji.send`로 회신. */
  executeJavaScript(windowId: number, code: string): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'execute_javascript', windowId, code });
  },
  getURL(windowId: number): Promise<GetUrlResponse> {
    return invoke<GetUrlResponse>('__core__', { cmd: 'get_url', windowId });
  },
  isLoading(windowId: number): Promise<IsLoadingResponse> {
    return invoke<IsLoadingResponse>('__core__', { cmd: 'is_loading', windowId });
  },
  setTitle(windowId: number, title: string): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_title', windowId, title });
  },
  setBounds(windowId: number, bounds: SetBoundsArgs): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_bounds', windowId, ...bounds });
  },

  openDevTools(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'open_dev_tools', windowId });
  },
  closeDevTools(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'close_dev_tools', windowId });
  },
  isDevToolsOpened(windowId: number): Promise<IsDevToolsOpenedResponse> {
    return invoke<IsDevToolsOpenedResponse>('__core__', { cmd: 'is_dev_tools_opened', windowId });
  },
  toggleDevTools(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'toggle_dev_tools', windowId });
  },

  setZoomLevel(windowId: number, level: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_zoom_level', windowId, level });
  },
  getZoomLevel(windowId: number): Promise<ZoomLevelResponse> {
    return invoke<ZoomLevelResponse>('__core__', { cmd: 'get_zoom_level', windowId });
  },
  setZoomFactor(windowId: number, factor: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_zoom_factor', windowId, factor });
  },
  getZoomFactor(windowId: number): Promise<ZoomFactorResponse> {
    return invoke<ZoomFactorResponse>('__core__', { cmd: 'get_zoom_factor', windowId });
  },

  undo(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'undo', windowId });
  },
  redo(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'redo', windowId });
  },
  cut(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'cut', windowId });
  },
  copy(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'copy', windowId });
  },
  paste(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'paste', windowId });
  },
  selectAll(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'select_all', windowId });
  },

  findInPage(
    windowId: number,
    text: string,
    options?: { forward?: boolean; matchCase?: boolean; findNext?: boolean },
  ): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', {
      cmd: 'find_in_page',
      windowId,
      text,
      forward: options?.forward ?? true,
      matchCase: options?.matchCase ?? false,
      findNext: options?.findNext ?? false,
    });
  },

  stopFindInPage(windowId: number, clearSelection = false): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'stop_find_in_page', windowId, clearSelection });
  },

  /** PDF 인쇄. CEF는 콜백 async라 두 단계 신호:
   *  1. 코어 IPC 응답 — 요청 접수만 (CEF에 큐잉, 파일 아직 X).
   *  2. `window:pdf-print-finished` 이벤트({path, success}) — 실 PDF 작성 완료.
   *  이 SDK는 listener를 path로 매칭해 Promise<{success}>로 단일화. */
  printToPDF(windowId: number, path: string): Promise<{ success: boolean }> {
    return new Promise((resolve) => {
      const off = on("window:pdf-print-finished", (data) => {
        const d = data as { path?: string; success?: boolean };
        if (d.path === path) {
          off();
          resolve({ success: d.success === true });
        }
      });
      invoke<WindowOpResponse>('__core__', { cmd: 'print_to_pdf', windowId, path });
    });
  },
};

// ============================================
// Clipboard / Shell / Dialog — Electron parity. Frontend `@suji/api`와 동일 cmd.
// 모두 invoke('__core__', ...) 경유 — IPC가 cef.zig handler로 라우팅.
// ============================================

export const clipboard = {
  /** 시스템 클립보드 plain text 읽기. */
  async readText(): Promise<string> {
    const r = await invoke<{ text: string }>('__core__', { cmd: 'clipboard_read_text' });
    return r.text ?? '';
  },

  /** 시스템 클립보드 plain text 쓰기. */
  async writeText(text: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'clipboard_write_text', text });
    return r.success === true;
  },

  async clear(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'clipboard_clear' });
    return r.success === true;
  },
};

export const shell = {
  /** URL을 시스템 기본 핸들러로 (http(s) → 브라우저, mailto: → 메일 앱 등). */
  async openExternal(url: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'shell_open_external', url });
    return r.success === true;
  },

  async showItemInFolder(path: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'shell_show_item_in_folder', path });
    return r.success === true;
  },

  async beep(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'shell_beep' });
    return r.success === true;
  },

  /** 휴지통으로 이동 (macOS NSFileManager `trashItemAtURL:`). 실패하면 false. */
  async trashItem(path: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'shell_trash_item', path });
    return r.success === true;
  },
};

// ============================================
// fs — 파일 시스템 API (text/stat/mkdir/readdir, Electron `fs.promises.*`)
// ============================================

export type FileType =
  | 'file'
  | 'directory'
  | 'symlink'
  | 'blockDevice'
  | 'characterDevice'
  | 'fifo'
  | 'socket'
  | 'whiteout'
  | 'door'
  | 'eventPort'
  | 'unknown';

export interface FsStat {
  success: boolean;
  type: FileType;
  size: number;
  /** Last modification time in milliseconds since UTC 1970-01-01 (compatible with `new Date(mtime)`). */
  mtime: number;
}

export interface FsDirEntry {
  name: string;
  type: FileType;
}

export const fs = {
  async readFile(path: string): Promise<string> {
    const r = await invoke<{ success: boolean; text: string; error?: string }>('__core__', { cmd: 'fs_read_file', path });
    if (r.success !== true) throw new Error(r.error ?? 'fs_read_file failed');
    return r.text;
  },

  async writeFile(path: string, text: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'fs_write_file', path, text });
    return r.success === true;
  },

  async stat(path: string): Promise<FsStat> {
    const r = await invoke<FsStat & { error?: string }>('__core__', { cmd: 'fs_stat', path });
    if (r.success !== true) throw new Error(r.error ?? 'fs_stat failed');
    return r;
  },

  async mkdir(path: string, options: { recursive?: boolean } = {}): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'fs_mkdir', path, recursive: options.recursive === true });
    return r.success === true;
  },

  async readdir(path: string): Promise<FsDirEntry[]> {
    const r = await invoke<{ success: boolean; entries: FsDirEntry[]; error?: string }>('__core__', { cmd: 'fs_readdir', path });
    if (r.success !== true) throw new Error(r.error ?? 'fs_readdir failed');
    return r.entries;
  },

  /** Remove `path`. `recursive` deletes directories; `force` ignores not-found (matches `node:fs.rm`). */
  async rm(path: string, options: { recursive?: boolean; force?: boolean } = {}): Promise<boolean> {
    const r = await invoke<{ success: boolean; error?: string }>('__core__', {
      cmd: 'fs_rm',
      path,
      recursive: options.recursive === true,
      force: options.force === true,
    });
    if (r.success !== true) throw new Error(r.error ?? 'fs_rm failed');
    return true;
  },
};

// ============================================
// notification — 시스템 알림 (Electron `Notification`). macOS only (UNUserNotificationCenter).
// 클릭은 `notification:click {notificationId}` 이벤트로 수신.
// ============================================

export interface NotificationOptions {
  title: string;
  body: string;
  silent?: boolean;
}

export const notification = {
  async isSupported(): Promise<boolean> {
    const r = await invoke<{ supported: boolean }>('__core__', { cmd: 'notification_is_supported' });
    return r.supported === true;
  },

  async requestPermission(): Promise<boolean> {
    const r = await invoke<{ granted: boolean }>('__core__', { cmd: 'notification_request_permission' });
    return r.granted === true;
  },

  async show(options: NotificationOptions): Promise<{ notificationId: string; success: boolean }> {
    return invoke<{ notificationId: string; success: boolean }>('__core__', {
      cmd: 'notification_show',
      ...options,
    });
  },

  async close(notificationId: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'notification_close', notificationId });
    return r.success === true;
  },
};

// ============================================
// tray — 시스템 트레이 (Electron `Tray`). frontend `@suji/api`와 동일 cmd.
// 클릭은 `tray:menu-click {trayId, click}` 이벤트로 수신 (suji.on 사용).
// ============================================

export interface TrayMenuSeparator { type: 'separator'; }
export interface TrayMenuItemSpec { label: string; click: string; }
export type TrayMenuItem = TrayMenuItemSpec | TrayMenuSeparator;

export interface TrayCreateOptions {
  title?: string;
  tooltip?: string;
}

export const tray = {
  async create(options: TrayCreateOptions = {}): Promise<{ trayId: number }> {
    return invoke<{ trayId: number }>('__core__', { cmd: 'tray_create', ...options });
  },

  async setTitle(trayId: number, title: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'tray_set_title', trayId, title });
    return r.success === true;
  },

  async setTooltip(trayId: number, tooltip: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'tray_set_tooltip', trayId, tooltip });
    return r.success === true;
  },

  async setMenu(trayId: number, items: TrayMenuItem[]): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'tray_set_menu', trayId, items });
    return r.success === true;
  },

  async destroy(trayId: number): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'tray_destroy', trayId });
    return r.success === true;
  },
};

// ============================================
// menu — macOS application menu customization.
// App 메뉴(Quit/Hide 등)는 Suji가 유지하고, 클릭은 `menu:click {click}` 이벤트로 수신.
// ============================================

export interface MenuSeparator { type: 'separator'; }
export interface MenuCommandItem {
  type?: 'item';
  label: string;
  click: string;
  enabled?: boolean;
}
export interface MenuCheckboxItem {
  type: 'checkbox';
  label: string;
  click: string;
  checked?: boolean;
  enabled?: boolean;
}
export interface MenuSubmenuItem {
  type?: 'submenu';
  label: string;
  enabled?: boolean;
  submenu: MenuItem[];
}
export type MenuItem = MenuCommandItem | MenuCheckboxItem | MenuSeparator | MenuSubmenuItem;

export const menu = {
  async setApplicationMenu(items: MenuItem[]): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'menu_set_application_menu', items });
    return r.success === true;
  },

  async resetApplicationMenu(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'menu_reset_application_menu' });
    return r.success === true;
  },
};

// ============================================
// globalShortcut — macOS Carbon Hot Key (Electron `globalShortcut.*`)
// ============================================

export const globalShortcut = {
  async register(accelerator: string, click: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'global_shortcut_register', accelerator, click });
    return r.success === true;
  },

  async unregister(accelerator: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'global_shortcut_unregister', accelerator });
    return r.success === true;
  },

  async unregisterAll(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'global_shortcut_unregister_all' });
    return r.success === true;
  },

  async isRegistered(accelerator: string): Promise<boolean> {
    const r = await invoke<{ registered: boolean }>('__core__', { cmd: 'global_shortcut_is_registered', accelerator });
    return r.registered === true;
  },
};

// Dialog 옵션 타입은 frontend `@suji/api`와 동일.
export type MessageBoxStyle = 'none' | 'info' | 'warning' | 'error' | 'question';

export interface MessageBoxOptions {
  windowId?: number;        // 지정 시 sheet (해당 창 attach), 없으면 free-floating.
  type?: MessageBoxStyle;
  title?: string;
  message: string;
  detail?: string;
  buttons?: string[];
  defaultId?: number;
  cancelId?: number;
  checkboxLabel?: string;
  checkboxChecked?: boolean;
}

export interface FileFilter {
  name: string;
  extensions: string[];
}

export type OpenDialogProperty =
  | 'openFile' | 'openDirectory' | 'multiSelections' | 'showHiddenFiles'
  | 'createDirectory' | 'noResolveAliases' | 'treatPackageAsDirectory';

export interface OpenDialogOptions {
  windowId?: number;
  title?: string;
  defaultPath?: string;
  buttonLabel?: string;
  message?: string;
  filters?: FileFilter[];
  properties?: OpenDialogProperty[];
}

export type SaveDialogProperty =
  | 'showHiddenFiles' | 'createDirectory' | 'treatPackageAsDirectory';

export interface SaveDialogOptions {
  windowId?: number;
  title?: string;
  defaultPath?: string;
  buttonLabel?: string;
  message?: string;
  nameFieldLabel?: string;
  showsTagField?: boolean;
  filters?: FileFilter[];
  properties?: SaveDialogProperty[];
}

export const dialog = {
  /** 메시지 박스. windowId 지정 시 sheet, 아니면 free-floating. */
  showMessageBox(
    options: MessageBoxOptions,
  ): Promise<{ response: number; checkboxChecked: boolean }> {
    return invoke<{ response: number; checkboxChecked: boolean }>('__core__', {
      cmd: 'dialog_show_message_box',
      ...options,
    });
  },

  async showErrorBox(title: string, content: string): Promise<void> {
    await invoke('__core__', { cmd: 'dialog_show_error_box', title, content });
  },

  showOpenDialog(
    options: OpenDialogOptions = {},
  ): Promise<{ canceled: boolean; filePaths: string[] }> {
    return invoke<{ canceled: boolean; filePaths: string[] }>('__core__', {
      cmd: 'dialog_show_open_dialog',
      ...options,
    });
  },

  showSaveDialog(
    options: SaveDialogOptions = {},
  ): Promise<{ canceled: boolean; filePath: string }> {
    return invoke<{ canceled: boolean; filePath: string }>('__core__', {
      cmd: 'dialog_show_save_dialog',
      ...options,
    });
  },
};

// ============================================
// screen / powerSaveBlocker / safeStorage / app — Frontend `@suji/api`와 동일 cmd.
// ============================================

export interface Display {
  index: number;
  isPrimary: boolean;
  x: number;
  y: number;
  width: number;
  height: number;
  visibleX: number;
  visibleY: number;
  visibleWidth: number;
  visibleHeight: number;
  scaleFactor: number;
}

export const screen = {
  /** 연결된 모든 모니터의 bounds/scale 정보. macOS NSScreen 기반. */
  async getAllDisplays(): Promise<Display[]> {
    const r = await invoke<{ displays: Display[] }>('__core__', { cmd: 'screen_get_all_displays' });
    return r.displays;
  },
};

export const webRequest = {
  /** URL glob blocklist 등록 (Electron `session.webRequest`). `*` wildcard만 지원.
   *  최대 32개/256자per. 빈 list 호출 시 모든 패턴 제거. */
  async setBlockedUrls(patterns: string[]): Promise<number> {
    const r = await invoke<{ count: number }>('__core__', { cmd: 'web_request_set_blocked_urls', patterns });
    return r.count;
  },

  /** dynamic listener filter. 매칭 요청은 RV_CONTINUE_ASYNC + webRequest:will-request 이벤트.
   *  consumer가 resolve(id, cancel) 호출 전까지 hold. */
  async setListenerFilter(patterns: string[]): Promise<number> {
    const r = await invoke<{ count: number }>('__core__', { cmd: 'web_request_set_listener_filter', patterns });
    return r.count;
  },

  /** pending 요청 결정 (Electron callback). cancel=true면 차단, false면 통과. */
  async resolve(id: number, cancel: boolean): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'web_request_resolve', id, cancel });
    return r.success === true;
  },
};

export type PowerSaveBlockerType = 'prevent_app_suspension' | 'prevent_display_sleep';

export const powerSaveBlocker = {
  /** sleep 차단 시작. 반환된 id로 stop. 0이면 실패. */
  async start(type: PowerSaveBlockerType): Promise<number> {
    const r = await invoke<{ id: number }>('__core__', { cmd: 'power_save_blocker_start', type });
    return r.id;
  },

  /** start로 받은 id 해제. unknown id는 false. */
  async stop(id: number): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'power_save_blocker_stop', id });
    return r.success === true;
  },
};

export const safeStorage = {
  /** macOS Keychain에 utf-8 value 저장. 같은 키면 update (idempotent). */
  async setItem(service: string, account: string, value: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', {
      cmd: 'safe_storage_set', service, account, value,
    });
    return r.success === true;
  },

  /** 응답: 없으면 빈 문자열. */
  async getItem(service: string, account: string): Promise<string> {
    const r = await invoke<{ value: string }>('__core__', {
      cmd: 'safe_storage_get', service, account,
    });
    return r.value;
  },

  /** 없는 키도 idempotent true. */
  async deleteItem(service: string, account: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', {
      cmd: 'safe_storage_delete', service, account,
    });
    return r.success === true;
  },
};

export type AppPathName =
  | 'home'
  | 'appData'
  | 'userData'
  | 'temp'
  | 'desktop'
  | 'documents'
  | 'downloads';

export const app = {
  /** Electron `app.getPath` 동등. unknown 키는 빈 문자열. */
  async getPath(name: AppPathName): Promise<string> {
    const r = await invoke<{ path: string }>('__core__', { cmd: 'app_get_path', name });
    return r.path;
  },

  /** dock 아이콘 바운스 시작. 0이면 no-op (앱이 이미 active). 아니면 cancel용 id. */
  async requestUserAttention(critical = true): Promise<number> {
    const r = await invoke<{ id: number }>('__core__', { cmd: 'app_attention_request', critical });
    return r.id;
  },

  /** id == 0은 false (guard). */
  async cancelUserAttentionRequest(id: number): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'app_attention_cancel', id });
    return r.success === true;
  },

  dock: {
    /** dock 배지 텍스트 — 빈 문자열로 제거. macOS만. */
    async setBadge(text: string): Promise<void> {
      await invoke('__core__', { cmd: 'dock_set_badge', text });
    },

    /** 현재 배지 텍스트. 미설정이면 빈 문자열. */
    async getBadge(): Promise<string> {
      const r = await invoke<{ text: string }>('__core__', { cmd: 'dock_get_badge' });
      return r.text;
    },
  },
};
