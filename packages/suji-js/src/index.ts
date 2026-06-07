/**
 * @suji/api — Suji Desktop Framework Frontend API
 *
 * Electron-style IPC for Suji apps.
 *
 * ```ts
 * import { invoke, on, send } from '@suji/api';
 *
 * const result = await invoke("ping");
 * const result = await invoke("greet", { name: "Suji" });
 * const result = await invoke("greet", { name: "Suji" }, { target: "rust" });
 *
 * const cancel = on("data-updated", (data) => console.log(data));
 * send("button-clicked", { button: "save" });
 * cancel(); // remove listener
 * ```
 */

export interface InvokeOptions {
  /** 특정 백엔드 지정 (생략 시 자동 라우팅) */
  target?: string;
}

/**
 * 사용자 핸들러 타입 declaration. 사용자가 module augmentation으로 채우면 `invoke`가
 * type-safe해진다 (cmd/req/res 모두 추론).
 *
 * ```ts
 * // 사용자 프로젝트의 src/suji.d.ts
 * declare module '@suji/api' {
 *   interface SujiHandlers {
 *     ping: { req: void; res: { msg: string } };
 *     greet: { req: { name: string }; res: string };
 *   }
 * }
 *
 * await invoke('greet', { name: 'Suji' });  // res: string
 * await invoke('ping');                     // req 생략 가능, res: { msg: string }
 * ```
 *
 * 비어있을 때 (default)는 fallback overload가 작동 — 기존 untyped invoke 호환.
 */
export interface SujiHandlers {}

/** Helper: req가 void/undefined이면 args 생략 가능, 아니면 필수. */
type InvokeArgsForHandler<K extends keyof SujiHandlers & string> =
  SujiHandlers[K] extends { req: infer R }
    ? [R] extends [void | undefined]
      ? [data?: undefined, options?: InvokeOptions]
      : [data: R, options?: InvokeOptions]
    : [data?: unknown, options?: InvokeOptions];

type InvokeRes<K extends keyof SujiHandlers & string> =
  SujiHandlers[K] extends { res: infer R } ? R : unknown;

/** 등록된 cmd면 typed args/res, 아니면 untyped fallback. conditional dispatch. */
type InvokeArgs<K extends string> = K extends keyof SujiHandlers & string
  ? InvokeArgsForHandler<K>
  : [data?: Record<string, unknown>, options?: InvokeOptions];

type InvokeReturn<K extends string> =
  K extends keyof SujiHandlers & string ? InvokeRes<K> : unknown;

export interface SendOptions {
  /** 특정 창(window id)에만 전달. 생략 시 모든 창으로 브로드캐스트 (Electron `webContents.send` 대응) */
  to?: number;
}

type Listener = (data: unknown) => void;

interface SujiBridge {
  invoke(channel: string, data?: string, options?: string): Promise<unknown>;
  on(event: string, cb: Listener): () => void;
  emit(event: string, data: string, target?: number): Promise<unknown>;
  chain(from: string, to: string, request: string): Promise<unknown>;
  fanout(backends: string, request: string): Promise<unknown>;
  core(request: string): Promise<unknown>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available. Are you running inside a Suji app?");
  return bridge;
}

/**
 * 백엔드 핸들러 호출 (Electron: ipcRenderer.invoke). SujiHandlers에 등록된 cmd면
 * type-safe (cmd/req/res 추론), 아니면 untyped fallback.
 *
 * @param channel - 핸들러 채널 이름
 * @param data - 요청 데이터 (옵셔널)
 * @param options - { target: "backend" } 명시적 백엔드 지정 (옵셔널)
 */
export async function invoke<K extends string>(
  cmd: K,
  ...rest: InvokeArgs<K>
): Promise<InvokeReturn<K>> {
  const [data, options] = rest;
  return getBridge().invoke(cmd, data as any, options as any) as any;
}

/**
 * 이벤트 구독 (Electron: ipcRenderer.on)
 *
 * @returns 리스너 해제 함수
 */
export function on(event: string, callback: Listener): () => void {
  return getBridge().on(event, callback);
}

/**
 * 이벤트 한 번만 구독 (Electron: ipcRenderer.once)
 *
 * @returns 리스너 해제 함수
 */
export function once(event: string, callback: Listener): () => void {
  const cancel = getBridge().on(event, (data) => {
    cancel();
    callback(data);
  });
  return cancel;
}

/**
 * 이벤트 발신 (Electron: ipcRenderer.send / webContents.send)
 *
 * @param options.to - 특정 창 id 지정 시 해당 창에만. 생략 시 모든 창으로 브로드캐스트.
 */
export function send(event: string, data: unknown, options?: SendOptions): void {
  getBridge().emit(event, JSON.stringify(data ?? {}), options?.to);
}

/**
 * 채널의 모든 리스너 해제 (Electron: ipcRenderer.removeAllListeners)
 */
export function off(event: string): void {
  const bridge = (window as any).__suji__;
  if (bridge?.off) bridge.off(event);
}

// ============================================
// windows — 런타임 창 생성/조작 (Phase 3 옵션 풀 지원)
// 내부적으로 `__suji__.core(JSON.stringify({...}))`로 라우팅된다.
// suji.json startup 창과 동일한 옵션 셋을 노출 (camelCase).
// ============================================

export type TitleBarStyle = "default" | "hidden" | "hiddenInset";

export interface WindowOptions {
  /** 창 타이틀 */
  title?: string;
  /** 초기 로드 URL. 생략 시 frontend dev_url/dist 자동 선택 */
  url?: string;
  /** WM 등록 이름 (singleton 키). 동일 name이 이미 있으면 기존 창 id 반환 */
  name?: string;
  width?: number;
  height?: number;
  /** 초기 위치 (px). 0/생략 시 OS cascade 자동 배치 */
  x?: number;
  y?: number;
  /** 부모 창 id 직접 지정 (parent보다 우선) */
  parentId?: number;
  /** 부모 창 이름 — 코어가 이름→id 변환 */
  parent?: string;
  /** false면 frameless (타이틀바/리사이즈 핸들 제거) */
  frame?: boolean;
  /** true면 투명 NSWindow + clear background (HTML body도 transparent여야 의미) */
  transparent?: boolean;
  /** 16진수 RGB(A) (`#FFFFFF` / `#FFFFFFFF`). transparent와 함께면 transparent 우선 */
  backgroundColor?: string;
  titleBarStyle?: TitleBarStyle;
  /** 사용자 리사이즈 허용 (frame=false일 땐 무시) */
  resizable?: boolean;
  /** NSFloatingWindowLevel — 일반 창 위 항상 표시 */
  alwaysOnTop?: boolean;
  minWidth?: number;
  minHeight?: number;
  maxWidth?: number;
  maxHeight?: number;
  /** 시작 시 전체화면 */
  fullscreen?: boolean;
}

export interface CreateWindowResponse {
  cmd: "create_window";
  from: "zig-core";
  windowId: number;
}

export interface WindowOpResponse {
  cmd: string;
  from: "zig-core";
  windowId: number;
  ok: boolean;
}

export interface SetBoundsArgs {
  x?: number;
  y?: number;
  width?: number;
  height?: number;
}

export interface GetUrlResponse extends WindowOpResponse {
  cmd: "get_url";
  url: string | null;
}

export interface GetUserAgentResponse extends WindowOpResponse {
  cmd: "get_user_agent";
  userAgent: string | null;
}

export interface IsLoadingResponse extends WindowOpResponse {
  cmd: "is_loading";
  loading: boolean;
}

export interface IsDevToolsOpenedResponse extends WindowOpResponse {
  cmd: "is_dev_tools_opened";
  opened: boolean;
}

export interface ZoomLevelResponse extends WindowOpResponse {
  cmd: "get_zoom_level";
  level: number;
}

export interface ZoomFactorResponse extends WindowOpResponse {
  cmd: "get_zoom_factor";
  factor: number;
}

export interface IsAudioMutedResponse extends WindowOpResponse {
  cmd: "is_audio_muted";
  muted: boolean;
}

export interface OpacityResponse extends WindowOpResponse {
  cmd: "get_opacity";
  opacity: number;
}

export interface HasShadowResponse extends WindowOpResponse {
  cmd: "has_shadow";
  hasShadow: boolean;
}
export interface IsMinimizedResponse extends WindowOpResponse {
  cmd: "is_minimized";
  minimized: boolean;
}
export interface IsMaximizedResponse extends WindowOpResponse {
  cmd: "is_maximized";
  maximized: boolean;
}
export interface IsResizableResponse extends WindowOpResponse {
  cmd: "is_resizable";
  resizable: boolean;
}
export interface IsMinimizableResponse extends WindowOpResponse {
  cmd: "is_minimizable";
  minimizable: boolean;
}
export interface IsMaximizableResponse extends WindowOpResponse {
  cmd: "is_maximizable";
  maximizable: boolean;
}
export interface IsClosableResponse extends WindowOpResponse {
  cmd: "is_closable";
  closable: boolean;
}
export interface IsMovableResponse extends WindowOpResponse {
  cmd: "is_movable";
  movable: boolean;
}
export interface IsFocusableResponse extends WindowOpResponse {
  cmd: "is_focusable";
  focusable: boolean;
}
export interface IsEnabledResponse extends WindowOpResponse {
  cmd: "is_enabled";
  enabled: boolean;
}
export interface IsFullScreenableResponse extends WindowOpResponse {
  cmd: "is_fullscreenable";
  fullscreenable: boolean;
}
export interface IsKioskResponse extends WindowOpResponse {
  cmd: "is_kiosk";
  kiosk: boolean;
}
export interface IsFullScreenResponse extends WindowOpResponse {
  cmd: "is_fullscreen";
  fullscreen: boolean;
}
export interface IsNormalResponse extends WindowOpResponse {
  cmd: "is_normal";
  /** minimized/maximized/fullscreen 모두 아닌 일반 상태 */
  normal: boolean;
}
export interface BoundsResponse extends WindowOpResponse {
  cmd: "get_bounds";
  /** 화면 좌표(top-left 원점) */
  x: number;
  y: number;
  width: number;
  height: number;
}
/** get_minimum_size / get_maximum_size 응답 — 추적된 제약 크기(0 = 제한 없음). */
export interface SizeResponse extends WindowOpResponse {
  width: number;
  height: number;
}
export interface IsFocusedResponse extends WindowOpResponse {
  cmd: "is_focused";
  focused: boolean;
}
export interface IsVisibleResponse extends WindowOpResponse {
  cmd: "is_visible";
  visible: boolean;
}
export interface IsAlwaysOnTopResponse extends WindowOpResponse {
  cmd: "is_always_on_top";
  alwaysOnTop: boolean;
}
export interface GetAllWindowsResponse {
  from: "zig-core";
  cmd: "get_all_windows";
  ok: boolean;
  /** 살아있는 top-level 창 id (WebContentsView 제외) */
  windowIds: number[];
}
export interface GetFocusedWindowResponse {
  from: "zig-core";
  cmd: "get_focused_window";
  ok: boolean;
  /** 포커스된 창 id, 없으면 null */
  windowId: number | null;
}

// ── Phase 17-A: WebContentsView (한 창 multi-content 합성) ──
// viewId는 windowId와 같은 monotonic 풀에서 발급 — `windows.loadURL(viewId, ...)`,
// `windows.executeJavaScript(viewId, ...)` 등 모든 webContents API가 view에도 동작.

