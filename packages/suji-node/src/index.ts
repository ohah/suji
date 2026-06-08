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
 * declaration merging으로 채우면 invoke/invokeSync/call/callSync가 cmd/req/res를 추론.
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

type HandlerReq<K extends keyof SujiHandlers & string> =
  SujiHandlers[K] extends { req: infer R } ? R : unknown;

type HandlerRes<K extends keyof SujiHandlers & string> =
  SujiHandlers[K] extends { res: infer R } ? R : unknown;

type NoContextInfer<T> = [T][T extends any ? 0 : never];

type InvokeRequestForHandler<K extends keyof SujiHandlers & string> =
  [HandlerReq<K>] extends [void | undefined]
    ? { cmd: K }
    : HandlerReq<K> extends object
      ? { cmd: K } & HandlerReq<K>
      : { cmd: K; data: HandlerReq<K> };

function requestWithCmd<K extends keyof SujiHandlers & string>(
  cmd: K,
  data: HandlerReq<K> | undefined,
): InvokeRequestForHandler<K> {
  if (data === undefined) return { cmd } as InvokeRequestForHandler<K>;
  if (data !== null && typeof data === 'object') {
    return { cmd, ...(data as object) } as InvokeRequestForHandler<K>;
  }
  return { cmd, data } as InvokeRequestForHandler<K>;
}

/**
 * 다른 백엔드 비동기 호출 (Promise 반환, event loop 비블록).
 * request.cmd가 SujiHandlers에 등록된 cmd면 req/res를 추론하고, 아니면 기존 generic
 * fallback(`invoke<T>`)으로 동작한다. 핸들러 안에서는 invokeSync 권장.
 *
 * @example
 * const result = await invoke('zig', { cmd: 'ping' }); // 등록된 ping이면 res 추론
 */
export function invoke<K extends keyof SujiHandlers & string>(
  backend: string,
  request: InvokeRequestForHandler<K>,
): Promise<HandlerRes<K>>;
export function invoke<T = unknown>(
  backend: string,
  request?: Record<string, unknown>,
): Promise<NoContextInfer<T>>;
export async function invoke<T = unknown>(
  backend: string,
  request: unknown = {},
): Promise<T> {
  const raw = await getBridge().invoke(backend, JSON.stringify(request));
  try {
    return JSON.parse(raw) as T;
  } catch {
    return raw as unknown as T;
  }
}

/**
 * 다른 백엔드 동기 호출 (핸들러 내부용). request.cmd가 SujiHandlers에 등록된
 * cmd면 req/res를 추론하고, 아니면 기존 generic fallback(`invokeSync<T>`)으로 동작한다.
 *
 * event loop을 블록하므로 핸들러 안에서만 사용할 것.
 *
 * @example
 * handle('call-zig', () => {
 *   const result = invokeSync('zig', { cmd: 'ping' });
 *   return { from: 'node', result };
 * });
 */
export function invokeSync<K extends keyof SujiHandlers & string>(
  backend: string,
  request: InvokeRequestForHandler<K>,
): HandlerRes<K>;
export function invokeSync<T = unknown>(
  backend: string,
  request?: Record<string, unknown>,
): NoContextInfer<T>;
export function invokeSync<T = unknown>(
  backend: string,
  request: unknown = {},
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
  [HandlerReq<K>] extends [void | undefined]
    ? []
    : [data: HandlerReq<K>];

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
): Promise<HandlerRes<K>> {
  const data = args[0];
  return invoke(backend, requestWithCmd(cmd, data));
}