export interface ViewOptions {
  /** view를 합성할 host 창 id. live & .window이어야 함 */
  hostId: number;
  /** 초기 로드 URL */
  url?: string;
  /** view 식별/디버깅 이름 (by_name 등록 X — view는 host scope) */
  name?: string;
  /** host contentView 좌표계의 view 위치/크기 (top-left). 기본 {0, 0, 800, 600} */
  bounds?: SetBoundsArgs;
}

export interface CreateViewResponse {
  cmd: "create_view";
  from: "zig-core";
  viewId: number;
}

/** view 전용 op 응답 — `windowId` 키 대신 `viewId`로 응답. webContents 메서드(load_url 등)
 *  는 그대로 windowId 키 사용 (id 풀 공유). */
export interface ViewOpResponse {
  cmd: string;
  from: "zig-core";
  viewId: number;
  ok: boolean;
}

export interface GetChildViewsResponse {
  cmd: "get_child_views";
  from: "zig-core";
  hostId: number;
  ok: boolean;
  /** z-order 순서 (0=bottom, 마지막=top). 빈 배열이면 host에 view 없음 */
  viewIds: number[];
}

async function coreCall<T>(request: Record<string, unknown>): Promise<T> {
  const raw = await getBridge().core(JSON.stringify(request));
  return (typeof raw === "string" ? JSON.parse(raw) : raw) as T;
}

/** deferred-response(`printToPDF`/`capturePage`) 전용 타임아웃 가드. 코어 TTL(30s)
 *  보다 여유를 둔 35s 후 `{success:false}` 로 resolve — 코어가 끝내 응답을 못 보내는
 *  극단(렌더러/GPU 크래시) 에서도 Promise hang 방지. 코어가 늦게 응답해도 race 승자가
 *  이미 정해져 무해. getCookies 의 setTimeout 패턴과 동형. */
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
  /**
   * 새 창 생성. Phase 3 옵션 풀 지원 — suji.json `windows[]` 항목과 동일한 키.
   * @returns `{ windowId }` — 후속 setTitle/setBounds 및 `send(_, { to: windowId })`에 사용
   */
  create(opts: WindowOptions = {}): Promise<CreateWindowResponse> {
    return coreCall<CreateWindowResponse>({ cmd: "create_window", ...opts });
  },

  /** 창 타이틀 변경 */
  setTitle(windowId: number, title: string): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_title", windowId, title });
  },

  /** 창 크기/위치 변경. width/height=0이면 현재 유지 */
  setBounds(windowId: number, bounds: SetBoundsArgs): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_bounds", windowId, ...bounds });
  },

  // ── Phase 4-A: webContents 네비/JS ──

  /** 창에 새 URL 로드 (Electron `webContents.loadURL`) */
  loadURL(windowId: number, url: string): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "load_url", windowId, url });
  },

  /** 현재 페이지 reload. ignoreCache=true면 disk 캐시 무시 */
  reload(windowId: number, ignoreCache = false): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "reload", windowId, ignoreCache });
  },

  /** 렌더러에서 임의 JS 실행 (Electron `webContents.executeJavaScript`).
   *  결과 회신은 미지원 — fire-and-forget. 결과가 필요하면 JS 측에서 `suji.send`로 회신. */
  executeJavaScript(windowId: number, code: string): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "execute_javascript", windowId, code });
  },

  /** 현재 main frame URL 조회 (캐시된 값). 캐시 미스면 null */
  getURL(windowId: number): Promise<GetUrlResponse> {
    return coreCall<GetUrlResponse>({ cmd: "get_url", windowId });
  },

  /** UA 동적 변경 (Electron `webContents.setUserAgent`). CDP
   *  Network.setUserAgentOverride — 이후 네비/요청에 적용. */
  setUserAgent(windowId: number, userAgent: string): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_user_agent", windowId, userAgent });
  },

  /** 설정한 UA override 조회 (Electron `webContents.getUserAgent`).
   *  미설정 시 userAgent=null (브라우저 기본 — CEF 가 per-browser
   *  기본 UA getter 미제공). */
  getUserAgent(windowId: number): Promise<GetUserAgentResponse> {
    return coreCall<GetUserAgentResponse>({ cmd: "get_user_agent", windowId });
  },

  /** 현재 로딩 중인지 조회 (Electron `webContents.isLoading`) */
  isLoading(windowId: number): Promise<IsLoadingResponse> {
    return coreCall<IsLoadingResponse>({ cmd: "is_loading", windowId });
  },

  /** DevTools 열기 — 이미 열려있으면 멱등 no-op */
  openDevTools(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "open_dev_tools", windowId });
  },

  /** DevTools 닫기 — 이미 닫혀있으면 no-op */
  closeDevTools(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "close_dev_tools", windowId });
  },

  /** DevTools 열려있는지 조회 (Electron `webContents.isDevToolsOpened`) */
  isDevToolsOpened(windowId: number): Promise<IsDevToolsOpenedResponse> {
    return coreCall<IsDevToolsOpenedResponse>({ cmd: "is_dev_tools_opened", windowId });
  },

  /** DevTools 토글 — F12 단축키와 동일 동작 */
  toggleDevTools(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "toggle_dev_tools", windowId });
  },

  /** 줌 레벨 변경. Electron 호환 — 0 = 100%, 1 = 120%, -1 = 1/1.2 (logarithmic) */
  setZoomLevel(windowId: number, level: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_zoom_level", windowId, level });
  },

  getZoomLevel(windowId: number): Promise<ZoomLevelResponse> {
    return coreCall<ZoomLevelResponse>({ cmd: "get_zoom_level", windowId });
  },

  /** 줌 factor 변경. 1.0 = 100%, 1.5 = 150% (linear). 내부적으로 level = log(factor)/log(1.2) 변환 */
  setZoomFactor(windowId: number, factor: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_zoom_factor", windowId, factor });
  },

  getZoomFactor(windowId: number): Promise<ZoomFactorResponse> {
    return coreCall<ZoomFactorResponse>({ cmd: "get_zoom_factor", windowId });
  },

  /** 창 오디오 mute (Electron `webContents.setAudioMuted`). */
  setAudioMuted(windowId: number, muted: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_audio_muted", windowId, muted });
  },

  /** 창 오디오 mute 상태 (Electron `webContents.isAudioMuted`). */
  isAudioMuted(windowId: number): Promise<IsAudioMutedResponse> {
    return coreCall<IsAudioMutedResponse>({ cmd: "is_audio_muted", windowId });
  },

  /** 창 투명도 (0~1). Electron `BrowserWindow.setOpacity`. */
  setOpacity(windowId: number, opacity: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_opacity", windowId, opacity });
  },

  /** 창 투명도 읽기. */
  getOpacity(windowId: number): Promise<OpacityResponse> {
    return coreCall<OpacityResponse>({ cmd: "get_opacity", windowId });
  },

  /** 배경색 (`#RRGGBB` 또는 `#RRGGBBAA`). Electron `BrowserWindow.setBackgroundColor`. */
  setBackgroundColor(windowId: number, color: string): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_background_color", windowId, color });
  },

  /** 그림자 표시 여부. Electron `BrowserWindow.setHasShadow`. */
  setHasShadow(windowId: number, hasShadow: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_has_shadow", windowId, hasShadow });
  },

  /** 그림자 상태 읽기. Electron `BrowserWindow.hasShadow`. */
  hasShadow(windowId: number): Promise<HasShadowResponse> {
    return coreCall<HasShadowResponse>({ cmd: "has_shadow", windowId });
  },

  // ── 창 생명주기 (Electron `BrowserWindow` 패리티 — Zig 백엔드 기존 구현 노출) ──
  minimize(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "minimize", windowId });
  },
  maximize(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "maximize", windowId });
  },
  unmaximize(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "unmaximize", windowId });
  },
  restore(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "restore_window", windowId });
  },
  show(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_visible", windowId, visible: true });
  },
  hide(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_visible", windowId, visible: false });
  },
  close(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "destroy_window", windowId });
  },
  /** 강제 파괴 (Electron `BrowserWindow.destroy`). close 와 달리 `window:close`
   *  (취소 hook)를 스킵하고 `window:closed` 만 발화 — listener 가 막을 수 없음. */
  destroy(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "destroy_window_force", windowId });
  },
  setFullScreen(windowId: number, flag: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_fullscreen", windowId, flag });
  },
  isMinimized(windowId: number): Promise<IsMinimizedResponse> {
    return coreCall<IsMinimizedResponse>({ cmd: "is_minimized", windowId });
  },
  isMaximized(windowId: number): Promise<IsMaximizedResponse> {
    return coreCall<IsMaximizedResponse>({ cmd: "is_maximized", windowId });
  },
  isFullScreen(windowId: number): Promise<IsFullScreenResponse> {
    return coreCall<IsFullScreenResponse>({ cmd: "is_fullscreen", windowId });
  },
  /** Electron BrowserWindow.focus() — 창을 포그라운드로 키 창으로. */
  focus(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "focus", windowId });
  },
  /** Electron BrowserWindow.isNormal() — minimized/maximized/fullscreen 모두 아님. */
  isNormal(windowId: number): Promise<IsNormalResponse> {
    return coreCall<IsNormalResponse>({ cmd: "is_normal", windowId });
  },
  /** Electron BrowserWindow.getBounds() — {x,y,width,height} (top-left 원점). */
  getBounds(windowId: number): Promise<BoundsResponse> {
    return coreCall<BoundsResponse>({ cmd: "get_bounds", windowId });
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
    return coreCall<BoundsResponse>({ cmd: "get_content_bounds", windowId });
  },
  /** Electron BrowserWindow.setContentBounds() — 콘텐츠 영역을 지정 사각형으로. */
  setContentBounds(windowId: number, bounds: SetBoundsArgs): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_content_bounds", windowId, ...bounds });
  },
  /** Electron BrowserWindow.getContentSize() — [width, height]. getContentBounds 에서 파생. */
  async getContentSize(windowId: number): Promise<[number, number]> {
    const b = await windows.getContentBounds(windowId);
    return [b.width, b.height];
  },
  /** Electron BrowserWindow.setSize(width, height) — 위치 유지(getBounds→setBounds 파생).
   *  `animate` 는 받되 무시(CEF Views set_bounds 비애니메이션 — 정직). */
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
  /** Electron BrowserWindow.setPosition(x, y) — 크기 유지(getBounds→setBounds 파생). `animate` 무시. */
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
    return coreCall<WindowOpResponse>({ cmd: "set_minimum_size", windowId, width, height });
  },
  /** Electron BrowserWindow.getMinimumSize() — [width, height] (추적된 제약값, 0=없음). */
  async getMinimumSize(windowId: number): Promise<[number, number]> {
    const r = await coreCall<SizeResponse>({ cmd: "get_minimum_size", windowId });
    return [r.width, r.height];
  },
  /** Electron BrowserWindow.setMaximumSize(width, height). 0 = 제한 없음. */
  setMaximumSize(windowId: number, width: number, height: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_maximum_size", windowId, width, height });
  },
  /** Electron BrowserWindow.getMaximumSize() — [width, height] (추적된 제약값, 0=없음). */
  async getMaximumSize(windowId: number): Promise<[number, number]> {
    const r = await coreCall<SizeResponse>({ cmd: "get_maximum_size", windowId });
    return [r.width, r.height];
  },
  /** Electron BrowserWindow.setResizable(resizable). false 면 사용자 리사이즈 불가. */
  setResizable(windowId: number, resizable: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_resizable", windowId, resizable });
  },
  /** Electron BrowserWindow.isResizable(). */
  isResizable(windowId: number): Promise<IsResizableResponse> {
    return coreCall<IsResizableResponse>({ cmd: "is_resizable", windowId });
  },
  /** Electron BrowserWindow.setMinimizable(minimizable). */
  setMinimizable(windowId: number, minimizable: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_minimizable", windowId, minimizable });
  },
  /** Electron BrowserWindow.isMinimizable(). */
  isMinimizable(windowId: number): Promise<IsMinimizableResponse> {
    return coreCall<IsMinimizableResponse>({ cmd: "is_minimizable", windowId });
  },
  /** Electron BrowserWindow.setMaximizable(maximizable). */
  setMaximizable(windowId: number, maximizable: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_maximizable", windowId, maximizable });
  },
  /** Electron BrowserWindow.isMaximizable(). */
  isMaximizable(windowId: number): Promise<IsMaximizableResponse> {
    return coreCall<IsMaximizableResponse>({ cmd: "is_maximizable", windowId });
  },
  /** Electron BrowserWindow.setClosable(closable). false 면 닫기 불가. */
  setClosable(windowId: number, closable: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_closable", windowId, closable });
  },
  /** Electron BrowserWindow.isClosable(). */
  isClosable(windowId: number): Promise<IsClosableResponse> {
    return coreCall<IsClosableResponse>({ cmd: "is_closable", windowId });
  },
  /** Electron BrowserWindow.setMovable(movable). macOS NSWindow.movable, 그 외 tracked. */
  setMovable(windowId: number, movable: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_movable", windowId, movable });
  },
  /** Electron BrowserWindow.isMovable(). */
  isMovable(windowId: number): Promise<IsMovableResponse> {
    return coreCall<IsMovableResponse>({ cmd: "is_movable", windowId });
  },
  /** Electron BrowserWindow.setFocusable(focusable). tracked(best-effort). */
  setFocusable(windowId: number, focusable: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_focusable", windowId, focusable });
  },
  /** Electron BrowserWindow.isFocusable(). */
  isFocusable(windowId: number): Promise<IsFocusableResponse> {
    return coreCall<IsFocusableResponse>({ cmd: "is_focusable", windowId });
  },
  /** Electron BrowserWindow.setEnabled(enable). Win32 EnableWindow / macOS ignoresMouseEvents(마우스). */
  setEnabled(windowId: number, enabled: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_enabled", windowId, enabled });
  },
  /** Electron BrowserWindow.isEnabled(). */
  isEnabled(windowId: number): Promise<IsEnabledResponse> {
    return coreCall<IsEnabledResponse>({ cmd: "is_enabled", windowId });
  },
  /** Electron BrowserWindow.setFullScreenable(fullscreenable). macOS collectionBehavior, 그 외 tracked. */
  setFullScreenable(windowId: number, fullscreenable: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_fullscreenable", windowId, fullscreenable });
  },
  /** Electron BrowserWindow.isFullScreenable(). */
  isFullScreenable(windowId: number): Promise<IsFullScreenableResponse> {
    return coreCall<IsFullScreenableResponse>({ cmd: "is_fullscreenable", windowId });
  },
  /** Electron BrowserWindow.setKiosk(flag). best-effort: 전체화면(presentation-options 미포함). */
  setKiosk(windowId: number, flag: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_kiosk", windowId, kiosk: flag });
  },
  /** Electron BrowserWindow.isKiosk(). */
  isKiosk(windowId: number): Promise<IsKioskResponse> {
    return coreCall<IsKioskResponse>({ cmd: "is_kiosk", windowId });
  },
  /** Electron BrowserWindow.blur() — 창 포커스 해제. */
  blur(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "blur", windowId });
  },
  /** Electron BrowserWindow.isFocused(). */
  isFocused(windowId: number): Promise<IsFocusedResponse> {
    return coreCall<IsFocusedResponse>({ cmd: "is_focused", windowId });
  },
  /** Electron BrowserWindow.isVisible(). */
  isVisible(windowId: number): Promise<IsVisibleResponse> {
    return coreCall<IsVisibleResponse>({ cmd: "is_visible", windowId });
  },
  /** Electron BrowserWindow.setAlwaysOnTop(flag). */
  setAlwaysOnTop(windowId: number, flag: boolean): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "set_always_on_top", windowId, onTop: flag });
  },
  /** Electron BrowserWindow.isAlwaysOnTop(). */
  isAlwaysOnTop(windowId: number): Promise<IsAlwaysOnTopResponse> {
    return coreCall<IsAlwaysOnTopResponse>({ cmd: "is_always_on_top", windowId });
  },
  /** Electron BrowserWindow.getAllWindows() — 살아있는 top-level 창 id (view 제외). */
  getAllWindows(): Promise<GetAllWindowsResponse> {
    return coreCall<GetAllWindowsResponse>({ cmd: "get_all_windows" });
  },
  /** Electron BrowserWindow.getFocusedWindow() — 포커스 창 id 또는 null. */
  getFocusedWindow(): Promise<GetFocusedWindowResponse> {
    return coreCall<GetFocusedWindowResponse>({ cmd: "get_focused_window" });
  },

  // Phase 4-E: 편집 — 모두 main frame에 위임. 응답은 ok만.
  undo(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "undo", windowId });
  },
  redo(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "redo", windowId });
  },
  cut(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "cut", windowId });
  },
  copy(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "copy", windowId });
  },
  paste(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "paste", windowId });
  },
  selectAll(windowId: number): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "select_all", windowId });
  },

  /** 페이지 텍스트 검색. 첫 호출은 findNext=false, 이후 같은 단어 다음 매치는 true.
   *  결과 보고는 cef_find_handler_t로 (현재 미노출 — 추후 이벤트). */
  findInPage(
    windowId: number,
    text: string,
    options?: { forward?: boolean; matchCase?: boolean; findNext?: boolean },
  ): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({
      cmd: "find_in_page",
      windowId,
      text,
      forward: options?.forward ?? true,
      matchCase: options?.matchCase ?? false,
      findNext: options?.findNext ?? false,
    });
  },

  stopFindInPage(windowId: number, clearSelection = false): Promise<WindowOpResponse> {
    return coreCall<WindowOpResponse>({ cmd: "stop_find_in_page", windowId, clearSelection });
  },

  /** PDF로 인쇄 (Electron `webContents.printToPDF`). 코어가 CDP 완료까지 응답
   *  보류 → 단일 await 로 결과(`{success}`) 받음. EventBus `window:pdf-print-
   *  finished` emit 은 다른 구독자(다른 백엔드/창) 호환 유지.
   *
   *  defense-in-depth: 코어가 CDP 콜백 미발화(렌더러/GPU 크래시 등)로 응답을
   *  영영 안 보내는 극단 경우, SDK 타임아웃(기본 35s)이 `{success:false}`로
   *  settle 해 Promise 영구 hang 방지. 코어가 늦게 응답해도 무해(이미 settled). */
  async printToPDF(windowId: number, path: string, opts?: { timeoutMs?: number }): Promise<{ success: boolean }> {
    const r = await withDeferTimeout(
      coreCall<{ success?: boolean }>({ cmd: "print_to_pdf", windowId, path }),
      opts?.timeoutMs,
    );
    return { success: r?.success === true };
  },

  /** 페이지 스크린샷 PNG 저장 (Electron `webContents.capturePage` — CDP
   *  Page.captureScreenshot). 코어 deferred response 로 단일 await.
   *  base64 가 IPC 한도(64KB) 초과 가능해 path 파일 방식.
   *  rect 지정 시 부분 영역만; 미지정=전체. defense-in-depth 타임아웃은 printToPDF 동일. */
  async capturePage(
    windowId: number,
    path: string,
    rect?: { x: number; y: number; width: number; height: number },
    opts?: { timeoutMs?: number },
  ): Promise<{ success: boolean }> {
    const r = await withDeferTimeout(
      coreCall<{ success?: boolean }>({
        cmd: "capture_page", windowId, path,
        ...(rect ? { clipX: rect.x, clipY: rect.y, clipWidth: rect.width, clipHeight: rect.height } : {}),
      }),
      opts?.timeoutMs,
    );
    return { success: r?.success === true };
  },

  // ── Phase 17-A: WebContentsView ──
  // viewId는 windowId와 같은 풀이라 loadURL/executeJavaScript/openDevTools/setZoomFactor
  // 등 모든 webContents API에 viewId를 그대로 넘기면 동작.

  /** host 창 contentView 안에 새 view 합성 (Electron `WebContentsView`). 자동으로 host의
   *  view_children top에 추가됨 — 이후 addChildView로 z-order 변경 가능. bounds 미지정 시
   *  800x600 @ 0,0 (코어의 parseBoundsFromJson은 누락 키를 0으로 채워 SDK가 default 적용). */
  createView(opts: ViewOptions): Promise<CreateViewResponse> {
    return coreCall<CreateViewResponse>({
      cmd: "create_view",
      hostId: opts.hostId,
      url: opts.url,
      name: opts.name,
      x: opts.bounds?.x ?? 0,
      y: opts.bounds?.y ?? 0,
      width: opts.bounds?.width ?? 800,
      height: opts.bounds?.height ?? 600,
    });
  },

  /** view 파괴. host의 view_children에서 자동 제거 + `window:view-destroyed` 이벤트 */
  destroyView(viewId: number): Promise<ViewOpResponse> {
    return coreCall<ViewOpResponse>({ cmd: "destroy_view", viewId });
  },

  /** view를 host children에 추가/재배치. index 생략 시 top. 같은 view 재호출 시 위치 갱신
   *  (Electron WebContentsView idiom). host 이동은 미지원. */
  addChildView(hostId: number, viewId: number, index?: number): Promise<ViewOpResponse> {
    return coreCall<ViewOpResponse>({ cmd: "add_child_view", hostId, viewId, index });
  },

  /** view를 host children에서 분리 (destroy X). native에서 setHidden(true). 다시 addChildView
   *  로 같은 host에 붙일 수 있음. */
  removeChildView(hostId: number, viewId: number): Promise<ViewOpResponse> {
    return coreCall<ViewOpResponse>({ cmd: "remove_child_view", hostId, viewId });
  },

  /** addChildView(host, view, undefined) 편의 — Electron `setTopBrowserView` 동등 */
  setTopView(hostId: number, viewId: number): Promise<ViewOpResponse> {
    return coreCall<ViewOpResponse>({ cmd: "set_top_view", hostId, viewId });
  },

  /** view 위치/크기 변경. host contentView 좌표계 (top-left). */
  setViewBounds(viewId: number, bounds: SetBoundsArgs): Promise<ViewOpResponse> {
    return coreCall<ViewOpResponse>({ cmd: "set_view_bounds", viewId, ...bounds });
  },

  /** view 표시/숨김 토글. CEF host.was_hidden도 함께 호출 (렌더링/입력 일시정지) */
  setViewVisible(viewId: number, visible: boolean): Promise<ViewOpResponse> {
    return coreCall<ViewOpResponse>({ cmd: "set_view_visible", viewId, visible });
  },

  /** host의 child view id들을 z-order 순서로 조회 (0=bottom, 마지막=top) */
  getChildViews(hostId: number): Promise<GetChildViewsResponse> {
    return coreCall<GetChildViewsResponse>({ cmd: "get_child_views", hostId });
  },
};