/** sync 변형 — 핸들러 내부용. */
export function callSync<K extends keyof SujiHandlers & string>(
  backend: string,
  cmd: K,
  ...args: CallArgs<K>
): HandlerRes<K> {
  const data = args[0];
  return invokeSync(backend, requestWithCmd(cmd, data));
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

export interface GetUserAgentResponse extends WindowOpResponse {
  cmd: 'get_user_agent';
  userAgent: string | null;
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

export interface IsAudioMutedResponse extends WindowOpResponse {
  cmd: 'is_audio_muted';
  muted: boolean;
}

export interface OpacityResponse extends WindowOpResponse {
  cmd: 'get_opacity';
  opacity: number;
}

export interface HasShadowResponse extends WindowOpResponse {
  cmd: 'has_shadow';
  hasShadow: boolean;
}
export interface IsMinimizedResponse extends WindowOpResponse {
  cmd: 'is_minimized';
  minimized: boolean;
}
export interface IsMaximizedResponse extends WindowOpResponse {
  cmd: 'is_maximized';
  maximized: boolean;
}
export interface IsResizableResponse extends WindowOpResponse {
  cmd: 'is_resizable';
  resizable: boolean;
}
export interface IsMinimizableResponse extends WindowOpResponse {
  cmd: 'is_minimizable';
  minimizable: boolean;
}
export interface IsMaximizableResponse extends WindowOpResponse {
  cmd: 'is_maximizable';
  maximizable: boolean;
}
export interface IsClosableResponse extends WindowOpResponse {
  cmd: 'is_closable';
  closable: boolean;
}
export interface IsMovableResponse extends WindowOpResponse {
  cmd: 'is_movable';
  movable: boolean;
}
export interface IsFocusableResponse extends WindowOpResponse {
  cmd: 'is_focusable';
  focusable: boolean;
}
export interface IsEnabledResponse extends WindowOpResponse {
  cmd: 'is_enabled';
  enabled: boolean;
}
export interface IsFullScreenableResponse extends WindowOpResponse {
  cmd: 'is_fullscreenable';
  fullscreenable: boolean;
}
export interface IsKioskResponse extends WindowOpResponse {
  cmd: 'is_kiosk';
  kiosk: boolean;
}
export interface IsFullScreenResponse extends WindowOpResponse {
  cmd: 'is_fullscreen';
  fullscreen: boolean;
}
export interface IsNormalResponse extends WindowOpResponse {
  cmd: 'is_normal';
  /** minimized/maximized/fullscreen 모두 아닌 일반 상태 */
  normal: boolean;
}
export interface BoundsResponse extends WindowOpResponse {
  cmd: 'get_bounds';
  /** 화면 좌표(top-left 원점) */
  x: number;
  y: number;
  width: number;
  height: number;
}
export interface IsFocusedResponse extends WindowOpResponse {
  cmd: 'is_focused';
  focused: boolean;
}
export interface IsVisibleResponse extends WindowOpResponse {
  cmd: 'is_visible';
  visible: boolean;
}
export interface IsAlwaysOnTopResponse extends WindowOpResponse {
  cmd: 'is_always_on_top';
  alwaysOnTop: boolean;
}
export interface GetAllWindowsResponse {
  from: 'zig-core';
  cmd: 'get_all_windows';
  ok: boolean;
  /** 살아있는 top-level 창 id (WebContentsView 제외) */
  windowIds: number[];
}
export interface GetFocusedWindowResponse {
  from: 'zig-core';
  cmd: 'get_focused_window';
  ok: boolean;
  /** 포커스된 창 id, 없으면 null */
  windowId: number | null;
}

export interface SetBoundsArgs {
  x?: number;
  y?: number;
  width?: number;
  height?: number;
}

export interface CreateViewOptions extends SetBoundsArgs {
  hostId: number;
  name?: string;
  url?: string;
}

export type HostCreateViewOptions = Omit<CreateViewOptions, 'hostId'>;

export interface CreateViewResponse {
  cmd: 'create_view';
  from: 'zig-core';
  viewId: number;
}

export interface ViewOpResponse {
  cmd: string;
  from: 'zig-core';
  viewId: number;
  ok: boolean;
}

export interface GetChildViewsResponse {
  cmd: 'get_child_views';
  from: 'zig-core';
  hostId: number;
  ok: boolean;
  viewIds: number[];
}

/** deferred-response(printToPDF/capturePage) defense-in-depth 타임아웃. 코어
 *  TTL(30s) 보다 여유 둔 35s 후 {success:false} resolve — 코어가 끝내 응답 못
 *  보내는 극단(렌더러/GPU 크래시) 에서도 Promise hang 방지. 코어 늦은 응답 무해. */
function withDeferTimeout<T extends { success?: boolean }>(p: Promise<T>, timeoutMs?: number): Promise<T> {
  const ms = timeoutMs ?? 35_000;
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<T>((resolve) => {
    timer = setTimeout(() => resolve({ success: false } as T), ms);
  });
  // race 승자 결정 후 clearTimeout — 호출당 dangling 35s 타이머 누수 방지.
  return Promise.race([p, timeout]).finally(() => clearTimeout(timer));
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
  /** UA 동적 변경 (Electron `webContents.setUserAgent`, CDP override). */
  setUserAgent(windowId: number, userAgent: string): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_user_agent', windowId, userAgent });
  },
  /** 설정한 UA override 조회. 미설정 시 userAgent=null. */
  getUserAgent(windowId: number): Promise<GetUserAgentResponse> {
    return invoke<GetUserAgentResponse>('__core__', { cmd: 'get_user_agent', windowId });
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
  createView(opts: CreateViewOptions): Promise<CreateViewResponse> {
    return invoke<CreateViewResponse>('__core__', { cmd: 'create_view', ...opts });
  },
  destroyView(viewId: number): Promise<ViewOpResponse> {
    return invoke<ViewOpResponse>('__core__', { cmd: 'destroy_view', viewId });
  },
  addChildView(hostId: number, viewId: number, index?: number): Promise<ViewOpResponse> {
    return invoke<ViewOpResponse>('__core__', {
      cmd: 'add_child_view',
      hostId,
      viewId,
      ...(index === undefined ? {} : { index }),
    });
  },
  removeChildView(hostId: number, viewId: number): Promise<ViewOpResponse> {
    return invoke<ViewOpResponse>('__core__', { cmd: 'remove_child_view', hostId, viewId });
  },
  setTopView(hostId: number, viewId: number): Promise<ViewOpResponse> {
    return invoke<ViewOpResponse>('__core__', { cmd: 'set_top_view', hostId, viewId });
  },
  setViewBounds(viewId: number, bounds: SetBoundsArgs): Promise<ViewOpResponse> {
    return invoke<ViewOpResponse>('__core__', { cmd: 'set_view_bounds', viewId, ...bounds });
  },
  setViewVisible(viewId: number, visible: boolean): Promise<ViewOpResponse> {
    return invoke<ViewOpResponse>('__core__', { cmd: 'set_view_visible', viewId, visible });
  },
  getChildViews(hostId: number): Promise<GetChildViewsResponse> {
    return invoke<GetChildViewsResponse>('__core__', { cmd: 'get_child_views', hostId });
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

  /** 창 오디오 mute (Electron `webContents.setAudioMuted`). */
  setAudioMuted(windowId: number, muted: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_audio_muted', windowId, muted });
  },

  /** 창 오디오 mute 상태 (Electron `webContents.isAudioMuted`). */
  isAudioMuted(windowId: number): Promise<IsAudioMutedResponse> {
    return invoke<IsAudioMutedResponse>('__core__', { cmd: 'is_audio_muted', windowId });
  },

  /** 창 투명도 (0~1). Electron `BrowserWindow.setOpacity`. */
  setOpacity(windowId: number, opacity: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_opacity', windowId, opacity });
  },

  getOpacity(windowId: number): Promise<OpacityResponse> {
    return invoke<OpacityResponse>('__core__', { cmd: 'get_opacity', windowId });
  },

  /** 배경색 (`#RRGGBB` 또는 `#RRGGBBAA`). */
  setBackgroundColor(windowId: number, color: string): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_background_color', windowId, color });
  },

  setHasShadow(windowId: number, hasShadow: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_has_shadow', windowId, hasShadow });
  },

  hasShadow(windowId: number): Promise<HasShadowResponse> {
    return invoke<HasShadowResponse>('__core__', { cmd: 'has_shadow', windowId });
  },

  // ── 창 생명주기 (Electron BrowserWindow 패리티 — Zig 백엔드 기존 구현 노출) ──
  minimize(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'minimize', windowId });
  },
  maximize(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'maximize', windowId });
  },
  unmaximize(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'unmaximize', windowId });
  },
  restore(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'restore_window', windowId });
  },
  show(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_visible', windowId, visible: true });
  },
  hide(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_visible', windowId, visible: false });
  },
  close(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'destroy_window', windowId });
  },
  /** 강제 파괴 (Electron `BrowserWindow.destroy`). `window:close`(취소 hook) 스킵, `window:closed` 만. */
  destroy(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'destroy_window_force', windowId });
  },
  setFullScreen(windowId: number, flag: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_fullscreen', windowId, flag });
  },
  isMinimized(windowId: number): Promise<IsMinimizedResponse> {
    return invoke<IsMinimizedResponse>('__core__', { cmd: 'is_minimized', windowId });
  },
  isMaximized(windowId: number): Promise<IsMaximizedResponse> {
    return invoke<IsMaximizedResponse>('__core__', { cmd: 'is_maximized', windowId });
  },
  isFullScreen(windowId: number): Promise<IsFullScreenResponse> {
    return invoke<IsFullScreenResponse>('__core__', { cmd: 'is_fullscreen', windowId });
  },
  /** Electron BrowserWindow.focus() — 창을 포그라운드로 키 창으로. */
  focus(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'focus', windowId });
  },
  /** Electron BrowserWindow.isNormal() — minimized/maximized/fullscreen 모두 아님. */
  isNormal(windowId: number): Promise<IsNormalResponse> {
    return invoke<IsNormalResponse>('__core__', { cmd: 'is_normal', windowId });
  },
  /** Electron BrowserWindow.getBounds() — {x,y,width,height} (top-left 원점). */
  getBounds(windowId: number): Promise<BoundsResponse> {
    return invoke<BoundsResponse>('__core__', { cmd: 'get_bounds', windowId });
  },
  /** Electron BrowserWindow.getSize() — [width, height]. getBounds 에서 파생. */
  async getSize(windowId: number): Promise<[number, number]> {
    const b = await windows.getBounds(windowId);
    return [b.width, b.height];
  },
  /** Electron BrowserWindow.getPosition() — [x, y]. getBounds 에서 파생. */
  async getPosition(windowId: number): Promise<[number, number]> {
    const b = await windows.getBounds(windowId);
    return [b.x, b.y];
  },
  /** Electron BrowserWindow.getContentBounds() — 콘텐츠 영역(프레임/타이틀바 제외). */
  getContentBounds(windowId: number): Promise<BoundsResponse> {
    return invoke<BoundsResponse>('__core__', { cmd: 'get_content_bounds', windowId });
  },
  /** Electron BrowserWindow.setContentBounds() — 콘텐츠 영역을 지정 사각형으로. */
  setContentBounds(windowId: number, bounds: SetBoundsArgs): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_content_bounds', windowId, ...bounds });
  },
  /** Electron BrowserWindow.getContentSize() — [width, height]. getContentBounds 에서 파생. */
  async getContentSize(windowId: number): Promise<[number, number]> {
    const b = await windows.getContentBounds(windowId);
    return [b.width, b.height];
  },
  /** Electron BrowserWindow.setSize(width, height) — 위치 유지(getBounds→setBounds 파생).
   *  `animate` 는 받되 무시(CEF Views set_bounds 비애니메이션). */
  async setSize(
    windowId: number,
    width: number,
    height: number,
    _animate?: boolean,
  ): Promise<WindowOpResponse> {
    const b = await windows.getBounds(windowId);
    if (!b.ok) return b; // getBounds 실패(창 없음) → 0,0 으로 이동 방지
    return windows.setBounds(windowId, { x: b.x, y: b.y, width, height });
  },
  /** Electron BrowserWindow.setPosition(x, y) — 크기 유지. `animate` 무시. */
  async setPosition(
    windowId: number,
    x: number,
    y: number,
    _animate?: boolean,
  ): Promise<WindowOpResponse> {
    const b = await windows.getBounds(windowId);
    if (!b.ok) return b; // getBounds 실패 → 0 크기로 collapse 방지
    return windows.setBounds(windowId, { x, y, width: b.width, height: b.height });
  },
  /** Electron BrowserWindow.setMinimumSize(width, height). 0 = 제한 없음. */
  setMinimumSize(windowId: number, width: number, height: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_minimum_size', windowId, width, height });
  },
  /** Electron BrowserWindow.getMinimumSize() — [width, height] (추적된 제약값, 0=없음). */
  async getMinimumSize(windowId: number): Promise<[number, number]> {
    const r = await invoke<{ width: number; height: number }>('__core__', { cmd: 'get_minimum_size', windowId });
    return [r.width, r.height];
  },
  /** Electron BrowserWindow.setMaximumSize(width, height). 0 = 제한 없음. */
  setMaximumSize(windowId: number, width: number, height: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_maximum_size', windowId, width, height });
  },
  /** Electron BrowserWindow.getMaximumSize() — [width, height] (추적된 제약값, 0=없음). */
  async getMaximumSize(windowId: number): Promise<[number, number]> {
    const r = await invoke<{ width: number; height: number }>('__core__', { cmd: 'get_maximum_size', windowId });
    return [r.width, r.height];
  },
  /** Electron BrowserWindow.setResizable(resizable). */
  setResizable(windowId: number, resizable: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_resizable', windowId, resizable });
  },
  /** Electron BrowserWindow.isResizable(). */
  isResizable(windowId: number): Promise<IsResizableResponse> {
    return invoke<IsResizableResponse>('__core__', { cmd: 'is_resizable', windowId });
  },
  /** Electron BrowserWindow.setMinimizable(minimizable). */
  setMinimizable(windowId: number, minimizable: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_minimizable', windowId, minimizable });
  },
  /** Electron BrowserWindow.isMinimizable(). */
  isMinimizable(windowId: number): Promise<IsMinimizableResponse> {
    return invoke<IsMinimizableResponse>('__core__', { cmd: 'is_minimizable', windowId });
  },
  /** Electron BrowserWindow.setMaximizable(maximizable). */
  setMaximizable(windowId: number, maximizable: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_maximizable', windowId, maximizable });
  },
  /** Electron BrowserWindow.isMaximizable(). */
  isMaximizable(windowId: number): Promise<IsMaximizableResponse> {
    return invoke<IsMaximizableResponse>('__core__', { cmd: 'is_maximizable', windowId });
  },
  /** Electron BrowserWindow.setClosable(closable). */
  setClosable(windowId: number, closable: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_closable', windowId, closable });
  },
  /** Electron BrowserWindow.isClosable(). */
  isClosable(windowId: number): Promise<IsClosableResponse> {
    return invoke<IsClosableResponse>('__core__', { cmd: 'is_closable', windowId });
  },
  /** Electron BrowserWindow.setMovable(movable). macOS NSWindow.movable, 그 외 tracked. */
  setMovable(windowId: number, movable: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_movable', windowId, movable });
  },
  isMovable(windowId: number): Promise<IsMovableResponse> {
    return invoke<IsMovableResponse>('__core__', { cmd: 'is_movable', windowId });
  },
  /** Electron BrowserWindow.setFocusable(focusable). tracked(best-effort). */
  setFocusable(windowId: number, focusable: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_focusable', windowId, focusable });
  },
  isFocusable(windowId: number): Promise<IsFocusableResponse> {
    return invoke<IsFocusableResponse>('__core__', { cmd: 'is_focusable', windowId });
  },
  /** Electron BrowserWindow.setEnabled(enable). Win32 EnableWindow / macOS ignoresMouseEvents(마우스). */
  setEnabled(windowId: number, enabled: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_enabled', windowId, enabled });
  },
  isEnabled(windowId: number): Promise<IsEnabledResponse> {
    return invoke<IsEnabledResponse>('__core__', { cmd: 'is_enabled', windowId });
  },
  /** Electron BrowserWindow.setFullScreenable(flag). macOS collectionBehavior, 그 외 tracked. */
  setFullScreenable(windowId: number, fullscreenable: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_fullscreenable', windowId, fullscreenable });
  },
  isFullScreenable(windowId: number): Promise<IsFullScreenableResponse> {
    return invoke<IsFullScreenableResponse>('__core__', { cmd: 'is_fullscreenable', windowId });
  },
  /** Electron BrowserWindow.setKiosk(flag). best-effort: 전체화면(presentation-options 미포함). */
  setKiosk(windowId: number, flag: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_kiosk', windowId, kiosk: flag });
  },
  isKiosk(windowId: number): Promise<IsKioskResponse> {
    return invoke<IsKioskResponse>('__core__', { cmd: 'is_kiosk', windowId });
  },
  /** Electron BrowserWindow.blur() — 창 포커스 해제. */
  blur(windowId: number): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'blur', windowId });
  },
  /** Electron BrowserWindow.isFocused(). */
  isFocused(windowId: number): Promise<IsFocusedResponse> {
    return invoke<IsFocusedResponse>('__core__', { cmd: 'is_focused', windowId });
  },
  /** Electron BrowserWindow.isVisible(). */
  isVisible(windowId: number): Promise<IsVisibleResponse> {
    return invoke<IsVisibleResponse>('__core__', { cmd: 'is_visible', windowId });
  },
  /** Electron BrowserWindow.setAlwaysOnTop(flag). */
  setAlwaysOnTop(windowId: number, flag: boolean): Promise<WindowOpResponse> {
    return invoke<WindowOpResponse>('__core__', { cmd: 'set_always_on_top', windowId, onTop: flag });
  },
  /** Electron BrowserWindow.isAlwaysOnTop(). */
  isAlwaysOnTop(windowId: number): Promise<IsAlwaysOnTopResponse> {
    return invoke<IsAlwaysOnTopResponse>('__core__', { cmd: 'is_always_on_top', windowId });
  },
  /** Electron BrowserWindow.getAllWindows() — 살아있는 top-level 창 id (view 제외). */
  getAllWindows(): Promise<GetAllWindowsResponse> {
    return invoke<GetAllWindowsResponse>('__core__', { cmd: 'get_all_windows' });
  },
  /** Electron BrowserWindow.getFocusedWindow() — 포커스 창 id 또는 null. */
  getFocusedWindow(): Promise<GetFocusedWindowResponse> {
    return invoke<GetFocusedWindowResponse>('__core__', { cmd: 'get_focused_window' });
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

  /** PDF 인쇄. 코어가 CDP 완료까지 응답 보류 → 단일 await 로 `{success}` 받음.
   *  EventBus `window:pdf-print-finished` emit 은 다른 구독자 호환 유지.
   *  defense-in-depth 타임아웃(기본 35s)으로 극단 hang 방지. */
  async printToPDF(windowId: number, path: string, opts?: { timeoutMs?: number }): Promise<{ success: boolean }> {
    const r = await withDeferTimeout(
      invoke<{ success?: boolean }>('__core__', { cmd: 'print_to_pdf', windowId, path }),
      opts?.timeoutMs,
    );
    return { success: r?.success === true };
  },

  /** 페이지 스크린샷 PNG 저장. 코어 deferred response 로 단일 await. */
  async capturePage(
    windowId: number,
    path: string,
    rect?: { x: number; y: number; width: number; height: number },
    opts?: { timeoutMs?: number },
  ): Promise<{ success: boolean }> {
    const r = await withDeferTimeout(
      invoke<{ success?: boolean }>('__core__', {
        cmd: 'capture_page', windowId, path,
        ...(rect ? { clipX: rect.x, clipY: rect.y, clipWidth: rect.width, clipHeight: rect.height } : {}),
      }),
      opts?.timeoutMs,
    );
    return { success: r?.success === true };
  },
};