/**
 * `windows.*`(raw windowId)의 객체지향 facade (Electron `BrowserWindow` 패리티).
 * 각 메서드는 `windows.<fn>(this.id, ...)` 로 위임 — 로직/응답 타입 무중복,
 * `windows` 변경에 자동 동기화(반환 타입은 위임으로 추론). view 합성
 * (createView/addChildView 등)은 host/view-id 다중 대상이라 `windows`
 * 네임스페이스에 유지(Electron 도 WebContentsView 별도).
 */
export class BrowserWindow {
  readonly #id: number;
  private constructor(id: number) {
    this.#id = id;
  }
  /** 후속 IPC/`send(_, { to })` 및 view host 인자로 쓰는 창 id. */
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
  /** 기존 windowId(예: 메인 창, 이벤트의 windowId)를 인스턴스로 래핑. */
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

  setTitle(title: string) {
    return windows.setTitle(this.#id, title);
  }
  setBounds(bounds: SetBoundsArgs) {
    return windows.setBounds(this.#id, bounds);
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
// clipboard — 시스템 클립보드 (Electron `clipboard.readText/writeText`)
// ============================================
// macOS NSPasteboard, Linux GTK clipboard, Windows CF_UNICODETEXT/CF_HTML.

export const powerMonitor = {
  /** 시스템 유휴 시간 (초). 활성 입력 후 0으로 리셋.
   *  Electron `powerMonitor.getSystemIdleTime()` 동등. */
  async getSystemIdleTime(): Promise<number> {
    const r = await coreCall<{ seconds: number }>({ cmd: "power_monitor_get_idle_time" });
    return r.seconds;
  },

  /** 화면 잠금이면 "locked", 유휴 시간 ≥ threshold(초)면 "idle", 아니면 "active".
   *  Electron `powerMonitor.getSystemIdleState(threshold)` 동등. */
  async getSystemIdleState(threshold: number): Promise<"active" | "idle" | "locked"> {
    const r = await coreCall<{ state: "active" | "idle" | "locked" }>({
      cmd: "power_monitor_get_idle_state",
      threshold,
    });
    return r.state;
  },

  /** Electron `powerMonitor.isOnBatteryPower()` — 현재 배터리 전원 여부.
   *  macOS IOKit / Windows GetSystemPowerStatus / Linux /sys. 정보 없으면 false. */
  async isOnBatteryPower(): Promise<boolean> {
    const r = await coreCall<{ onBattery: boolean }>({ cmd: "power_monitor_is_on_battery" });
    return r.onBattery === true;
  },
};

export const clipboard = {
  /** 클립보드의 plain text 읽기. 비어 있거나 non-text면 빈 문자열. */
  async readText(): Promise<string> {
    const r = await coreCall<{ text: string }>({ cmd: "clipboard_read_text" });
    return r.text ?? "";
  },

  /** 클립보드에 plain text 쓰기. 성공 시 true. */
  async writeText(text: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "clipboard_write_text", text });
    return r.success === true;
  },

  /** 클립보드 비우기. */
  async clear(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "clipboard_clear" });
    return r.success === true;
  },

  /** HTML read (NSPasteboard `public.html`). 비어 있거나 non-html이면 빈 문자열. */
  async readHTML(): Promise<string> {
    const r = await coreCall<{ html: string }>({ cmd: "clipboard_read_html" });
    return r.html ?? "";
  },

  /** HTML write — write 시 다른 type (text 등)도 함께 지움. */
  async writeHTML(html: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "clipboard_write_html", html });
    return r.success === true;
  },

  /** RTF read (Electron `clipboard.readRTF`). 비어 있거나 non-rtf면 빈 문자열. */
  async readRTF(): Promise<string> {
    const r = await coreCall<{ rtf: string }>({ cmd: "clipboard_read_rtf" });
    return r.rtf ?? "";
  },

  /** RTF write (Electron `clipboard.writeRTF`). 다른 type 지움. */
  async writeRTF(rtf: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "clipboard_write_rtf", rtf });
    return r.success === true;
  },

  /** 임의 UTI raw bytes 쓰기 (Electron `clipboard.writeBuffer(format, buffer)`).
   *  data는 base64 인코딩된 문자열 (raw ~8KB 한도). */
  async writeBuffer(format: string, data: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "clipboard_write_buffer", format, data });
    return r.success === true;
  },

  /** 임의 UTI raw bytes 읽기 (Electron `clipboard.readBuffer(format)`). base64 string 반환. */
  async readBuffer(format: string): Promise<string> {
    const r = await coreCall<{ data: string }>({ cmd: "clipboard_read_buffer", format });
    return r.data ?? "";
  },

  /** 클립보드에 주어진 format이 있는지 (Electron `clipboard.has(format)`).
   *  format은 macOS UTI ("public.utf8-plain-text", "public.html" 등). */
  async has(format: string): Promise<boolean> {
    const r = await coreCall<{ present: boolean }>({ cmd: "clipboard_has", format });
    return r.present === true;
  },

  /** 클립보드에 등록된 모든 format (UTI) 배열. */
  async availableFormats(): Promise<string[]> {
    const r = await coreCall<{ formats: string[] }>({ cmd: "clipboard_available_formats" });
    return r.formats ?? [];
  },

  /** PNG 이미지 쓰기 — base64 문자열. 다른 type 함께 지움. (Electron `writeImage`). */
  async writeImage(pngBase64: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "clipboard_write_image", data: pngBase64 });
    return r.success === true;
  },

  /** PNG 이미지 읽기 — base64 반환. PNG 아니면 빈 문자열. */
  async readImage(): Promise<string> {
    const r = await coreCall<{ data: string }>({ cmd: "clipboard_read_image" });
    return r.data ?? "";
  },

  /** TIFF 이미지 쓰기 — base64 문자열 (NSPasteboard `public.tiff`). writeImage 동형. */
  async writeTiff(tiffBase64: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "clipboard_write_tiff", data: tiffBase64 });
    return r.success === true;
  },

  /** TIFF 이미지 읽기 — base64 반환. TIFF 아니면 빈 문자열. */
  async readTiff(): Promise<string> {
    const r = await coreCall<{ data: string }>({ cmd: "clipboard_read_tiff" });
    return r.data ?? "";
  },
};

// ============================================
// notification — 시스템 알림 (Electron `Notification`)
// ============================================
// macOS UNUserNotificationCenter, Linux freedesktop Notifications D-Bus,
// Windows Shell_NotifyIcon balloon. macOS는 valid Bundle ID + Info.plist 필요.
// (suji dev 모드에선 알림 안 뜰 수 있음 — `.app` 번들 이후 정상). 첫 호출 시 OS 권한 요청.
//
// 클릭은 `notification:click {notificationId}` 이벤트로 수신 (suji.on 사용).

export interface NotificationOptions {
  title: string;
  body: string;
  /** 사운드 묻음 */
  silent?: boolean;
}

export const notification = {
  /** 플랫폼 지원 여부 — macOS bundle/권한, Linux daemon, Windows tray balloon 상태를 반영. */
  async isSupported(): Promise<boolean> {
    const r = await coreCall<{ supported: boolean }>({ cmd: "notification_is_supported" });
    return r.supported === true;
  },

  /** 알림 권한 요청 — 첫 호출 시 OS 다이얼로그. 이후 캐시. */
  async requestPermission(): Promise<boolean> {
    const r = await coreCall<{ granted: boolean }>({ cmd: "notification_request_permission" });
    return r.granted === true;
  },

  /** 알림 표시. 반환 `notificationId`로 close 가능. success=false면 권한/번들 문제. */
  async show(options: NotificationOptions): Promise<{ notificationId: string; success: boolean }> {
    return coreCall<{ notificationId: string; success: boolean }>({
      cmd: "notification_show",
      ...options,
    });
  },

  async close(notificationId: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "notification_close", notificationId });
    return r.success === true;
  },

  /** Electron `Notification` 전체 제거 — 표시/대기 모든 알림(macOS 실동작). */
  async removeAll(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "notification_remove_all" });
    return r.success === true;
  },
};

// ============================================
// tray — 시스템 트레이 아이콘 (Electron `Tray`)
// ============================================
// macOS NSStatusItem, Linux GTK StatusIcon, Windows Shell_NotifyIconW.
// macOS/Linux: iconPath + submenu/checkbox. Windows: flat HMENU + default icon.

export interface TrayMenuSeparator {
  type: "separator";
}

export interface TrayMenuItemSpec {
  type?: "item";
  /** 메뉴에 표시될 텍스트. */
  label: string;
  /** 클릭 시 emit될 이벤트 이름 — `tray:menu-click {trayId, click}` 페이로드의 click 필드. */
  click: string;
  enabled?: boolean;
}

export interface TrayMenuCheckbox {
  type: "checkbox";
  label: string;
  click: string;
  checked?: boolean;
  enabled?: boolean;
}

export interface TrayMenuSubmenu {
  type?: "submenu";
  label: string;
  enabled?: boolean;
  submenu: TrayMenuItem[];
}

export type TrayMenuItem = TrayMenuItemSpec | TrayMenuCheckbox | TrayMenuSeparator | TrayMenuSubmenu;

export interface TrayCreateOptions {
  /** 메뉴바에 표시될 텍스트. */
  title?: string;
  /** 마우스 호버 시 표시될 툴팁. */
  tooltip?: string;
  /** macOS/Linux tray icon 이미지 파일 경로. Windows는 현재 기본 아이콘을 사용. */
  iconPath?: string;
}

export const tray = {
  /** 새 시스템 트레이 아이콘 생성. 반환된 trayId로 이후 update/destroy. */
  async create(options: TrayCreateOptions = {}): Promise<{ trayId: number }> {
    return coreCall<{ trayId: number }>({ cmd: "tray_create", ...options });
  },

  async setTitle(trayId: number, title: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "tray_set_title", trayId, title });
    return r.success === true;
  },

  async setTooltip(trayId: number, tooltip: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "tray_set_tooltip", trayId, tooltip });
    return r.success === true;
  },

  /** 트레이 클릭 시 표시될 컨텍스트 메뉴 설정. macOS/Linux는 submenu/checkbox도 지원.
   *  메뉴 항목 클릭은 `suji.on('tray:menu-click', ({trayId, click}) => ...)` 로 수신. */
  async setMenu(trayId: number, items: TrayMenuItem[]): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "tray_set_menu", trayId, items });
    return r.success === true;
  },

  async destroy(trayId: number): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "tray_destroy", trayId });
    return r.success === true;
  },
};

// ============================================
// menu — macOS application menu customization
// ============================================
// App 메뉴(Quit/Hide 등)는 Suji가 유지하고, 전달한 top-level 메뉴가 그 뒤에 붙는다.
// 메뉴 항목 클릭은 `suji.on('menu:click', ({ click }) => ...)` 로 수신.

export interface MenuSeparator {
  type: "separator";
}

export interface MenuCommandItem {
  type?: "item";
  label: string;
  click: string;
  enabled?: boolean;
  /** Electron MenuItem.id — getMenuItemById 식별자(UI 효과 없음). */
  id?: string;
  /** Electron MenuItem.visible — false 면 항목 숨김(기본 true). macOS 실효, Win/Linux best-effort. */
  visible?: boolean;
  /** Electron MenuItem.accelerator — 예 "Cmd+Shift+K". macOS NSMenuItem keyEquivalent
   *  (단일 문자 키만; 특수키 best-effort). Win/Linux no-op. */
  accelerator?: string;
  /** Electron MenuItem.role — copy/paste/quit 등 표준 동작(설정 시 click 무시, 네이티브
   *  수행). macOS only(undo/redo/cut/copy/paste/pasteAndMatchStyle/selectAll/delete/
   *  minimize/zoom/close/togglefullscreen/quit). Win/Linux no-op. */
  role?: string;
}

export interface MenuCheckboxItem {
  type: "checkbox";
  label: string;
  click: string;
  checked?: boolean;
  enabled?: boolean;
  id?: string;
  visible?: boolean;
  accelerator?: string;
}

export interface MenuSubmenuItem {
  type?: "submenu";
  label: string;
  enabled?: boolean;
  submenu: MenuItem[];
  id?: string;
  visible?: boolean;
}

export type MenuItem = MenuCommandItem | MenuCheckboxItem | MenuSeparator | MenuSubmenuItem;

export const menu = {
  async setApplicationMenu(items: MenuItem[]): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "menu_set_application_menu", items });
    return r.success === true;
  },

  async resetApplicationMenu(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "menu_reset_application_menu" });
    return r.success === true;
  },

  /** 임의 위치 컨텍스트 메뉴 (Electron `Menu.popup({x?,y?})`). x/y 미지정 시
   *  현재 커서(화면 좌표, macOS bottom-up). 선택은 `suji.on('menu:click',
   *  ({click}) => ...)` 로 수신 (setApplicationMenu 와 동일). macOS NSMenu
   *  `popUpMenuPositioningItem:atLocation:inView:` — 동기 모달. */
  async popup(items: MenuItem[], opts: { x?: number; y?: number } = {}): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "menu_popup",
      items,
      ...(opts.x !== undefined ? { x: opts.x } : {}),
      ...(opts.y !== undefined ? { y: opts.y } : {}),
    });
    return r.success === true;
  },
};

// ============================================
// globalShortcut — system-wide hot keys (Electron `globalShortcut.*`)
// ============================================
// Accelerator syntax: "Cmd+Shift+K", "CommandOrControl+P", "Alt+F4". Trigger fires on
// `globalShortcut:trigger {accelerator, click}` via `suji.on`. macOS/Linux(X11)/Windows supported.

export const globalShortcut = {
  async register(accelerator: string, click: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "global_shortcut_register", accelerator, click });
    return r.success === true;
  },

  async unregister(accelerator: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "global_shortcut_unregister", accelerator });
    return r.success === true;
  },

  async unregisterAll(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "global_shortcut_unregister_all" });
    return r.success === true;
  },

  async isRegistered(accelerator: string): Promise<boolean> {
    const r = await coreCall<{ registered: boolean }>({ cmd: "global_shortcut_is_registered", accelerator });
    return r.registered === true;
  },
};

// ============================================
// shell — 외부 핸들러 호출 (Electron `shell.*`)
// ============================================
// macOS NSWorkspace/NSFileManager, Linux GIO/FileManager1/GDK, Windows ShellExecute/SHFileOperation.

export const shell = {
  /** URL을 시스템 기본 핸들러로 열기 (http(s) → 브라우저, mailto: → 메일 앱 등).
   *  잘못된 URL syntax면 false. */
  async openExternal(url: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "shell_open_external", url });
    return r.success === true;
  },

  /** Finder/탐색기에서 파일/폴더 reveal — 부모 폴더 열리고 항목 선택. 경로 없으면 false. */
  async showItemInFolder(path: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "shell_show_item_in_folder", path });
    return r.success === true;
  },

  /** 시스템 비프음. */
  async beep(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "shell_beep" });
    return r.success === true;
  },

  /** 휴지통으로 이동. macOS NSFileManager `trashItemAtURL:`. 실패하면 false. */
  async trashItem(path: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "shell_trash_item", path });
    return r.success === true;
  },

  /** 파일/폴더를 기본 앱으로 열기 (`openExternal`은 URL용, 이건 로컬 path용).
   *  존재하지 않는 경로는 false. macOS NSWorkspace `openURL:` (file://). */
  async openPath(path: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "shell_open_path", path });
    return r.success === true;
  },
};

export const nativeImage = {
  /** 이미지 파일 → 크기 {width, height} (point 단위, NSImage). 파일 없거나 디코딩 실패는 0/0.
   *  Electron `nativeImage.createFromPath(path).getSize()` 동등. */
  async getSize(path: string): Promise<{ width: number; height: number }> {
    const r = await coreCall<{ width: number; height: number }>({ cmd: "native_image_get_size", path });
    return { width: r.width, height: r.height };
  },

  /** 이미지 파일 → PNG base64 (raw ~8KB 한도, 작은 아이콘용 1차).
   *  Electron `nativeImage.createFromPath(path).toPNG()` → base64.toString('base64'). */
  async toPng(path: string): Promise<string> {
    const r = await coreCall<{ data: string }>({ cmd: "native_image_to_png", path });
    return r.data ?? "";
  },

  /** 이미지 파일 → JPEG base64. quality 0~100 (기본 90). */
  async toJpeg(path: string, quality: number = 90): Promise<string> {
    const r = await coreCall<{ data: string }>({ cmd: "native_image_to_jpeg", path, quality });
    return r.data ?? "";
  },
};

export type ThemeSource = "system" | "light" | "dark";

export const nativeTheme = {
  /** 시스템 다크 모드 활성 여부 (Electron `nativeTheme.shouldUseDarkColors`).
   *  macOS NSApp.effectiveAppearance.name이 Dark 계열이면 true. */
  async shouldUseDarkColors(): Promise<boolean> {
    const r = await coreCall<{ dark: boolean }>({ cmd: "native_theme_should_use_dark_colors" });
    return r.dark === true;
  },

  /** `themeSource = "light" | "dark" | "system"` setter (Electron 동등).
   *  system은 OS 따름 (NSApp.appearance = nil), light/dark는 NSAppearance 강제.
   *  잘못된 값은 false. */
  async setThemeSource(source: ThemeSource): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "native_theme_set_source", source });
    return r.success === true;
  },

  /** Electron `nativeTheme.themeSource` (getter) — 마지막 설정값(기본 "system"). */
  async getThemeSource(): Promise<ThemeSource> {
    const r = await coreCall<{ source: ThemeSource }>({ cmd: "native_theme_get_source" });
    return r.source;
  },
};

// ============================================
// fs — 파일 시스템 API (text/stat/mkdir/readdir, Electron `fs.promises.*`)
// ============================================

export type FileType =
  | "file"
  | "directory"
  | "symlink"
  | "blockDevice"
  | "characterDevice"
  | "fifo"
  | "socket"
  | "whiteout"
  | "door"
  | "eventPort"
  | "unknown";

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
    const r = await coreCall<{ success: boolean; text: string; error?: string }>({ cmd: "fs_read_file", path });
    if (r.success !== true) throw new Error(r.error ?? "fs_read_file failed");
    return r.text;
  },

  async writeFile(path: string, text: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "fs_write_file", path, text });
    return r.success === true;
  },

  async stat(path: string): Promise<FsStat> {
    const r = await coreCall<FsStat & { error?: string }>({ cmd: "fs_stat", path });
    if (r.success !== true) throw new Error(r.error ?? "fs_stat failed");
    return r;
  },

  async mkdir(path: string, options: { recursive?: boolean } = {}): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "fs_mkdir", path, recursive: options.recursive === true });
    return r.success === true;
  },

  async readdir(path: string): Promise<FsDirEntry[]> {
    const r = await coreCall<{ success: boolean; entries: FsDirEntry[]; error?: string }>({ cmd: "fs_readdir", path });
    if (r.success !== true) throw new Error(r.error ?? "fs_readdir failed");
    return r.entries;
  },

  /** Remove `path`. `recursive` deletes directories; `force` ignores not-found (matches `node:fs.rm`). */
  async rm(path: string, options: { recursive?: boolean; force?: boolean } = {}): Promise<boolean> {
    const r = await coreCall<{ success: boolean; error?: string }>({
      cmd: "fs_rm",
      path,
      recursive: options.recursive === true,
      force: options.force === true,
    });
    if (r.success !== true) throw new Error(r.error ?? "fs_rm failed");
    return true;
  },
};

// ============================================
// dialog — Native modal dialogs (Electron `dialog.*`)
// ============================================
// macOS NSOpenPanel/NSSavePanel/NSAlert, Linux GTK, Windows native dialogs.
//
// 모든 dialog는 Promise. 내부적으로 `runModal` 동기 호출이라 modal 동안 부모 창 입력 차단.

export type MessageBoxStyle = "none" | "info" | "warning" | "error" | "question";

export interface MessageBoxOptions {
  /** 아이콘 / 시스템 사운드 결정. 기본 "none". */
  type?: MessageBoxStyle;
  /** 창 타이틀. */
  title?: string;
  /** 주 메시지 (필수에 가까움 — 빈 값이면 macOS가 자동 텍스트). */
  message: string;
  /** 보조 메시지 (작은 폰트). */
  detail?: string;
  /** 버튼 레이블 배열. 빈 배열이면 ["OK"]. */
  buttons?: string[];
  /** Enter로 활성화될 버튼 index (기본: 첫 번째). */
  defaultId?: number;
  /** ESC로 활성화될 버튼 index. */
  cancelId?: number;
  /** suppression checkbox 레이블. 빈 문자열이면 체크박스 비활성. */
  checkboxLabel?: string;
  /** 체크박스 초기 상태. */
  checkboxChecked?: boolean;
}

export interface FileFilter {
  /** 필터 그룹 표시명. 플랫폼별 native file filter에 매핑된다. */
  name: string;
  /** 허용 확장자 (점 없이): `["jpg", "png"]`. `"*"`은 모든 파일. */
  extensions: string[];
}

export type OpenDialogProperty =
  | "openFile"
  | "openDirectory"
  | "multiSelections"
  | "showHiddenFiles"
  | "createDirectory"
  | "noResolveAliases"
  | "treatPackageAsDirectory";

export interface OpenDialogOptions {
  title?: string;
  /** 초기 디렉토리 (또는 파일명 포함 경로 — 마지막 segment가 파일명으로 들어감). */
  defaultPath?: string;
  /** 확인 버튼 레이블 ("Open" 대신). */
  buttonLabel?: string;
  /** 다이얼로그 상단 메시지 (macOS 한정 표시). */
  message?: string;
  filters?: FileFilter[];
  /** 기본: ["openFile"]. */
  properties?: OpenDialogProperty[];
}

export type SaveDialogProperty =
  | "showHiddenFiles"
  | "createDirectory"
  | "treatPackageAsDirectory";

export interface SaveDialogOptions {
  title?: string;
  defaultPath?: string;
  buttonLabel?: string;
  message?: string;
  /** 파일명 입력란의 레이블. */
  nameFieldLabel?: string;
  /** macOS Finder 태그 입력 필드 표시. */
  showsTagField?: boolean;
  filters?: FileFilter[];
  properties?: SaveDialogProperty[];
}