/**
 * `windows.*`(raw windowId)의 객체지향 facade (Electron `BrowserWindow`
 * 패리티, @suji/api 와 동형). 각 메서드는 `windows.<fn>(this.id,...)` 위임
 * — 로직/응답 타입 무중복(반환 타입 위임 추론, windows 변경 자동 동기화).
 */
export class BrowserWindow {
  readonly #id: number;
  private constructor(id: number) {
    this.#id = id;
  }
  /** 후속 IPC/sendTo 및 view host 인자로 쓰는 창 id. */
  get id(): number {
    return this.#id;
  }

  /** 새 창 생성 후 인스턴스 반환 (Electron `new BrowserWindow(opts)`). */
  static async create(opts: WindowOptions = {}): Promise<BrowserWindow> {
    const res = await windows.create(opts);
    // windowId 부재 시 좀비 인스턴스 방지 — Rust None / Go error 와 시맨틱 일치.
    if (typeof res.windowId !== "number") {
      throw new Error(`create_window: no windowId in response (${JSON.stringify(res)})`);
    }
    return new BrowserWindow(res.windowId);
  }
  /** 기존 windowId(메인 창/이벤트 sender)를 인스턴스로 래핑. */
  static fromId(id: number): BrowserWindow {
    return new BrowserWindow(id);
  }
  /** Electron BrowserWindow.getAllWindows() — 살아있는 top-level 창 인스턴스 배열. */
  static async getAllWindows(): Promise<BrowserWindow[]> {
    const r = await windows.getAllWindows();
    return r.windowIds.map((id) => BrowserWindow.fromId(id));
  }
  /** Electron BrowserWindow.getFocusedWindow() — 포커스 창 인스턴스 또는 null. */
  static async getFocusedWindow(): Promise<BrowserWindow | null> {
    const r = await windows.getFocusedWindow();
    return r.windowId == null ? null : BrowserWindow.fromId(r.windowId);
  }

  loadURL(url: string) {
    return windows.loadURL(this.#id, url);
  }
  reload(ignoreCache = false) {
    return windows.reload(this.#id, ignoreCache);
  }
  executeJavaScript(code: string) {
    return windows.executeJavaScript(this.#id, code);
  }
  getURL() {
    return windows.getURL(this.#id);
  }
  setUserAgent(userAgent: string) {
    return windows.setUserAgent(this.#id, userAgent);
  }
  getUserAgent() {
    return windows.getUserAgent(this.#id);
  }
  isLoading() {
    return windows.isLoading(this.#id);
  }
  setTitle(title: string) {
    return windows.setTitle(this.#id, title);
  }
  setBounds(bounds: SetBoundsArgs) {
    return windows.setBounds(this.#id, bounds);
  }
  createView(opts: HostCreateViewOptions = {}) {
    return windows.createView({ hostId: this.#id, ...opts });
  }
  destroyView(viewId: number) {
    return windows.destroyView(viewId);
  }
  addChildView(viewId: number, index?: number) {
    return windows.addChildView(this.#id, viewId, index);
  }
  removeChildView(viewId: number) {
    return windows.removeChildView(this.#id, viewId);
  }
  setTopView(viewId: number) {
    return windows.setTopView(this.#id, viewId);
  }
  setViewBounds(viewId: number, bounds: SetBoundsArgs) {
    return windows.setViewBounds(viewId, bounds);
  }
  setViewVisible(viewId: number, visible: boolean) {
    return windows.setViewVisible(viewId, visible);
  }
  getChildViews() {
    return windows.getChildViews(this.#id);
  }
  openDevTools() {
    return windows.openDevTools(this.#id);
  }
  closeDevTools() {
    return windows.closeDevTools(this.#id);
  }
  isDevToolsOpened() {
    return windows.isDevToolsOpened(this.#id);
  }
  toggleDevTools() {
    return windows.toggleDevTools(this.#id);
  }
  setZoomLevel(level: number) {
    return windows.setZoomLevel(this.#id, level);
  }
  getZoomLevel() {
    return windows.getZoomLevel(this.#id);
  }
  setZoomFactor(factor: number) {
    return windows.setZoomFactor(this.#id, factor);
  }
  getZoomFactor() {
    return windows.getZoomFactor(this.#id);
  }
  setAudioMuted(muted: boolean) {
    return windows.setAudioMuted(this.#id, muted);
  }
  isAudioMuted() {
    return windows.isAudioMuted(this.#id);
  }
  setOpacity(opacity: number) {
    return windows.setOpacity(this.#id, opacity);
  }
  getOpacity() {
    return windows.getOpacity(this.#id);
  }
  setBackgroundColor(color: string) {
    return windows.setBackgroundColor(this.#id, color);
  }
  setHasShadow(hasShadow: boolean) {
    return windows.setHasShadow(this.#id, hasShadow);
  }
  hasShadow() {
    return windows.hasShadow(this.#id);
  }
  // ── 창 생명주기 (Electron BrowserWindow 패리티) ──
  minimize() {
    return windows.minimize(this.#id);
  }
  maximize() {
    return windows.maximize(this.#id);
  }
  unmaximize() {
    return windows.unmaximize(this.#id);
  }
  restore() {
    return windows.restore(this.#id);
  }
  show() {
    return windows.show(this.#id);
  }
  hide() {
    return windows.hide(this.#id);
  }
  close() {
    return windows.close(this.#id);
  }
  /** 강제 파괴 (Electron `BrowserWindow.destroy`) — `window:close` 스킵, `window:closed` 만. */
  destroy() {
    return windows.destroy(this.#id);
  }
  setFullScreen(flag: boolean) {
    return windows.setFullScreen(this.#id, flag);
  }
  isMinimized() {
    return windows.isMinimized(this.#id);
  }
  isMaximized() {
    return windows.isMaximized(this.#id);
  }
  isFullScreen() {
    return windows.isFullScreen(this.#id);
  }
  focus() {
    return windows.focus(this.#id);
  }
  isNormal() {
    return windows.isNormal(this.#id);
  }
  getBounds() {
    return windows.getBounds(this.#id);
  }
  getSize() {
    return windows.getSize(this.#id);
  }
  getPosition() {
    return windows.getPosition(this.#id);
  }
  getContentBounds() {
    return windows.getContentBounds(this.#id);
  }
  setContentBounds(bounds: SetBoundsArgs) {
    return windows.setContentBounds(this.#id, bounds);
  }
  getContentSize() {
    return windows.getContentSize(this.#id);
  }
  setSize(width: number, height: number, animate?: boolean) {
    return windows.setSize(this.#id, width, height, animate);
  }
  setPosition(x: number, y: number, animate?: boolean) {
    return windows.setPosition(this.#id, x, y, animate);
  }
  setMinimumSize(width: number, height: number) {
    return windows.setMinimumSize(this.#id, width, height);
  }
  getMinimumSize() {
    return windows.getMinimumSize(this.#id);
  }
  setMaximumSize(width: number, height: number) {
    return windows.setMaximumSize(this.#id, width, height);
  }
  getMaximumSize() {
    return windows.getMaximumSize(this.#id);
  }
  setResizable(resizable: boolean) {
    return windows.setResizable(this.#id, resizable);
  }
  isResizable() {
    return windows.isResizable(this.#id);
  }
  setMinimizable(minimizable: boolean) {
    return windows.setMinimizable(this.#id, minimizable);
  }
  isMinimizable() {
    return windows.isMinimizable(this.#id);
  }
  setMaximizable(maximizable: boolean) {
    return windows.setMaximizable(this.#id, maximizable);
  }
  isMaximizable() {
    return windows.isMaximizable(this.#id);
  }
  setClosable(closable: boolean) {
    return windows.setClosable(this.#id, closable);
  }
  isClosable() {
    return windows.isClosable(this.#id);
  }
  setMovable(movable: boolean) {
    return windows.setMovable(this.#id, movable);
  }
  isMovable() {
    return windows.isMovable(this.#id);
  }
  setFocusable(focusable: boolean) {
    return windows.setFocusable(this.#id, focusable);
  }
  isFocusable() {
    return windows.isFocusable(this.#id);
  }
  setEnabled(enabled: boolean) {
    return windows.setEnabled(this.#id, enabled);
  }
  isEnabled() {
    return windows.isEnabled(this.#id);
  }
  setFullScreenable(fullscreenable: boolean) {
    return windows.setFullScreenable(this.#id, fullscreenable);
  }
  isFullScreenable() {
    return windows.isFullScreenable(this.#id);
  }
  setKiosk(flag: boolean) {
    return windows.setKiosk(this.#id, flag);
  }
  isKiosk() {
    return windows.isKiosk(this.#id);
  }
  blur() {
    return windows.blur(this.#id);
  }
  isFocused() {
    return windows.isFocused(this.#id);
  }
  isVisible() {
    return windows.isVisible(this.#id);
  }
  setAlwaysOnTop(flag: boolean) {
    return windows.setAlwaysOnTop(this.#id, flag);
  }
  isAlwaysOnTop() {
    return windows.isAlwaysOnTop(this.#id);
  }
  undo() {
    return windows.undo(this.#id);
  }
  redo() {
    return windows.redo(this.#id);
  }
  cut() {
    return windows.cut(this.#id);
  }
  copy() {
    return windows.copy(this.#id);
  }
  paste() {
    return windows.paste(this.#id);
  }
  selectAll() {
    return windows.selectAll(this.#id);
  }
  findInPage(
    text: string,
    options?: { forward?: boolean; matchCase?: boolean; findNext?: boolean },
  ) {
    return windows.findInPage(this.#id, text, options);
  }
  stopFindInPage(clearSelection = false) {
    return windows.stopFindInPage(this.#id, clearSelection);
  }
  printToPDF(path: string) {
    return windows.printToPDF(this.#id, path);
  }
  capturePage(path: string, rect?: { x: number; y: number; width: number; height: number }) {
    return windows.capturePage(this.#id, path, rect);
  }
}

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

  /** HTML read (NSPasteboard `public.html`). */
  async readHTML(): Promise<string> {
    const r = await invoke<{ html: string }>('__core__', { cmd: 'clipboard_read_html' });
    return r.html ?? '';
  },

  /** HTML write — 다른 type도 함께 지움. */
  async writeHTML(html: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'clipboard_write_html', html });
    return r.success === true;
  },

  /** RTF read (Electron `clipboard.readRTF`). */
  async readRTF(): Promise<string> {
    const r = await invoke<{ rtf: string }>('__core__', { cmd: 'clipboard_read_rtf' });
    return r.rtf ?? '';
  },

  /** RTF write (Electron `clipboard.writeRTF`). */
  async writeRTF(rtf: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'clipboard_write_rtf', rtf });
    return r.success === true;
  },

  /** 임의 UTI raw bytes 쓰기 — data는 base64 (raw ~8KB 한도). */
  async writeBuffer(format: string, data: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'clipboard_write_buffer', format, data });
    return r.success === true;
  },

  /** 임의 UTI raw bytes 읽기 — base64 string 반환. */
  async readBuffer(format: string): Promise<string> {
    const r = await invoke<{ data: string }>('__core__', { cmd: 'clipboard_read_buffer', format });
    return r.data ?? '';
  },

  /** 클립보드에 format(UTI)이 있는지. */
  async has(format: string): Promise<boolean> {
    const r = await invoke<{ present: boolean }>('__core__', { cmd: 'clipboard_has', format });
    return r.present === true;
  },

  /** 클립보드 등록된 format 배열. */
  async availableFormats(): Promise<string[]> {
    const r = await invoke<{ formats: string[] }>('__core__', { cmd: 'clipboard_available_formats' });
    return r.formats ?? [];
  },

  /** PNG 이미지 쓰기 (base64). 한도: raw PNG ~8KB (1차). */
  async writeImage(pngBase64: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'clipboard_write_image', data: pngBase64 });
    return r.success === true;
  },

  /** PNG 이미지 읽기 (base64). 없으면 빈 문자열. */
  async readImage(): Promise<string> {
    const r = await invoke<{ data: string }>('__core__', { cmd: 'clipboard_read_image' });
    return r.data ?? '';
  },

  /** TIFF 이미지 쓰기 (base64) — NSPasteboard `public.tiff`. writeImage 동형. */
  async writeTiff(tiffBase64: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'clipboard_write_tiff', data: tiffBase64 });
    return r.success === true;
  },

  /** TIFF 이미지 읽기 (base64). 없으면 빈 문자열. */
  async readTiff(): Promise<string> {
    const r = await invoke<{ data: string }>('__core__', { cmd: 'clipboard_read_tiff' });
    return r.data ?? '';
  },
};

export const powerMonitor = {
  /** 시스템 유휴 시간 (초). 활성 입력 후 0으로 리셋. */
  async getSystemIdleTime(): Promise<number> {
    const r = await invoke<{ seconds: number }>('__core__', { cmd: 'power_monitor_get_idle_time' });
    return r.seconds;
  },

  /** 화면 잠금이면 "locked", 유휴 시간 ≥ threshold(초)면 "idle", 아니면 "active". */
  async getSystemIdleState(threshold: number): Promise<'active' | 'idle' | 'locked'> {
    const r = await invoke<{ state: 'active' | 'idle' | 'locked' }>('__core__', {
      cmd: 'power_monitor_get_idle_state',
      threshold,
    });
    return r.state;
  },

  /** Electron `powerMonitor.isOnBatteryPower()` — 배터리 전원 여부(정보 없으면 false). */
  async isOnBatteryPower(): Promise<boolean> {
    const r = await invoke<{ onBattery: boolean }>('__core__', { cmd: 'power_monitor_is_on_battery' });
    return r.onBattery === true;
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

  /** 파일/폴더를 기본 앱으로 열기. 존재하지 않는 경로는 false. */
  async openPath(path: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'shell_open_path', path });
    return r.success === true;
  },
};

export const nativeImage = {
  /** 이미지 파일 dimensions. file 없거나 디코딩 실패 시 0/0. macOS NSImage. */
  async getSize(path: string): Promise<{ width: number; height: number }> {
    const r = await invoke<{ width: number; height: number }>('__core__', { cmd: 'native_image_get_size', path });
    return { width: r.width, height: r.height };
  },

  /** 이미지 파일 → PNG base64 (raw ~8KB 한도). */
  async toPng(path: string): Promise<string> {
    const r = await invoke<{ data: string }>('__core__', { cmd: 'native_image_to_png', path });
    return r.data ?? '';
  },

  /** 이미지 파일 → JPEG base64. quality 0~100. */
  async toJpeg(path: string, quality: number = 90): Promise<string> {
    const r = await invoke<{ data: string }>('__core__', { cmd: 'native_image_to_jpeg', path, quality });
    return r.data ?? '';
  },

  /** 이미지가 비어있는지 (로드 실패/크기 0) — Electron `nativeImage.isEmpty()`. */
  async isEmpty(path: string): Promise<boolean> {
    const r = await invoke<{ isEmpty: boolean }>('__core__', { cmd: 'native_image_is_empty', path });
    return r.isEmpty === true;
  },

  /** template 이미지 여부 (macOS 메뉴바 자동 틴트 대상) — Electron `nativeImage.isTemplateImage()`.
   *  macOS NSImage.isTemplate. Win/Linux는 false(미지원). */
  async isTemplateImage(path: string): Promise<boolean> {
    const r = await invoke<{ isTemplate: boolean }>('__core__', { cmd: 'native_image_is_template', path });
    return r.isTemplate === true;
  },
};

export type ThemeSource = 'system' | 'light' | 'dark';

export const nativeTheme = {
  /** 시스템 다크 모드 활성 여부 (macOS NSApp.effectiveAppearance). */
  async shouldUseDarkColors(): Promise<boolean> {
    const r = await invoke<{ dark: boolean }>('__core__', { cmd: 'native_theme_should_use_dark_colors' });
    return r.dark === true;
  },

  /** "light"|"dark"|"system" 강제. */
  async setThemeSource(source: ThemeSource): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'native_theme_set_source', source });
    return r.success === true;
  },

  /** Electron `nativeTheme.themeSource` (getter) — 마지막 설정값(기본 "system"). */
  async getThemeSource(): Promise<ThemeSource> {
    const r = await invoke<{ source: ThemeSource }>('__core__', { cmd: 'native_theme_get_source' });
    return r.source;
  },

  /** 고대비 모드 여부 (Electron `nativeTheme.shouldUseHighContrastColors`).
   *  macOS NSWorkspace.accessibilityDisplayShouldIncreaseContrast / Windows SPI_GETHIGHCONTRAST.
   *  Linux는 false(미지원). */
  async shouldUseHighContrastColors(): Promise<boolean> {
    const r = await invoke<{ highContrast: boolean }>('__core__', { cmd: 'native_theme_high_contrast' });
    return r.highContrast === true;
  },

  /** 투명도 감소 선호 여부 (Electron `nativeTheme.prefersReducedTransparency`).
   *  macOS NSWorkspace.accessibilityDisplayShouldReduceTransparency / Windows EnableTransparency==0.
   *  Linux는 false(미지원). */
  async prefersReducedTransparency(): Promise<boolean> {
    const r = await invoke<{ reducedTransparency: boolean }>('__core__', { cmd: 'native_theme_reduced_transparency' });
    return r.reducedTransparency === true;
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
// notification — 시스템 알림 (Electron `Notification`).
// macOS UNUserNotificationCenter, Linux freedesktop Notifications D-Bus,
// Windows Shell_NotifyIcon balloon.
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

  /** Electron `Notification` 전체 제거 — 표시/대기 모든 알림(macOS 실동작). */
  async removeAll(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'notification_remove_all' });
    return r.success === true;
  },
};

// ============================================
// tray — 시스템 트레이 (Electron `Tray`). frontend `@suji/api`와 동일 cmd.
// 클릭은 `tray:menu-click {trayId, click}` 이벤트로 수신 (suji.on 사용).
// ============================================

export interface TrayMenuSeparator { type: 'separator'; }
export interface TrayMenuItemSpec {
  type?: 'item';
  label: string;
  click: string;
  enabled?: boolean;
}
export interface TrayMenuCheckbox {
  type: 'checkbox';
  label: string;
  click: string;
  checked?: boolean;
  enabled?: boolean;
}
export interface TrayMenuSubmenu {
  type?: 'submenu';
  label: string;
  enabled?: boolean;
  submenu: TrayMenuItem[];
}
export type TrayMenuItem = TrayMenuItemSpec | TrayMenuCheckbox | TrayMenuSeparator | TrayMenuSubmenu;

export interface TrayCreateOptions {
  title?: string;
  tooltip?: string;
  iconPath?: string;
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
  /** Electron MenuItem.id — getMenuItemById 식별자(UI 효과 없음). */
  id?: string;
  /** Electron MenuItem.visible — false 면 항목 숨김(기본 true). */
  visible?: boolean;
  /** Electron MenuItem.accelerator — 예 "Cmd+Shift+K". macOS keyEquivalent(단일 문자),
   *  Win/Linux no-op. */
  accelerator?: string;
  /** Electron MenuItem.role — copy/paste/quit 등 표준 동작(설정 시 click 무시). macOS only,
   *  Win/Linux no-op. */
  role?: string;
  /** Electron MenuItem.icon — 이미지 파일 경로. macOS NSImage(setImage:). fs sandbox
   *  allowedRoots 게이트(렌더러 경로; 미설정=레거시 허용). macOS only. */
  icon?: string;
}
export interface MenuCheckboxItem {
  type: 'checkbox';
  label: string;
  click: string;
  checked?: boolean;
  enabled?: boolean;
  id?: string;
  visible?: boolean;
  accelerator?: string;
  /** Electron MenuItem.icon — 이미지 파일 경로. macOS NSImage(setImage:). fs sandbox 게이트. */
  icon?: string;
}
export interface MenuSubmenuItem {
  type?: 'submenu';
  label: string;
  enabled?: boolean;
  submenu: MenuItem[];
  id?: string;
  visible?: boolean;
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

  /** Electron `Menu.getApplicationMenu()` — 마지막 setApplicationMenu items 스냅샷(없으면 []).
   *  라이브 mutation 아님(fire-and-forget). */
  async getApplicationMenu(): Promise<MenuItem[]> {
    const r = await invoke<{ items: MenuItem[] }>('__core__', { cmd: 'menu_get_application_menu' });
    return Array.isArray(r.items) ? r.items : [];
  },

  /** Electron `Menu.getMenuItemById(id)` — getApplicationMenu 스냅샷에서 id 재귀 탐색(없으면 null). */
  async getMenuItemById(id: string): Promise<MenuItem | null> {
    const find = (items: MenuItem[]): MenuItem | null => {
      for (const it of items) {
        if ((it as { id?: string }).id === id) return it;
        const sub = (it as MenuSubmenuItem).submenu;
        if (Array.isArray(sub)) {
          const hit = find(sub);
          if (hit) return hit;
        }
      }
      return null;
    };
    return find(await menu.getApplicationMenu());
  },

  /** Electron `Menu.insert(pos, menuItem)` — getApplicationMenu 스냅샷 pos 에 삽입 후 재설정
   *  (fire-and-forget — splice + setApplicationMenu). pos clamp. */
  async insert(pos: number, item: MenuItem): Promise<boolean> {
    const items = await menu.getApplicationMenu();
    const idx = Math.max(0, Math.min(pos, items.length));
    items.splice(idx, 0, item);
    return menu.setApplicationMenu(items);
  },

  /** Electron `Menu.sendActionToFirstResponder(action)` — macOS first responder 에 표준
   *  셀렉터 전달(예 "copy:"). macOS only, Win/Linux no-op. */
  async sendActionToFirstResponder(action: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'menu_send_action_to_first_responder', action });
    return r.success === true;
  },
};

// ============================================
// globalShortcut — system-wide hot keys (Electron `globalShortcut.*`)
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

export interface DisplayMatchingResponse {
  cmd: 'screen_get_display_matching';
  /** getAllDisplays 배열 index. 디스플레이 없으면 -1. */
  index: number;
}

export const screen = {
  /** 연결된 모든 모니터의 bounds/scale 정보. macOS NSScreen 기반. */
  async getAllDisplays(): Promise<Display[]> {
    const r = await invoke<{ displays: Display[] }>('__core__', { cmd: 'screen_get_all_displays' });
    return r.displays;
  },

  /** 마우스 포인터 화면 좌표 (NSEvent.mouseLocation, bottom-up). */
  async getCursorScreenPoint(): Promise<{ x: number; y: number }> {
    const r = await invoke<{ x: number; y: number }>('__core__', { cmd: 'screen_get_cursor_point' });
    return { x: r.x, y: r.y };
  },

  /** (x,y)에 가장 가까운 display index. -1이면 어느 display에도 contained 안 됨. */
  async getDisplayNearestPoint(point: { x: number; y: number }): Promise<number> {
    const r = await invoke<{ index: number }>('__core__', { cmd: 'screen_get_display_nearest_point', x: point.x, y: point.y });
    return r.index;
  },

  /** Primary display (없으면 null). */
  async getPrimaryDisplay(): Promise<Display | null> {
    const all = await this.getAllDisplays();
    return all.find((d) => d.isPrimary) ?? all[0] ?? null;
  },

  /**
   * rect(보통 창 bounds)와 가장 많이 겹치는 Display (Electron `screen.getDisplayMatching`).
   * 듀얼/멀티모니터에서 "이 창이 있는 모니터" 판정 — 겹침 없으면 중심 최근접.
   * 매칭 계산은 코어 cmd `screen_get_display_matching`(전 언어 SDK 공유)이 수행.
   */
  async getDisplayMatching(rect: {
    x: number;
    y: number;
    width: number;
    height: number;
  }): Promise<Display | null> {
    const r = await invoke<DisplayMatchingResponse>('__core__', { cmd: 'screen_get_display_matching', ...rect });
    if (r.index < 0) return null;
    return (await this.getAllDisplays())[r.index] ?? null;
  },
};

/** Electron `desktopCapturer.getSources` 소스. ⚠️ thumbnail/appIcon 미포함. */
export interface DesktopCapturerSource {
  id: string;
  name: string;
  type: 'screen' | 'window';
  x: number;
  y: number;
  width: number;
  height: number;
  displayId?: number;
}

export const desktopCapturer = {
  /**
   * 화면/창 소스 열거 (Electron `desktopCapturer.getSources`).
   * types 기본 둘 다. ⚠️ Electron 과 달리 thumbnail/appIcon 미포함 —
   * Screen Recording TCC 권한 + base64 IPC 한도 때문(후속).
   */
  async getSources(
    opts: { types?: Array<'screen' | 'window'> } = {},
  ): Promise<DesktopCapturerSource[]> {
    const types = (opts.types ?? ['screen', 'window']).join(',');
    const r = await invoke<{ sources: DesktopCapturerSource[] }>('__core__', {
      cmd: 'desktop_capturer_get_sources', types,
    });
    return r.sources;
  },

  /**
   * 소스(getSources `id` — "screen:N:0"/"window:N:0") 썸네일을 PNG 로 `path`
   * 에 캡처(파일경로 — base64 IPC 한도 우회). ⚠️ Screen Recording TCC 권한
   * 필요 — 미부여 시 false(정직 경계).
   */
  async captureThumbnail(sourceId: string, path: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', {
      cmd: 'desktop_capturer_capture_thumbnail', sourceId, path,
    });
    return r.success === true;
  },
};

export interface CrashReporterStartOptions {
  submitURL?: string;
  productName?: string;
  companyName?: string;
  uploadToServer?: boolean;
  ignoreSystemCrashHandler?: boolean;
  rateLimit?: boolean;
  compress?: boolean;
  extra?: Record<string, string>;
  globalExtra?: Record<string, string>;
}

export interface CrashReport {
  date: string;
  id: string;
}

export const crashReporter = {
  /** Runtime state 등록. 첫 프로세스 Crashpad enable은 suji.json app.crashReporter 필요. */
  async start(options: CrashReporterStartOptions = {}): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'crash_reporter_start', ...options });
    return r.success === true;
  },

  async getParameters(): Promise<Record<string, string>> {
    const r = await invoke<{ parameters: Record<string, string> }>('__core__', { cmd: 'crash_reporter_get_parameters' });
    return r.parameters ?? {};
  },

  async addExtraParameter(key: string, value: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'crash_reporter_add_extra_parameter', key, value });
    return r.success === true;
  },

  async removeExtraParameter(key: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'crash_reporter_remove_extra_parameter', key });
    return r.success === true;
  },

  async getUploadToServer(): Promise<boolean> {
    const r = await invoke<{ uploadToServer: boolean }>('__core__', { cmd: 'crash_reporter_get_upload_to_server' });
    return r.uploadToServer === true;
  },

  async setUploadToServer(uploadToServer: boolean): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'crash_reporter_set_upload_to_server', uploadToServer });
    return r.success === true;
  },

  async getUploadedReports(): Promise<CrashReport[]> {
    const r = await invoke<{ reports: CrashReport[] }>('__core__', { cmd: 'crash_reporter_get_uploaded_reports' });
    return r.reports ?? [];
  },

  async getLastCrashReport(): Promise<CrashReport | null> {
    const r = await invoke<{ report: CrashReport | null }>('__core__', { cmd: 'crash_reporter_get_last_crash_report' });
    return r.report ?? null;
  },
};

export interface AutoUpdaterManifest {
  version: string;
  url: string;
  sha256?: string;
  notes?: string;
  pubDate?: string;
}

export interface AutoUpdaterCheckOptions {
  currentVersion?: string;
}

export interface AutoUpdaterCheckResult {
  success: boolean;
  updateAvailable: boolean;
  currentVersion: string;
  version: string;
  url: string;
  sha256: string;
  notes: string;
  pubDate: string;
}

export interface AutoUpdaterVerifyResult {
  success: boolean;
  actualSha256: string;
}

export interface AutoUpdaterDownloadOptions {
  sha256?: string;
}

export interface AutoUpdaterDownloadResult {
  success: boolean;
  path: string;
  sha256: string;
  size: number;
}

export type AutoUpdaterInstallFormat = 'auto' | 'app' | 'zip' | 'dmg' | 'appimage' | 'raw' | 'deb';

export interface AutoUpdaterPrepareInstallOptions {
  sha256?: string;
  target?: string;
  stageDir?: string;
  format?: AutoUpdaterInstallFormat;
}

export interface AutoUpdaterPrepareInstallResult {
  success: boolean;
  path: string;
  source: string;
  target: string;
  stageDir: string;
  format: Exclude<AutoUpdaterInstallFormat, 'auto'>;
  action: 'quitAndInstall' | 'systemPackage';
  requiresQuitAndInstall: boolean;
}

export interface AutoUpdaterQuitAndInstallOptions {
  sha256?: string;
  target?: string;
  relaunch?: boolean;
  helperPath?: string;
}

export interface AutoUpdaterQuitAndInstallResult {
  success: boolean;
  path: string;
  target: string;
  helperPath: string;
  relaunch: boolean;
}

async function resolveAutoUpdaterManifest(input: string | AutoUpdaterManifest): Promise<AutoUpdaterManifest> {
  if (typeof input !== 'string') return input;
  const res = await fetch(input);
  if (!res.ok) throw new Error(`autoUpdater manifest request failed: ${res.status}`);
  return (await res.json()) as AutoUpdaterManifest;
}

export const autoUpdater = {
  /** manifest 객체 또는 manifest URL을 확인해 새 버전 여부를 반환. */
  async checkForUpdates(
    input: string | AutoUpdaterManifest,
    options: AutoUpdaterCheckOptions = {},
  ): Promise<AutoUpdaterCheckResult> {
    const manifest = await resolveAutoUpdaterManifest(input);
    const currentVersion = options.currentVersion ?? (await app.getVersion());
    return invoke<AutoUpdaterCheckResult>('__core__', {
      cmd: 'auto_updater_check_update',
      currentVersion,
      latestVersion: manifest.version,
      url: manifest.url,
      sha256: manifest.sha256 ?? '',
      notes: manifest.notes ?? '',
      pubDate: manifest.pubDate ?? '',
    });
  },

  /** 다운로드된 파일의 SHA-256을 검증. mismatch면 success=false와 actualSha256 반환. */
  async verifyFile(path: string, sha256: string): Promise<AutoUpdaterVerifyResult> {
    return invoke<AutoUpdaterVerifyResult>('__core__', {
      cmd: 'auto_updater_verify_file',
      path,
      sha256,
    });
  },

  /** artifact URL 또는 manifest 객체를 지정 경로로 다운로드하고 optional SHA-256을 검증. */
  async downloadArtifact(
    input: string | AutoUpdaterManifest,
    path: string,
    options: AutoUpdaterDownloadOptions = {},
  ): Promise<AutoUpdaterDownloadResult> {
    const url = typeof input === 'string' ? input : input.url;
    const sha256 = options.sha256 ?? (typeof input === 'string' ? '' : input.sha256 ?? '');
    return invoke<AutoUpdaterDownloadResult>('__core__', {
      cmd: 'auto_updater_download_artifact',
      url,
      path,
      sha256,
    });
  },

  /** artifact 포맷(.zip/.dmg/.app/.AppImage/.deb)을 quitAndInstall 또는 system package handoff 입력으로 정규화. */
  async prepareInstall(
    input: string | AutoUpdaterDownloadResult,
    options: AutoUpdaterPrepareInstallOptions = {},
  ): Promise<AutoUpdaterPrepareInstallResult> {
    const path = typeof input === 'string' ? input : input.path;
    const sha256 = options.sha256 ?? (typeof input === 'string' ? '' : input.sha256 ?? '');
    return invoke<AutoUpdaterPrepareInstallResult>('__core__', {
      cmd: 'auto_updater_prepare_install',
      path,
      target: options.target ?? '',
      stageDir: options.stageDir ?? '',
      format: options.format ?? 'auto',
      sha256,
    });
  },

  /** staged artifact를 앱 종료 후 target으로 교체하고 quit을 요청. */
  async quitAndInstall(
    input: string | AutoUpdaterDownloadResult | AutoUpdaterPrepareInstallResult,
    options: AutoUpdaterQuitAndInstallOptions = {},
  ): Promise<AutoUpdaterQuitAndInstallResult> {
    const path = typeof input === 'string' ? input : input.path;
    const sha256 = options.sha256 ?? (typeof input === 'string' ? '' : 'sha256' in input ? input.sha256 ?? '' : '');
    const target = options.target ?? (typeof input === 'string' ? '' : 'target' in input ? input.target ?? '' : '');
    return invoke<AutoUpdaterQuitAndInstallResult>('__core__', {
      cmd: 'auto_updater_quit_and_install',
      path,
      target,
      sha256,
      relaunch: options.relaunch ?? true,
      helperPath: options.helperPath ?? '',
    });
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

export interface CookieDescriptor {
  url: string;
  name: string;
  value?: string;
  domain?: string;
  path?: string;
  secure?: boolean;
  httponly?: boolean;
  /** unix epoch second. 0이면 세션 쿠키. */
  expires?: number;
}

export interface CookieRecord {
  name: string;
  value: string;
  domain: string;
  path: string;
  secure: boolean;
  httponly: boolean;
  expires: number;
}

export interface CookieFilter {
  url?: string;
  includeHttpOnly?: boolean;
}

/** 렌더러(웹 콘텐츠)가 권한을 요청할 때 핸들러가 받는 정보. */
export interface PermissionRequestDetails {
  /** 응답 매칭용 CEF prompt id. */
  permissionId: number;
  /** 요청 origin. file:// 페이지는 빈 문자열일 수 있음. */
  origin: string;
  /** 요청된 권한 이름 배열 (예: ["geolocation"]). */
  permissions: string[];
}

/** 권한 요청 핸들러 — true 반환 시 허용, false 반환 시 거부. async 가능. 1 핸들러만 active. */
export type PermissionRequestHandler = (
  details: PermissionRequestDetails,
) => boolean | Promise<boolean>;

let activePermissionOff: (() => void) | null = null;

export const session = {
  /** 모든 cookie 삭제 (fire-and-forget). 실제 cleanup은 비동기. */
  async clearCookies(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'session_clear_cookies' });
    return r.success === true;
  },

  /** disk store flush (Electron `session.cookies.flushStore`). */
  async flushStore(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'session_flush_store' });
    return r.success === true;
  },

  /**
   * Electron `session.setProxy(config)` — Chromium "proxy" preference 설정.
   * mode 미지정/`"direct"` → 프록시 해제. `proxyRules`: `"host:port"`. 이후 요청에 적용.
   */
  async setProxy(config: {
    mode?: 'direct' | 'auto_detect' | 'pac_script' | 'fixed_servers' | 'system';
    proxyRules?: string;
    proxyBypassRules?: string;
    pacScript?: string;
  }): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', {
      cmd: 'session_set_proxy',
      mode: config.mode ?? '',
      proxyRules: config.proxyRules ?? '',
      proxyBypassRules: config.proxyBypassRules ?? '',
      pacScript: config.pacScript ?? '',
    });
    return r.success === true;
  },

  /**
   * Electron `session.setPermissionRequestHandler(handler)` 동등. 렌더러가 geolocation/
   * notifications/clipboard 등 권한을 요청하면 handler 가 호출돼 true(허용)/false(거부) 결정.
   * async 가능(타임아웃 없음). throw/비-bool → 거부(안전 기본). null → 핸들러 해제.
   * 1 핸들러만 active. 정직 경계: camera/mic(getUserMedia)는 별도 CEF 경로라 미포함.
   */
  async setPermissionRequestHandler(
    handler: PermissionRequestHandler | null,
  ): Promise<void> {
    if (activePermissionOff) {
      activePermissionOff();
      activePermissionOff = null;
    }
    if (!handler) {
      await invoke('__core__', { cmd: 'session_set_permission_handler', enabled: false });
      return;
    }
    activePermissionOff = on<PermissionRequestDetails>(
      'session:permission-request',
      (ev) => {
        let settled = false;
        const respond = (granted: boolean) => {
          if (settled) return;
          settled = true;
          void invoke('__core__', {
            cmd: 'session_permission_response',
            permissionId: ev.permissionId,
            granted,
          });
        };
        Promise.resolve()
          .then(() => handler(ev))
          .then((granted) => respond(granted === true))
          .catch(() => respond(false));
      },
    );
    await invoke('__core__', { cmd: 'session_set_permission_handler', enabled: true });
  },

  /**
   * IndexedDB/localStorage/cache 삭제 (Electron `session.clearStorageData`).
   * origin 미지정 → 전역 HTTP 캐시만(웹 플랫폼상 origin 없이 storage 일괄
   * 삭제 불가). storageTypes 기본 "all" (CDP 콤마구분).
   */
  async clearStorageData(origin = '', storageTypes = 'all'): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', {
      cmd: 'session_clear_storage_data', origin, storageTypes,
    });
    return r.success === true;
  },

  /** Electron `session.cookies.set`. expires는 unix epoch second (0 → 세션 쿠키). */
  async setCookie(cookie: CookieDescriptor): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', {
      cmd: 'session_set_cookie',
      url: cookie.url,
      name: cookie.name,
      value: cookie.value ?? '',
      domain: cookie.domain ?? '',
      path: cookie.path ?? '',
      secure: cookie.secure ?? false,
      httponly: cookie.httponly ?? false,
      expires: cookie.expires ?? 0,
    });
    return r.success === true;
  },

  /** Electron `session.cookies.remove`. url+name 매칭. */
  async removeCookies(url: string, name: string): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', {
      cmd: 'session_remove_cookies',
      url,
      name,
    });
    return r.success === true;
  },

  /** Electron `session.cookies.get`. visitor 패턴 — `session:cookies-result`로 결과 도착.
   *  Race-safe: listener 먼저 등록 + emit을 buffer (visit이 invoke 응답보다 빨리 fire 가능). */
  async getCookies(filter: CookieFilter = {}): Promise<CookieRecord[]> {
    return new Promise<CookieRecord[]>((resolve) => {
      let id = 0;
      let pending: { requestId: number; cookies: CookieRecord[] } | null = null;
      const timer = setTimeout(() => {
        off();
        resolve([]);
      }, 1000);
      const off = on<{ requestId: number; cookies: CookieRecord[] }>(
        'session:cookies-result',
        (data) => {
          if (id === 0) {
            pending = data;
            return;
          }
          if (data.requestId !== id) return;
          clearTimeout(timer);
          off();
          resolve(data.cookies ?? []);
        },
      );
      invoke<{ success: boolean; requestId: number }>('__core__', {
        cmd: 'session_get_cookies',
        url: filter.url ?? '',
        includeHttpOnly: filter.includeHttpOnly ?? true,
      })
        .then((r) => {
          if (!r.success || !r.requestId) {
            clearTimeout(timer);
            off();
            resolve([]);
            return;
          }
          id = r.requestId;
          if (pending && pending.requestId === id) {
            clearTimeout(timer);
            off();
            resolve(pending.cookies ?? []);
          }
        })
        .catch(() => {
          clearTimeout(timer);
          off();
          resolve([]);
        });
    });
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
  /** suji.json `app.name` 반환. */
  async getName(): Promise<string> {
    const r = await invoke<{ name: string }>('__core__', { cmd: 'app_get_name' });
    return r.name;
  },

  /** suji.json `app.version` 반환. */
  async getVersion(): Promise<string> {
    const r = await invoke<{ version: string }>('__core__', { cmd: 'app_get_version' });
    return r.version;
  },

  /** 앱 init 완료 여부 (V8 binding 호출 가능 시점이면 항상 true). */
  async isReady(): Promise<boolean> {
    const r = await invoke<{ ready: boolean }>('__core__', { cmd: 'app_is_ready' });
    return r.ready === true;
  },

  /** `.app` 번들로 실행 중인지 (Electron `app.isPackaged`). dev mode에선 false. */
  async isPackaged(): Promise<boolean> {
    const r = await invoke<{ packaged: boolean }>('__core__', { cmd: 'app_is_packaged' });
    return r.packaged === true;
  },

  /** 메인 번들 경로 (Electron `app.getAppPath`). dev mode에선 binary가 위치한 디렉토리. */
  async getAppPath(): Promise<string> {
    const r = await invoke<{ path: string }>('__core__', { cmd: 'app_get_app_path' });
    return r.path ?? '';
  },

  /** 시스템 locale (BCP 47, e.g. "en-US"). */
  async getLocale(): Promise<string> {
    const r = await invoke<{ locale: string }>('__core__', { cmd: 'app_get_locale' });
    return r.locale;
  },

  /** Electron `app.setBadgeCount(count)` 동등. 0 이하면 배지 제거. */
  async setBadgeCount(count: number): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'app_set_badge_count', count });
    return r.success === true;
  },

  /** Electron `app.getBadgeCount()` 동등. */
  async getBadgeCount(): Promise<number> {
    const r = await invoke<{ count: number }>('__core__', { cmd: 'app_get_badge_count' });
    return r.count ?? 0;
  },

  /** dock 진행률. progress<0=hide, 0~1=ratio, >1=clamp to 1. */
  async setProgressBar(progress: number): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'app_set_progress_bar', progress });
    return r.success === true;
  },

  /** 앱 강제 종료 (Electron `app.exit(code)`). exit code는 무시. */
  async exit(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'app_exit' });
    return r.success === true;
  },

  /**
   * Electron `app.requestSingleInstanceLock()` — primary 면 true, 다른 인스턴스가
   * 이미 보유 중이면 false (보통 앱 quit). 이미 보유 중이면 멱등적으로 true.
   * macOS/Linux=userData flock, Windows=named mutex.
   */
  async requestSingleInstanceLock(): Promise<boolean> {
    const r = await invoke<{ locked: boolean }>('__core__', { cmd: 'app_request_single_instance_lock' });
    return r.locked === true;
  },

  /** Electron `app.hasSingleInstanceLock()` — 이 프로세스가 락 보유 중인지. */
  async hasSingleInstanceLock(): Promise<boolean> {
    const r = await invoke<{ locked: boolean }>('__core__', { cmd: 'app_has_single_instance_lock' });
    return r.locked === true;
  },

  /** Electron `app.releaseSingleInstanceLock()` — 보유 락 해제(없으면 no-op). */
  async releaseSingleInstanceLock(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'app_release_single_instance_lock' });
    return r.success === true;
  },

  /** 앱 frontmost로. */
  async focus(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'app_focus' });
    return r.success === true;
  },

  /** 모든 윈도우 hide (macOS Cmd+H). */
  async hide(): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'app_hide' });
    return r.success === true;
  },

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

  /**
   * Security-scoped bookmark 생성 (App Sandbox 영속 파일 접근). 실패 시 null.
   * 비-sandbox 빌드에선 일반 bookmark 로 동작 (sandbox escapement no-op).
   */
  async createSecurityScopedBookmark(path: string): Promise<string | null> {
    const r = await invoke<{ success: boolean; bookmark?: string }>('__core__', { cmd: 'security_scoped_bookmark_create', path });
    return r.success === true ? r.bookmark ?? null : null;
  },

  /** bookmark 해소 + 접근 시작. 실패 시 null. id 를 stop 에 전달. */
  async startAccessingSecurityScopedResource(
    bookmark: string,
  ): Promise<{ id: number; path: string; stale: boolean } | null> {
    const r = await invoke<{ success: boolean; id: number; path: string; stale: boolean }>(
      '__core__',
      { cmd: 'security_scoped_access_start', bookmark },
    );
    return r.success === true ? { id: r.id, path: r.path, stale: r.stale } : null;
  },

  /** 접근 종료. 유효하지 않은 id 는 false. */
  async stopAccessingSecurityScopedResource(id: number): Promise<boolean> {
    const r = await invoke<{ success: boolean }>('__core__', { cmd: 'security_scoped_access_stop', id });
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