/// Dialog 함수의 Electron 두-인자 오버로드 분해. 첫 인자가 number면 windowId(=sheet 부모),
/// 아니면 options 단일 인자로 free-floating modal.
function splitDialogArgs<T extends object>(
  arg1: T | number,
  arg2: T | undefined,
): { windowId?: number; options: T } {
  if (typeof arg1 === "number") {
    return { windowId: arg1, options: (arg2 ?? ({} as T)) as T };
  }
  return { options: arg1 };
}

export interface CookieDescriptor {
  url: string;
  name: string;
  value?: string;
  domain?: string;
  path?: string;
  secure?: boolean;
  httponly?: boolean;
  /** unix epoch second. 0 또는 미지정이면 세션 쿠키. */
  expires?: number;
}

export interface CookieRecord {
  name: string;
  value: string;
  domain: string;
  path: string;
  secure: boolean;
  httponly: boolean;
  /** unix epoch second. 0이면 세션 쿠키. */
  expires: number;
}

export interface CookieFilter {
  /** 빈 문자열 또는 미지정이면 모든 쿠키 (visit_all_cookies). */
  url?: string;
  /** httpOnly 쿠키 포함 여부 (visit_url_cookies 시). 기본 true. */
  includeHttpOnly?: boolean;
}

/** 렌더러(웹 콘텐츠)가 권한을 요청할 때 핸들러가 받는 정보. */
export interface PermissionRequestDetails {
  /** 응답 매칭용 CEF prompt id. */
  permissionId: number;
  /** 요청 origin (예: "https://example.com"). file:// 페이지는 빈 문자열일 수 있음. */
  origin: string;
  /** 요청된 권한 이름 배열 (예: ["geolocation"], ["notifications","clipboard"]). */
  permissions: string[];
}

/** 권한 요청 핸들러 — true 반환 시 허용(grant), false 반환 시 거부(deny).
 *  async 가능(커스텀 UI 등). 한 번에 1 핸들러만 active. */
export type PermissionRequestHandler = (
  details: PermissionRequestDetails,
) => boolean | Promise<boolean>;

let activePermissionOff: (() => void) | null = null;

export const session = {
  /** 모든 cookie 삭제 (Electron `session.clearStorageData({storages:["cookies"]})`).
   *  fire-and-forget — 실제 cleanup은 비동기. */
  async clearCookies(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "session_clear_cookies" });
    return r.success === true;
  },

  /** disk store flush (Electron `session.cookies.flushStore`). */
  async flushStore(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "session_flush_store" });
    return r.success === true;
  },

  /**
   * Electron `session.setProxy(config)` — Chromium "proxy" preference 설정.
   * mode 미지정/`"direct"` → 프록시 해제. `proxyRules`: `"host:port"` 또는
   * `"http=foo:80;https=bar:80"`. 이후 요청에 적용. fire-and-forget(설정 성공 bool).
   */
  async setProxy(config: {
    mode?: "direct" | "auto_detect" | "pac_script" | "fixed_servers" | "system";
    proxyRules?: string;
    proxyBypassRules?: string;
    pacScript?: string;
  }): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "session_set_proxy",
      mode: config.mode ?? "",
      proxyRules: config.proxyRules ?? "",
      proxyBypassRules: config.proxyBypassRules ?? "",
      pacScript: config.pacScript ?? "",
    });
    return r.success === true;
  },

  /**
   * Electron `session.setPermissionRequestHandler(handler)` 동등. 렌더러(웹 콘텐츠)가
   * geolocation/notifications/clipboard/midi-sysex/idle-detection/window-management 등
   * 권한을 요청하면 handler 가 호출돼 `true`(허용)/`false`(거부)를 결정한다. async 가능
   * (커스텀 UI 등 — 타임아웃 없음. 핸들러가 응답할 때까지 요청 hold).
   *
   * `handler` 가 throw 하거나 비-bool 반환 시 **거부**(deny, 안전 기본). `null` 전달 시
   * 핸들러 해제(이후 CEF 기본 처리). 한 번에 1 핸들러만 active — 재등록 시 이전 detach.
   *
   * 정직 경계: camera/mic(getUserMedia)는 별도 CEF 경로(media access)라 이 핸들러
   * 미포함 — on_show_permission_prompt 가 덮는 권한군 대상.
   */
  async setPermissionRequestHandler(
    handler: PermissionRequestHandler | null,
  ): Promise<void> {
    if (activePermissionOff) {
      activePermissionOff();
      activePermissionOff = null;
    }
    if (!handler) {
      await coreCall({ cmd: "session_set_permission_handler", enabled: false });
      return;
    }
    activePermissionOff = on("session:permission-request", (payload) => {
      let ev: PermissionRequestDetails;
      try {
        ev = typeof payload === "string" ? JSON.parse(payload) : payload;
      } catch {
        // malformed payload: 응답할 permissionId 가 없음 — 무시(핸들러 안 깨지게).
        return;
      }
      let settled = false;
      const respond = (granted: boolean) => {
        if (settled) return;
        settled = true;
        void coreCall({
          cmd: "session_permission_response",
          permissionId: ev.permissionId,
          granted,
        });
      };
      // 동기 throw / async reject 모두 deny 로 수렴(안전 기본).
      Promise.resolve()
        .then(() => handler(ev))
        .then((granted) => respond(granted === true))
        .catch(() => respond(false));
    });
    await coreCall({ cmd: "session_set_permission_handler", enabled: true });
  },

  /**
   * IndexedDB/localStorage/cache 삭제 (Electron `session.clearStorageData`).
   * origin 미지정 → 전역 HTTP 캐시만(웹 플랫폼상 origin 없이 storage 일괄
   * 삭제 불가 — 호출부가 자기 앱 origin 전달 시 그 origin storage 삭제).
   * storageTypes 기본 "all" (CDP 콤마구분: local_storage,indexeddb,...).
   */
  async clearStorageData(origin = "", storageTypes = "all"): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "session_clear_storage_data", origin, storageTypes,
    });
    return r.success === true;
  },

  /** Electron `session.cookies.set`. expires는 unix epoch second (0 → 세션 쿠키). */
  async setCookie(cookie: CookieDescriptor): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "session_set_cookie",
      url: cookie.url,
      name: cookie.name,
      value: cookie.value ?? "",
      domain: cookie.domain ?? "",
      path: cookie.path ?? "",
      secure: cookie.secure ?? false,
      httponly: cookie.httponly ?? false,
      expires: cookie.expires ?? 0,
    });
    return r.success === true;
  },

  /** Electron `session.cookies.remove`. url+name 매칭. */
  async removeCookies(url: string, name: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "session_remove_cookies",
      url,
      name,
    });
    return r.success === true;
  },

  /** Electron `session.cookies.get`. visitor 패턴 — `session:cookies-result` 이벤트로
   *  결과 도착, requestId 매칭으로 promise resolve.
   *
   *  Race-safe: listener 먼저 등록하지만 visit이 invoke 응답보다 빨리 emit하면 id=0 상태로
   *  도달. 그 emit을 buffer해두고 invoke 응답으로 id 받은 뒤 매칭.
   *
   *  Timeout 1초 — cookies 0개 case는 native visitor가 호출 안 돼 emit이 없으므로
   *  timeout으로 빈 array 반환. 1초면 사용자 느끼는 지연 충분히 짧고 visit 비동기성
   *  여유도 보장. */
  async getCookies(filter: CookieFilter = {}): Promise<CookieRecord[]> {
    return new Promise<CookieRecord[]>((resolve) => {
      let id = 0;
      let pending: { requestId: number; cookies: CookieRecord[] } | null = null;
      const timer = setTimeout(() => {
        off();
        resolve([]);
      }, 1000);
      const off = on("session:cookies-result", (data) => {
        const raw = typeof data === "string" ? JSON.parse(data) : data;
        const ev = raw as { requestId: number; cookies: CookieRecord[] };
        if (id === 0) {
          pending = ev;
          return;
        }
        if (ev.requestId !== id) return;
        clearTimeout(timer);
        off();
        resolve(ev.cookies ?? []);
      });
      coreCall<{ success: boolean; requestId: number }>({
        cmd: "session_get_cookies",
        url: filter.url ?? "",
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

export const dialog = {
  /** 메시지 박스. 첫 인자에 windowId(number) 주면 sheet — 그 창에 부착. 없으면 free-floating.
   *  반환: 사용자가 클릭한 버튼 index + checkbox 상태. */
  async showMessageBox(
    arg1: MessageBoxOptions | number,
    arg2?: MessageBoxOptions,
  ): Promise<{ response: number; checkboxChecked: boolean }> {
    const { windowId, options } = splitDialogArgs(arg1, arg2);
    return coreCall<{ response: number; checkboxChecked: boolean }>({
      cmd: "dialog_show_message_box",
      ...(windowId !== undefined ? { windowId } : {}),
      ...options,
    });
  },

  /** 단순 에러 popup (NSAlert critical style + OK 버튼). 응답 없음 — Electron 동등. */
  async showErrorBox(title: string, content: string): Promise<void> {
    await coreCall({ cmd: "dialog_show_error_box", title, content });
  },

  /** 파일/폴더 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePaths:[]}`. */
  async showOpenDialog(
    arg1: OpenDialogOptions | number = {},
    arg2?: OpenDialogOptions,
  ): Promise<{ canceled: boolean; filePaths: string[] }> {
    const { windowId, options } = splitDialogArgs(arg1, arg2);
    return coreCall<{ canceled: boolean; filePaths: string[] }>({
      cmd: "dialog_show_open_dialog",
      ...(windowId !== undefined ? { windowId } : {}),
      ...options,
    });
  },

  /** 저장 경로 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePath:""}`. */
  async showSaveDialog(
    arg1: SaveDialogOptions | number = {},
    arg2?: SaveDialogOptions,
  ): Promise<{ canceled: boolean; filePath: string }> {
    const { windowId, options } = splitDialogArgs(arg1, arg2);
    return coreCall<{ canceled: boolean; filePath: string }>({
      cmd: "dialog_show_save_dialog",
      ...(windowId !== undefined ? { windowId } : {}),
      ...options,
    });
  },

  // ── Sync 변종 — Electron 호환. modal 동안 부모 창 입력 차단되는 건 async와 동일.
  // JS 측 응답 shape만 다름: number / string[] | undefined / string | undefined.

  /** Sync 변종 — `response: number`만 반환. windowId 첫 인자 지원. */
  async showMessageBoxSync(
    arg1: MessageBoxOptions | number,
    arg2?: MessageBoxOptions,
  ): Promise<number> {
    const { windowId, options } = splitDialogArgs(arg1, arg2);
    const r = await coreCall<{ response: number }>({
      cmd: "dialog_show_message_box",
      ...(windowId !== undefined ? { windowId } : {}),
      ...options,
    });
    return r.response;
  },

  /** Sync 변종 — 취소면 `undefined`, 아니면 `string[]`. windowId 첫 인자 지원. */
  async showOpenDialogSync(
    arg1: OpenDialogOptions | number = {},
    arg2?: OpenDialogOptions,
  ): Promise<string[] | undefined> {
    const { windowId, options } = splitDialogArgs(arg1, arg2);
    const r = await coreCall<{ canceled: boolean; filePaths: string[] }>({
      cmd: "dialog_show_open_dialog",
      ...(windowId !== undefined ? { windowId } : {}),
      ...options,
    });
    return r.canceled ? undefined : r.filePaths;
  },

  /** Sync 변종 — 취소면 `undefined`, 아니면 `string`. windowId 첫 인자 지원. */
  async showSaveDialogSync(
    arg1: SaveDialogOptions | number = {},
    arg2?: SaveDialogOptions,
  ): Promise<string | undefined> {
    const { windowId, options } = splitDialogArgs(arg1, arg2);
    const r = await coreCall<{ canceled: boolean; filePath: string }>({
      cmd: "dialog_show_save_dialog",
      ...(windowId !== undefined ? { windowId } : {}),
      ...options,
    });
    return r.canceled ? undefined : r.filePath;
  },
};

// ============================================
// webRequest — URL glob blocklist (Electron `session.webRequest`)
// ============================================
// declarative 패턴만 지원 — JS callback decision은 후속 (sync IPC deadlock 방지).
// 매칭 시 fetch/XHR/이미지 등 모든 요청 cancel. `*` wildcard만 지원.
//
// 이벤트 (suji.on(...)으로 listen):
//   `webRequest:before-request` — { url } (모든 요청, 자체 페이지 asset/HMR 포함 — 노이즈
//                                   많음. consumer가 prefix/regex로 필터 권장)
//   `webRequest:completed` — { url, statusCode, requestStatus, receivedBytes }
//                             requestStatus: 0=UNKNOWN 1=SUCCESS 2=IO_PENDING 3=CANCELED 4=FAILED.
//                             blocklist 매칭 차단 시 statusCode=0 + requestStatus=FAILED(4)
//                             — CEF가 handler-initiated cancel을 FAILED로 보고 (CANCELED는
//                             user-initiated만).

export interface WebRequestDetails {
  url: string;
  /** resolve용 internal id — `webRequest.resolve`에 그대로 전달. */
  id: number;
}

export interface WebRequestDecision {
  /** true면 요청 cancel, false/생략이면 통과. */
  cancel?: boolean;
}

type WebRequestListener = (
  details: WebRequestDetails,
  callback: (decision: WebRequestDecision) => void,
) => void;

let activeListenerOff: (() => void) | null = null;

export const webRequest = {
  /** blocklist 패턴 list 갱신 (전체 교체). 빈 list = 모든 요청 통과. 최대 32개, 256자/패턴. */
  async setBlockedUrls(patterns: string[]): Promise<number> {
    const r = await coreCall<{ count: number }>({
      cmd: "web_request_set_blocked_urls",
      patterns,
    });
    return r.count;
  },

  /**
   * Electron `session.webRequest.onBeforeRequest({urls}, listener)` 동등.
   * filter.urls glob 매칭 시 listener가 비동기 결정 — `callback({ cancel: true })`로 차단,
   * `callback({})`로 통과.
   *
   * **timeout fallback**: listener 가 decision callback 을 `options.timeoutMs`(기본
   * 5000ms) 내 호출 안 하거나 동기 throw 하면 자동으로 통과(fail-open, Electron 도
   * listener 오작동으로 요청을 막지 않음)시켜 네이티브 RV_CONTINUE_ASYNC hold 를
   * 해제 — 요청 영구 hang 방지(cookie SDK 타임아웃 선례 동형). `timeoutMs <= 0`
   * 이면 무제한(opt-out, 기존 동작). double-resolve 는 will-request 발화마다
   * 새 클로저의 per-event `settled` 가드. 유일 예외: payload 파싱 실패 시 resolve
   * 할 id 가 없어 그 1건은 무시(네이티브 hold 유지) — 정상 경로 외 core 버그 신호.
   *
   * 한 번에 1 listener만 active — 새로 등록 시 이전 listener detach.
   * filter null 또는 빈 listener는 detach.
   */
  async onBeforeRequest(
    filter: { urls: string[] } | null,
    listener: WebRequestListener | null,
    options?: { timeoutMs?: number },
  ): Promise<void> {
    if (activeListenerOff) {
      activeListenerOff();
      activeListenerOff = null;
    }
    const patterns = filter && listener ? filter.urls : [];
    await coreCall({ cmd: "web_request_set_listener_filter", patterns });
    if (!listener || patterns.length === 0) return;
    const timeoutMs = options?.timeoutMs ?? 5000;
    activeListenerOff = on("webRequest:will-request", (payload) => {
      let ev: { url: string; id: number };
      try {
        ev = typeof payload === "string" ? JSON.parse(payload) : payload;
      } catch {
        // malformed payload: resolve할 id가 없음 — 무시 (listener 안 깨지게).
        return;
      }
      let settled = false;
      let timer: ReturnType<typeof setTimeout> | null = null;
      const resolveOnce = (cancel: boolean) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        void coreCall({ cmd: "web_request_resolve", id: ev.id, cancel });
      };
      if (timeoutMs > 0) {
        // 미응답 → 자동 통과(fail-open). 네이티브 hold 해제.
        timer = setTimeout(() => resolveOnce(false), timeoutMs);
      }
      try {
        listener({ url: ev.url, id: ev.id }, (decision) => resolveOnce(!!decision?.cancel));
      } catch {
        // listener 동기 throw → fail-open(통과). hang 방지.
        resolveOnce(false);
      }
    });
  },

  /** listener 직접 detach (파라미터 없는 onBeforeRequest와 동등). */
  async clearListener(): Promise<void> {
    return this.onBeforeRequest(null, null);
  },
};

// ============================================
// screen — 디스플레이 정보 (Electron `screen.getAllDisplays`)
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
  cmd: "screen_get_display_matching";
  /** getAllDisplays 배열 index. 디스플레이 없으면 -1. */
  index: number;
}

export const screen = {
  /** 연결된 모든 모니터의 bounds/scale 정보. macOS NSScreen 기반. */
  async getAllDisplays(): Promise<Display[]> {
    const r = await coreCall<{ displays: Display[] }>({ cmd: "screen_get_all_displays" });
    return r.displays;
  },

  /** 마우스 포인터 화면 좌표 (macOS NSEvent.mouseLocation). bottom-up 좌표계. */
  async getCursorScreenPoint(): Promise<{ x: number; y: number }> {
    const r = await coreCall<{ x: number; y: number }>({ cmd: "screen_get_cursor_point" });
    return { x: r.x, y: r.y };
  },

  /** (x,y)를 포함하는 display index. 어느 display에도 포함 안 되면 -1. */
  async getDisplayNearestPoint(point: { x: number; y: number }): Promise<number> {
    const r = await coreCall<{ index: number }>({ cmd: "screen_get_display_nearest_point", x: point.x, y: point.y });
    return r.index;
  },

  /** Primary display 객체 반환 (없으면 null) — getAllDisplays.find(isPrimary) wrapper. */
  async getPrimaryDisplay(): Promise<Display | null> {
    const all = await this.getAllDisplays();
    return all.find((d) => d.isPrimary) ?? all[0] ?? null;
  },

  /**
   * rect(보통 창 bounds)와 가장 많이 겹치는 Display (Electron `screen.getDisplayMatching`).
   * 듀얼/멀티모니터에서 "이 창이 있는 모니터" 판정 — 겹침 없으면 중심 최근접.
   * 매칭 계산은 코어 cmd `screen_get_display_matching`(전 언어 SDK 공유)이 수행하고,
   * 여기선 그 index 로 getAllDisplays 에서 Display 를 해석해 반환.
   */
  async getDisplayMatching(rect: {
    x: number;
    y: number;
    width: number;
    height: number;
  }): Promise<Display | null> {
    const r = await coreCall<DisplayMatchingResponse>({ cmd: "screen_get_display_matching", ...rect });
    if (r.index < 0) return null;
    return (await this.getAllDisplays())[r.index] ?? null;
  },
};

/** Electron `desktopCapturer.getSources` 소스. ⚠️ thumbnail/appIcon 미포함. */
export interface DesktopCapturerSource {
  id: string;
  name: string;
  type: "screen" | "window";
  x: number;
  y: number;
  width: number;
  height: number;
  displayId?: number;
}

export const desktopCapturer = {
  /**
   * 화면/창 소스 열거 (Electron `desktopCapturer.getSources`). types 기본
   * 둘 다. ⚠️ Electron 과 달리 thumbnail/appIcon 미포함 — Screen Recording
   * TCC 권한 + base64 IPC 한도 때문(소스 열거만, 썸네일은 후속).
   */
  async getSources(
    opts: { types?: Array<"screen" | "window"> } = {},
  ): Promise<DesktopCapturerSource[]> {
    const types = (opts.types ?? ["screen", "window"]).join(",");
    const r = await coreCall<{ sources: DesktopCapturerSource[] }>({
      cmd: "desktop_capturer_get_sources", types,
    });
    return r.sources;
  },

  /**
   * 소스(`getSources()` 의 `id` — "screen:N:0"/"window:N:0") 썸네일을 PNG 로
   * `path` 에 캡처(파일경로 — base64 IPC 한도 우회, capture_page 동형).
   * ⚠️ Screen Recording TCC 권한 필요 — 미부여 시 `false`(정직 경계).
   */
  async captureThumbnail(sourceId: string, path: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "desktop_capturer_capture_thumbnail", sourceId, path,
    });
    return r.success === true;
  },
};

// ============================================
// crashReporter — CEF Crashpad/Breakpad bridge (Electron `crashReporter`)
// ============================================

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
    const r = await coreCall<{ success: boolean }>({ cmd: "crash_reporter_start", ...options });
    return r.success === true;
  },

  async getParameters(): Promise<Record<string, string>> {
    const r = await coreCall<{ parameters: Record<string, string> }>({ cmd: "crash_reporter_get_parameters" });
    return r.parameters ?? {};
  },

  async addExtraParameter(key: string, value: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "crash_reporter_add_extra_parameter", key, value });
    return r.success === true;
  },

  async removeExtraParameter(key: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "crash_reporter_remove_extra_parameter", key });
    return r.success === true;
  },

  async getUploadToServer(): Promise<boolean> {
    const r = await coreCall<{ uploadToServer: boolean }>({ cmd: "crash_reporter_get_upload_to_server" });
    return r.uploadToServer === true;
  },

  async setUploadToServer(uploadToServer: boolean): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "crash_reporter_set_upload_to_server", uploadToServer });
    return r.success === true;
  },

  async getUploadedReports(): Promise<CrashReport[]> {
    const r = await coreCall<{ reports: CrashReport[] }>({ cmd: "crash_reporter_get_uploaded_reports" });
    return r.reports ?? [];
  },

  async getLastCrashReport(): Promise<CrashReport | null> {
    const r = await coreCall<{ report: CrashReport | null }>({ cmd: "crash_reporter_get_last_crash_report" });
    return r.report ?? null;
  },
};

// ============================================
// autoUpdater — manifest 기반 업데이트 확인 + artifact download/checksum 검증
// ============================================
// staged artifact를 검증한 뒤 앱 종료 후 target을 교체하는 quitAndInstall까지 제공한다.

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

export type AutoUpdaterInstallFormat = "auto" | "app" | "zip" | "dmg" | "appimage" | "raw" | "deb";

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
  format: Exclude<AutoUpdaterInstallFormat, "auto">;
  action: "quitAndInstall" | "systemPackage";
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
  if (typeof input !== "string") return input;
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
    return coreCall<AutoUpdaterCheckResult>({
      cmd: "auto_updater_check_update",
      currentVersion,
      latestVersion: manifest.version,
      url: manifest.url,
      sha256: manifest.sha256 ?? "",
      notes: manifest.notes ?? "",
      pubDate: manifest.pubDate ?? "",
    });
  },

  /** 다운로드된 파일의 SHA-256을 검증. mismatch면 success=false와 actualSha256 반환. */
  async verifyFile(path: string, sha256: string): Promise<AutoUpdaterVerifyResult> {
    return coreCall<AutoUpdaterVerifyResult>({
      cmd: "auto_updater_verify_file",
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
    const url = typeof input === "string" ? input : input.url;
    const sha256 = options.sha256 ?? (typeof input === "string" ? "" : input.sha256 ?? "");
    return coreCall<AutoUpdaterDownloadResult>({
      cmd: "auto_updater_download_artifact",
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
    const path = typeof input === "string" ? input : input.path;
    const sha256 = options.sha256 ?? (typeof input === "string" ? "" : input.sha256 ?? "");
    return coreCall<AutoUpdaterPrepareInstallResult>({
      cmd: "auto_updater_prepare_install",
      path,
      target: options.target ?? "",
      stageDir: options.stageDir ?? "",
      format: options.format ?? "auto",
      sha256,
    });
  },

  /** staged artifact를 앱 종료 후 target으로 교체하고 quit을 요청. */
  async quitAndInstall(
    input: string | AutoUpdaterDownloadResult | AutoUpdaterPrepareInstallResult,
    options: AutoUpdaterQuitAndInstallOptions = {},
  ): Promise<AutoUpdaterQuitAndInstallResult> {
    const path = typeof input === "string" ? input : input.path;
    const sha256 = options.sha256 ?? (typeof input === "string" ? "" : "sha256" in input ? input.sha256 ?? "" : "");
    const target = options.target ?? (typeof input === "string" ? "" : "target" in input ? input.target ?? "" : "");
    return coreCall<AutoUpdaterQuitAndInstallResult>({
      cmd: "auto_updater_quit_and_install",
      path,
      target,
      sha256,
      relaunch: options.relaunch ?? true,
      helperPath: options.helperPath ?? "",
    });
  },
};

// ============================================
// powerSaveBlocker — 화면/시스템 sleep 차단 (Electron `powerSaveBlocker`)
// ============================================

export type PowerSaveBlockerType = "prevent_app_suspension" | "prevent_display_sleep";

export const powerSaveBlocker = {
  /** sleep 차단 시작. 반환된 id로 stop. 0이면 실패. */
  async start(type: PowerSaveBlockerType): Promise<number> {
    const r = await coreCall<{ id: number }>({ cmd: "power_save_blocker_start", type });
    return r.id;
  },

  /** start로 받은 id를 해제. unknown id는 false. */
  async stop(id: number): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "power_save_blocker_stop", id });
    return r.success === true;
  },
};

// ============================================
// safeStorage — macOS Keychain 저장소 (Electron `safeStorage`의 키체인 변종)
// ============================================
// Electron API는 encryptString/decryptString 패턴이지만 Suji는 service+account
// 키체인 직접 wrap. macOS만 동작 (Linux libsecret / Win DPAPI는 후속).

export const safeStorage = {
  /** service+account에 utf-8 value 저장. 같은 키면 update (idempotent). */
  async setItem(service: string, account: string, value: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "safe_storage_set",
      service,
      account,
      value,
    });
    return r.success === true;
  },

  /** service+account로 저장된 value read. 없으면 빈 문자열. */
  async getItem(service: string, account: string): Promise<string> {
    const r = await coreCall<{ value: string }>({
      cmd: "safe_storage_get",
      service,
      account,
    });
    return r.value;
  },

  /** service+account 삭제. 존재하지 않아도 true (idempotent). */
  async deleteItem(service: string, account: string): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({
      cmd: "safe_storage_delete",
      service,
      account,
    });
    return r.success === true;
  },
};

// ============================================
// app — 애플리케이션 레벨 API (dock 바운스 등 NSApp wrap)
// ============================================
// Electron `app.requestUserAttention` / `app.dock.setBadge` 동등 (macOS).

export type AppPathName =
  | "home"
  | "appData"
  | "userData"
  | "temp"
  | "desktop"
  | "documents"
  | "downloads";

export const app = {
  /** suji.json `app.name` 반환 (Electron `app.getName`). */
  async getName(): Promise<string> {
    const r = await coreCall<{ name: string }>({ cmd: "app_get_name" });
    return r.name;
  },

  /** suji.json `app.version` 반환 (Electron `app.getVersion`). */
  async getVersion(): Promise<string> {
    const r = await coreCall<{ version: string }>({ cmd: "app_get_version" });
    return r.version;
  },

  /** 앱 init 완료 여부 (V8 binding이 호출 가능한 시점은 항상 true). Electron 동등. */
  async isReady(): Promise<boolean> {
    const r = await coreCall<{ ready: boolean }>({ cmd: "app_is_ready" });
    return r.ready === true;
  },

  /** `.app` 번들로 실행 중인지 (Electron `app.isPackaged`). dev mode (raw binary)에선 false. */
  async isPackaged(): Promise<boolean> {
    const r = await coreCall<{ packaged: boolean }>({ cmd: "app_is_packaged" });
    return r.packaged === true;
  },

  /** 메인 번들 경로 (Electron `app.getAppPath`). dev mode에선 binary가 위치한 디렉토리. */
  async getAppPath(): Promise<string> {
    const r = await coreCall<{ path: string }>({ cmd: "app_get_app_path" });
    return r.path ?? "";
  },

  /** 시스템 locale BCP 47 형식 (e.g. "en-US", "ko-KR"). Electron `app.getLocale()`. */
  async getLocale(): Promise<string> {
    const r = await coreCall<{ locale: string }>({ cmd: "app_get_locale" });
    return r.locale;
  },

  /** Electron `app.setBadgeCount(count)` 동등. 0 이하면 배지 제거. */
  async setBadgeCount(count: number): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "app_set_badge_count", count });
    return r.success === true;
  },

  /** Electron `app.getBadgeCount()` 동등. */
  async getBadgeCount(): Promise<number> {
    const r = await coreCall<{ count: number }>({ cmd: "app_get_badge_count" });
    return r.count ?? 0;
  },

  /** dock 진행률 표시. progress<0=hide, 0~1=ratio, >1=100%로 clamp.
   *  Electron `BrowserWindow.setProgressBar` 동등 (macOS는 NSApp.dockTile 공유). */
  async setProgressBar(progress: number): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "app_set_progress_bar", progress });
    return r.success === true;
  },

  /** 앱 강제 종료 (Electron `app.exit(code)`). exit code는 무시 (cef.quit 경유). */
  async exit(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "app_exit" });
    return r.success === true;
  },

  /**
   * Electron `app.requestSingleInstanceLock()` — 이 프로세스를 primary 로 만들고
   * true 반환. 다른 인스턴스가 이미 락을 보유 중이면 false (앱은 보통 quit).
   * 이미 보유 중이면 멱등적으로 true. macOS/Linux=userData flock, Windows=named mutex.
   */
  async requestSingleInstanceLock(): Promise<boolean> {
    const r = await coreCall<{ locked: boolean }>({ cmd: "app_request_single_instance_lock" });
    return r.locked === true;
  },

  /** Electron `app.hasSingleInstanceLock()` — 이 프로세스가 락 보유 중인지. */
  async hasSingleInstanceLock(): Promise<boolean> {
    const r = await coreCall<{ locked: boolean }>({ cmd: "app_has_single_instance_lock" });
    return r.locked === true;
  },

  /** Electron `app.releaseSingleInstanceLock()` — 보유 락 해제(없으면 no-op). */
  async releaseSingleInstanceLock(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "app_release_single_instance_lock" });
    return r.success === true;
  },

  /** 앱을 frontmost로 (NSApp `activateIgnoringOtherApps:`). */
  async focus(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "app_focus" });
    return r.success === true;
  },

  /** 모든 윈도우 hide (macOS Cmd+H 동등). */
  async hide(): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "app_hide" });
    return r.success === true;
  },

  /** Electron `app.getPath` 동등. 표준 디렉토리 경로 반환. unknown 키는 빈 문자열. */
  async getPath(name: AppPathName): Promise<string> {
    const r = await coreCall<{ path: string }>({ cmd: "app_get_path", name });
    return r.path;
  },

  /** dock 아이콘 바운스 시작. 0이면 no-op (앱이 이미 active). 아니면 cancel용 id. */
  async requestUserAttention(critical = true): Promise<number> {
    const r = await coreCall<{ id: number }>({ cmd: "app_attention_request", critical });
    return r.id;
  },

  /** requestUserAttention으로 받은 id 취소. id == 0은 false (guard). */
  async cancelUserAttentionRequest(id: number): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "app_attention_cancel", id });
    return r.success === true;
  },

  /**
   * Security-scoped bookmark 생성 (App Sandbox 영속 파일 접근). 실패 시 null.
   * 비-sandbox 빌드에선 일반 bookmark 로 동작 (sandbox escapement no-op).
   */
  async createSecurityScopedBookmark(path: string): Promise<string | null> {
    const r = await coreCall<{ success: boolean; bookmark?: string }>({ cmd: "security_scoped_bookmark_create", path });
    return r.success === true ? r.bookmark ?? null : null;
  },

  /** bookmark 해소 + 접근 시작. 실패 시 null. id 를 stop 에 전달. */
  async startAccessingSecurityScopedResource(
    bookmark: string,
  ): Promise<{ id: number; path: string; stale: boolean } | null> {
    const r = await coreCall<{ success: boolean; id: number; path: string; stale: boolean }>({
      cmd: "security_scoped_access_start",
      bookmark,
    });
    return r.success === true ? { id: r.id, path: r.path, stale: r.stale } : null;
  },

  /** 접근 종료. 유효하지 않은 id 는 false. */
  async stopAccessingSecurityScopedResource(id: number): Promise<boolean> {
    const r = await coreCall<{ success: boolean }>({ cmd: "security_scoped_access_stop", id });
    return r.success === true;
  },

  dock: {
    /** dock 배지 텍스트 — 빈 문자열로 제거. macOS만. */
    async setBadge(text: string): Promise<void> {
      await coreCall({ cmd: "dock_set_badge", text });
    },

    /** 현재 배지 텍스트. 미설정이면 빈 문자열. */
    async getBadge(): Promise<string> {
      const r = await coreCall<{ text: string }>({ cmd: "dock_get_badge" });
      return r.text;
    },
  },
};

/**
 * 여러 백엔드에 동시 요청
 */
export async function fanout<T = unknown>(
  backends: string[],
  channel: string,
  data?: Record<string, unknown>,
): Promise<T> {
  const request = JSON.stringify({ cmd: channel, ...data });
  return getBridge().fanout(backends.join(","), request) as Promise<T>;
}

/**
 * 체인 호출 (A → Core → B)
 */
export async function chain<T = unknown>(
  from: string,
  to: string,
  channel: string,
  data?: Record<string, unknown>,
): Promise<T> {
  const request = JSON.stringify({ cmd: channel, ...data });
  return getBridge().chain(from, to, request) as Promise<T>;
}
