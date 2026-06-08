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
export interface SujiHandlers {
}
/** Helper: req가 void/undefined이면 args 생략 가능, 아니면 필수. */
type InvokeArgsForHandler<K extends keyof SujiHandlers & string> = SujiHandlers[K] extends {
    req: infer R;
} ? [R] extends [void | undefined] ? [data?: undefined, options?: InvokeOptions] : [data: R, options?: InvokeOptions] : [data?: unknown, options?: InvokeOptions];
type InvokeRes<K extends keyof SujiHandlers & string> = SujiHandlers[K] extends {
    res: infer R;
} ? R : unknown;
/** 등록된 cmd면 typed args/res, 아니면 untyped fallback. conditional dispatch. */
type InvokeArgs<K extends string> = K extends keyof SujiHandlers & string ? InvokeArgsForHandler<K> : [data?: Record<string, unknown>, options?: InvokeOptions];
type InvokeReturn<K extends string> = K extends keyof SujiHandlers & string ? InvokeRes<K> : unknown;
export interface SendOptions {
    /** 특정 창(window id)에만 전달. 생략 시 모든 창으로 브로드캐스트 (Electron `webContents.send` 대응) */
    to?: number;
}
type Listener = (data: unknown) => void;
/**
 * 백엔드 핸들러 호출 (Electron: ipcRenderer.invoke). SujiHandlers에 등록된 cmd면
 * type-safe (cmd/req/res 추론), 아니면 untyped fallback.
 *
 * @param channel - 핸들러 채널 이름
 * @param data - 요청 데이터 (옵셔널)
 * @param options - { target: "backend" } 명시적 백엔드 지정 (옵셔널)
 */
export declare function invoke<K extends string>(cmd: K, ...rest: InvokeArgs<K>): Promise<InvokeReturn<K>>;
/**
 * 이벤트 구독 (Electron: ipcRenderer.on)
 *
 * @returns 리스너 해제 함수
 */
export declare function on(event: string, callback: Listener): () => void;
/**
 * 이벤트 한 번만 구독 (Electron: ipcRenderer.once)
 *
 * @returns 리스너 해제 함수
 */
export declare function once(event: string, callback: Listener): () => void;
/**
 * 이벤트 발신 (Electron: ipcRenderer.send / webContents.send)
 *
 * @param options.to - 특정 창 id 지정 시 해당 창에만. 생략 시 모든 창으로 브로드캐스트.
 */
export declare function send(event: string, data: unknown, options?: SendOptions): void;
/**
 * 리스너 해제 (Electron: ipcRenderer.removeAllListeners([channel])).
 * `event` 지정 시 해당 채널의 모든 리스너 해제, 생략 시 **전 채널** 리스너 해제.
 */
export declare function off(event?: string): void;
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
/** get_view_bounds 응답 — 추적된 view bounds(없으면 ok:false + 0). */
export interface ViewBoundsResponse extends ViewOpResponse {
    x: number;
    y: number;
    width: number;
    height: number;
}
export interface GetChildViewsResponse {
    cmd: "get_child_views";
    from: "zig-core";
    hostId: number;
    ok: boolean;
    /** z-order 순서 (0=bottom, 마지막=top). 빈 배열이면 host에 view 없음 */
    viewIds: number[];
}
export declare const windows: {
    /**
     * 새 창 생성. Phase 3 옵션 풀 지원 — suji.json `windows[]` 항목과 동일한 키.
     * @returns `{ windowId }` — 후속 setTitle/setBounds 및 `send(_, { to: windowId })`에 사용
     */
    create(opts?: WindowOptions): Promise<CreateWindowResponse>;
    /** 창 타이틀 변경 */
    setTitle(windowId: number, title: string): Promise<WindowOpResponse>;
    /** 창 크기/위치 변경. width/height=0이면 현재 유지 */
    setBounds(windowId: number, bounds: SetBoundsArgs): Promise<WindowOpResponse>;
    /** 창에 새 URL 로드 (Electron `webContents.loadURL`) */
    loadURL(windowId: number, url: string): Promise<WindowOpResponse>;
    /** 현재 페이지 reload. ignoreCache=true면 disk 캐시 무시 */
    reload(windowId: number, ignoreCache?: boolean): Promise<WindowOpResponse>;
    /** 렌더러에서 임의 JS 실행 (Electron `webContents.executeJavaScript`).
     *  결과 회신은 미지원 — fire-and-forget. 결과가 필요하면 JS 측에서 `suji.send`로 회신. */
    executeJavaScript(windowId: number, code: string): Promise<WindowOpResponse>;
    /** 현재 main frame URL 조회 (캐시된 값). 캐시 미스면 null */
    getURL(windowId: number): Promise<GetUrlResponse>;
    /** UA 동적 변경 (Electron `webContents.setUserAgent`). CDP
     *  Network.setUserAgentOverride — 이후 네비/요청에 적용. */
    setUserAgent(windowId: number, userAgent: string): Promise<WindowOpResponse>;
    /** 설정한 UA override 조회 (Electron `webContents.getUserAgent`).
     *  미설정 시 userAgent=null (브라우저 기본 — CEF 가 per-browser
     *  기본 UA getter 미제공). */
    getUserAgent(windowId: number): Promise<GetUserAgentResponse>;
    /** 현재 로딩 중인지 조회 (Electron `webContents.isLoading`) */
    isLoading(windowId: number): Promise<IsLoadingResponse>;
    /** DevTools 열기 — 이미 열려있으면 멱등 no-op */
    openDevTools(windowId: number): Promise<WindowOpResponse>;
    /** DevTools 닫기 — 이미 닫혀있으면 no-op */
    closeDevTools(windowId: number): Promise<WindowOpResponse>;
    /** DevTools 열려있는지 조회 (Electron `webContents.isDevToolsOpened`) */
    isDevToolsOpened(windowId: number): Promise<IsDevToolsOpenedResponse>;
    /** DevTools 토글 — F12 단축키와 동일 동작 */
    toggleDevTools(windowId: number): Promise<WindowOpResponse>;
    /** 줌 레벨 변경. Electron 호환 — 0 = 100%, 1 = 120%, -1 = 1/1.2 (logarithmic) */
    setZoomLevel(windowId: number, level: number): Promise<WindowOpResponse>;
    getZoomLevel(windowId: number): Promise<ZoomLevelResponse>;
    /** 줌 factor 변경. 1.0 = 100%, 1.5 = 150% (linear). 내부적으로 level = log(factor)/log(1.2) 변환 */
    setZoomFactor(windowId: number, factor: number): Promise<WindowOpResponse>;
    getZoomFactor(windowId: number): Promise<ZoomFactorResponse>;
    /** 창 오디오 mute (Electron `webContents.setAudioMuted`). */
    setAudioMuted(windowId: number, muted: boolean): Promise<WindowOpResponse>;
    /** 창 오디오 mute 상태 (Electron `webContents.isAudioMuted`). */
    isAudioMuted(windowId: number): Promise<IsAudioMutedResponse>;
    /** 창 투명도 (0~1). Electron `BrowserWindow.setOpacity`. */
    setOpacity(windowId: number, opacity: number): Promise<WindowOpResponse>;
    /** 창 투명도 읽기. */
    getOpacity(windowId: number): Promise<OpacityResponse>;
    /** 배경색 (`#RRGGBB` 또는 `#RRGGBBAA`). Electron `BrowserWindow.setBackgroundColor`. */
    setBackgroundColor(windowId: number, color: string): Promise<WindowOpResponse>;
    /** 그림자 표시 여부. Electron `BrowserWindow.setHasShadow`. */
    setHasShadow(windowId: number, hasShadow: boolean): Promise<WindowOpResponse>;
    /** 그림자 상태 읽기. Electron `BrowserWindow.hasShadow`. */
    hasShadow(windowId: number): Promise<HasShadowResponse>;
    minimize(windowId: number): Promise<WindowOpResponse>;
    maximize(windowId: number): Promise<WindowOpResponse>;
    unmaximize(windowId: number): Promise<WindowOpResponse>;
    restore(windowId: number): Promise<WindowOpResponse>;
    show(windowId: number): Promise<WindowOpResponse>;
    hide(windowId: number): Promise<WindowOpResponse>;
    close(windowId: number): Promise<WindowOpResponse>;
    /** 강제 파괴 (Electron `BrowserWindow.destroy`). close 와 달리 `window:close`
     *  (취소 hook)를 스킵하고 `window:closed` 만 발화 — listener 가 막을 수 없음. */
    destroy(windowId: number): Promise<WindowOpResponse>;
    setFullScreen(windowId: number, flag: boolean): Promise<WindowOpResponse>;
    isMinimized(windowId: number): Promise<IsMinimizedResponse>;
    isMaximized(windowId: number): Promise<IsMaximizedResponse>;
    isFullScreen(windowId: number): Promise<IsFullScreenResponse>;
    /** Electron BrowserWindow.focus() — 창을 포그라운드로 키 창으로. */
    focus(windowId: number): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isNormal() — minimized/maximized/fullscreen 모두 아님. */
    isNormal(windowId: number): Promise<IsNormalResponse>;
    /** Electron BrowserWindow.getBounds() — {x,y,width,height} (top-left 원점). */
    getBounds(windowId: number): Promise<BoundsResponse>;
    /** Electron BrowserWindow.getSize() — [width, height]. getBounds 에서 파생. */
    getSize(windowId: number): Promise<[number, number]>;
    /** Electron BrowserWindow.getPosition() — [x, y]. getBounds 에서 파생. */
    getPosition(windowId: number): Promise<[number, number]>;
    /** Electron BrowserWindow.getContentBounds() — 콘텐츠 영역(프레임/타이틀바 제외). */
    getContentBounds(windowId: number): Promise<BoundsResponse>;
    /** Electron BrowserWindow.setContentBounds() — 콘텐츠 영역을 지정 사각형으로. */
    setContentBounds(windowId: number, bounds: SetBoundsArgs): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.getContentSize() — [width, height]. getContentBounds 에서 파생. */
    getContentSize(windowId: number): Promise<[number, number]>;
    /** Electron BrowserWindow.setSize(width, height) — 위치 유지(getBounds→setBounds 파생).
     *  `animate` 는 받되 무시(CEF Views set_bounds 비애니메이션 — 정직). */
    setSize(windowId: number, width: number, height: number, _animate?: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.setPosition(x, y) — 크기 유지(getBounds→setBounds 파생). `animate` 무시. */
    setPosition(windowId: number, x: number, y: number, _animate?: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.setMinimumSize(width, height). 0 = 제한 없음. */
    setMinimumSize(windowId: number, width: number, height: number): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.getMinimumSize() — [width, height] (추적된 제약값, 0=없음). */
    getMinimumSize(windowId: number): Promise<[number, number]>;
    /** Electron BrowserWindow.setMaximumSize(width, height). 0 = 제한 없음. */
    setMaximumSize(windowId: number, width: number, height: number): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.getMaximumSize() — [width, height] (추적된 제약값, 0=없음). */
    getMaximumSize(windowId: number): Promise<[number, number]>;
    /** Electron BrowserWindow.setResizable(resizable). false 면 사용자 리사이즈 불가. */
    setResizable(windowId: number, resizable: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isResizable(). */
    isResizable(windowId: number): Promise<IsResizableResponse>;
    /** Electron BrowserWindow.setMinimizable(minimizable). */
    setMinimizable(windowId: number, minimizable: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isMinimizable(). */
    isMinimizable(windowId: number): Promise<IsMinimizableResponse>;
    /** Electron BrowserWindow.setMaximizable(maximizable). */
    setMaximizable(windowId: number, maximizable: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isMaximizable(). */
    isMaximizable(windowId: number): Promise<IsMaximizableResponse>;
    /** Electron BrowserWindow.setClosable(closable). false 면 닫기 불가. */
    setClosable(windowId: number, closable: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isClosable(). */
    isClosable(windowId: number): Promise<IsClosableResponse>;
    /** Electron BrowserWindow.setMovable(movable). macOS NSWindow.movable, 그 외 tracked. */
    setMovable(windowId: number, movable: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isMovable(). */
    isMovable(windowId: number): Promise<IsMovableResponse>;
    /** Electron BrowserWindow.setFocusable(focusable). tracked(best-effort). */
    setFocusable(windowId: number, focusable: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isFocusable(). */
    isFocusable(windowId: number): Promise<IsFocusableResponse>;
    /** Electron BrowserWindow.setEnabled(enable). Win32 EnableWindow / macOS ignoresMouseEvents(마우스). */
    setEnabled(windowId: number, enabled: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isEnabled(). */
    isEnabled(windowId: number): Promise<IsEnabledResponse>;
    /** Electron BrowserWindow.setFullScreenable(fullscreenable). macOS collectionBehavior, 그 외 tracked. */
    setFullScreenable(windowId: number, fullscreenable: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isFullScreenable(). */
    isFullScreenable(windowId: number): Promise<IsFullScreenableResponse>;
    /** Electron BrowserWindow.setKiosk(flag). best-effort: 전체화면(presentation-options 미포함). */
    setKiosk(windowId: number, flag: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isKiosk(). */
    isKiosk(windowId: number): Promise<IsKioskResponse>;
    /** Electron BrowserWindow.blur() — 창 포커스 해제. */
    blur(windowId: number): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isFocused(). */
    isFocused(windowId: number): Promise<IsFocusedResponse>;
    /** Electron BrowserWindow.isVisible(). */
    isVisible(windowId: number): Promise<IsVisibleResponse>;
    /** Electron BrowserWindow.setAlwaysOnTop(flag). */
    setAlwaysOnTop(windowId: number, flag: boolean): Promise<WindowOpResponse>;
    /** Electron BrowserWindow.isAlwaysOnTop(). */
    isAlwaysOnTop(windowId: number): Promise<IsAlwaysOnTopResponse>;
    /** Electron BrowserWindow.getAllWindows() — 살아있는 top-level 창 id (view 제외). */
    getAllWindows(): Promise<GetAllWindowsResponse>;
    /** Electron BrowserWindow.getFocusedWindow() — 포커스 창 id 또는 null. */
    getFocusedWindow(): Promise<GetFocusedWindowResponse>;
    undo(windowId: number): Promise<WindowOpResponse>;
    redo(windowId: number): Promise<WindowOpResponse>;
    cut(windowId: number): Promise<WindowOpResponse>;
    copy(windowId: number): Promise<WindowOpResponse>;
    paste(windowId: number): Promise<WindowOpResponse>;
    selectAll(windowId: number): Promise<WindowOpResponse>;
    /** 페이지 텍스트 검색. 첫 호출은 findNext=false, 이후 같은 단어 다음 매치는 true.
     *  결과 보고는 cef_find_handler_t로 (현재 미노출 — 추후 이벤트). */
    findInPage(windowId: number, text: string, options?: {
        forward?: boolean;
        matchCase?: boolean;
        findNext?: boolean;
    }): Promise<WindowOpResponse>;
    stopFindInPage(windowId: number, clearSelection?: boolean): Promise<WindowOpResponse>;
    /** PDF로 인쇄 (Electron `webContents.printToPDF`). 코어가 CDP 완료까지 응답
     *  보류 → 단일 await 로 결과(`{success}`) 받음. EventBus `window:pdf-print-
     *  finished` emit 은 다른 구독자(다른 백엔드/창) 호환 유지.
     *
     *  defense-in-depth: 코어가 CDP 콜백 미발화(렌더러/GPU 크래시 등)로 응답을
     *  영영 안 보내는 극단 경우, SDK 타임아웃(기본 35s)이 `{success:false}`로
     *  settle 해 Promise 영구 hang 방지. 코어가 늦게 응답해도 무해(이미 settled). */
    printToPDF(windowId: number, path: string, opts?: {
        timeoutMs?: number;
    }): Promise<{
        success: boolean;
    }>;
    /** 페이지 스크린샷 PNG 저장 (Electron `webContents.capturePage` — CDP
     *  Page.captureScreenshot). 코어 deferred response 로 단일 await.
     *  base64 가 IPC 한도(64KB) 초과 가능해 path 파일 방식.
     *  rect 지정 시 부분 영역만; 미지정=전체. defense-in-depth 타임아웃은 printToPDF 동일. */
    capturePage(windowId: number, path: string, rect?: {
        x: number;
        y: number;
        width: number;
        height: number;
    }, opts?: {
        timeoutMs?: number;
    }): Promise<{
        success: boolean;
    }>;
    /** host 창 contentView 안에 새 view 합성 (Electron `WebContentsView`). 자동으로 host의
     *  view_children top에 추가됨 — 이후 addChildView로 z-order 변경 가능. bounds 미지정 시
     *  800x600 @ 0,0 (코어의 parseBoundsFromJson은 누락 키를 0으로 채워 SDK가 default 적용). */
    createView(opts: ViewOptions): Promise<CreateViewResponse>;
    /** view 파괴. host의 view_children에서 자동 제거 + `window:view-destroyed` 이벤트 */
    destroyView(viewId: number): Promise<ViewOpResponse>;
    /** view를 host children에 추가/재배치. index 생략 시 top. 같은 view 재호출 시 위치 갱신
     *  (Electron WebContentsView idiom). host 이동은 미지원. */
    addChildView(hostId: number, viewId: number, index?: number): Promise<ViewOpResponse>;
    /** view를 host children에서 분리 (destroy X). native에서 setHidden(true). 다시 addChildView
     *  로 같은 host에 붙일 수 있음. */
    removeChildView(hostId: number, viewId: number): Promise<ViewOpResponse>;
    /** addChildView(host, view, undefined) 편의 — Electron `setTopBrowserView` 동등 */
    setTopView(hostId: number, viewId: number): Promise<ViewOpResponse>;
    /** view 위치/크기 변경. host contentView 좌표계 (top-left). */
    setViewBounds(viewId: number, bounds: SetBoundsArgs): Promise<ViewOpResponse>;
    /** view 표시/숨김 토글. CEF host.was_hidden도 함께 호출 (렌더링/입력 일시정지) */
    setViewVisible(viewId: number, visible: boolean): Promise<ViewOpResponse>;
    /** host의 child view id들을 z-order 순서로 조회 (0=bottom, 마지막=top) */
    getChildViews(hostId: number): Promise<GetChildViewsResponse>;
    /** Electron `View.getBounds()` — view 의 추적 bounds {x,y,width,height} (없으면 ok:false+0). */
    getViewBounds(viewId: number): Promise<ViewBoundsResponse>;
    /** Electron `View.setBackgroundColor(color)` — view cef_view_t 배경색 "#RRGGBB[AA]". */
    setViewBackgroundColor(viewId: number, color: string): Promise<ViewOpResponse>;
};
/**
 * `windows.*`(raw windowId)의 객체지향 facade (Electron `BrowserWindow` 패리티).
 * 각 메서드는 `windows.<fn>(this.id, ...)` 로 위임 — 로직/응답 타입 무중복,
 * `windows` 변경에 자동 동기화(반환 타입은 위임으로 추론). view 합성
 * (createView/addChildView 등)은 host/view-id 다중 대상이라 `windows`
 * 네임스페이스에 유지(Electron 도 WebContentsView 별도).
 */
export declare class BrowserWindow {
    #private;
    private constructor();
    /** 후속 IPC/`send(_, { to })` 및 view host 인자로 쓰는 창 id. */
    get id(): number;
    /** 새 창 생성 후 인스턴스 반환 (Electron `new BrowserWindow(opts)`). */
    static create(opts?: WindowOptions): Promise<BrowserWindow>;
    /** 기존 windowId(예: 메인 창, 이벤트의 windowId)를 인스턴스로 래핑. */
    static fromId(id: number): BrowserWindow;
    /** Electron BrowserWindow.getAllWindows() — 살아있는 top-level 창 인스턴스 배열. */
    static getAllWindows(): Promise<BrowserWindow[]>;
    /** Electron BrowserWindow.getFocusedWindow() — 포커스 창 인스턴스 또는 null. */
    static getFocusedWindow(): Promise<BrowserWindow | null>;
    setTitle(title: string): Promise<WindowOpResponse>;
    setBounds(bounds: SetBoundsArgs): Promise<WindowOpResponse>;
    loadURL(url: string): Promise<WindowOpResponse>;
    reload(ignoreCache?: boolean): Promise<WindowOpResponse>;
    executeJavaScript(code: string): Promise<WindowOpResponse>;
    getURL(): Promise<GetUrlResponse>;
    setUserAgent(userAgent: string): Promise<WindowOpResponse>;
    getUserAgent(): Promise<GetUserAgentResponse>;
    isLoading(): Promise<IsLoadingResponse>;
    openDevTools(): Promise<WindowOpResponse>;
    closeDevTools(): Promise<WindowOpResponse>;
    isDevToolsOpened(): Promise<IsDevToolsOpenedResponse>;
    toggleDevTools(): Promise<WindowOpResponse>;
    setZoomLevel(level: number): Promise<WindowOpResponse>;
    getZoomLevel(): Promise<ZoomLevelResponse>;
    setZoomFactor(factor: number): Promise<WindowOpResponse>;
    getZoomFactor(): Promise<ZoomFactorResponse>;
    setAudioMuted(muted: boolean): Promise<WindowOpResponse>;
    isAudioMuted(): Promise<IsAudioMutedResponse>;
    setOpacity(opacity: number): Promise<WindowOpResponse>;
    getOpacity(): Promise<OpacityResponse>;
    setBackgroundColor(color: string): Promise<WindowOpResponse>;
    setHasShadow(hasShadow: boolean): Promise<WindowOpResponse>;
    hasShadow(): Promise<HasShadowResponse>;
    minimize(): Promise<WindowOpResponse>;
    maximize(): Promise<WindowOpResponse>;
    unmaximize(): Promise<WindowOpResponse>;
    restore(): Promise<WindowOpResponse>;
    show(): Promise<WindowOpResponse>;
    hide(): Promise<WindowOpResponse>;
    close(): Promise<WindowOpResponse>;
    /** 강제 파괴 (Electron `BrowserWindow.destroy`) — `window:close` 스킵, `window:closed` 만. */
    destroy(): Promise<WindowOpResponse>;
    setFullScreen(flag: boolean): Promise<WindowOpResponse>;
    isMinimized(): Promise<IsMinimizedResponse>;
    isMaximized(): Promise<IsMaximizedResponse>;
    isFullScreen(): Promise<IsFullScreenResponse>;
    focus(): Promise<WindowOpResponse>;
    isNormal(): Promise<IsNormalResponse>;
    getBounds(): Promise<BoundsResponse>;
    getSize(): Promise<[number, number]>;
    getPosition(): Promise<[number, number]>;
    getContentBounds(): Promise<BoundsResponse>;
    setContentBounds(bounds: SetBoundsArgs): Promise<WindowOpResponse>;
    getContentSize(): Promise<[number, number]>;
    setSize(width: number, height: number, animate?: boolean): Promise<WindowOpResponse>;
    setPosition(x: number, y: number, animate?: boolean): Promise<WindowOpResponse>;
    setMinimumSize(width: number, height: number): Promise<WindowOpResponse>;
    getMinimumSize(): Promise<[number, number]>;
    setMaximumSize(width: number, height: number): Promise<WindowOpResponse>;
    getMaximumSize(): Promise<[number, number]>;
    setResizable(resizable: boolean): Promise<WindowOpResponse>;
    isResizable(): Promise<IsResizableResponse>;
    setMinimizable(minimizable: boolean): Promise<WindowOpResponse>;
    isMinimizable(): Promise<IsMinimizableResponse>;
    setMaximizable(maximizable: boolean): Promise<WindowOpResponse>;
    isMaximizable(): Promise<IsMaximizableResponse>;
    setClosable(closable: boolean): Promise<WindowOpResponse>;
    isClosable(): Promise<IsClosableResponse>;
    setMovable(movable: boolean): Promise<WindowOpResponse>;
    isMovable(): Promise<IsMovableResponse>;
    setFocusable(focusable: boolean): Promise<WindowOpResponse>;
    isFocusable(): Promise<IsFocusableResponse>;
    setEnabled(enabled: boolean): Promise<WindowOpResponse>;
    isEnabled(): Promise<IsEnabledResponse>;
    setFullScreenable(fullscreenable: boolean): Promise<WindowOpResponse>;
    isFullScreenable(): Promise<IsFullScreenableResponse>;
    setKiosk(flag: boolean): Promise<WindowOpResponse>;
    isKiosk(): Promise<IsKioskResponse>;
    blur(): Promise<WindowOpResponse>;
    isFocused(): Promise<IsFocusedResponse>;
    isVisible(): Promise<IsVisibleResponse>;
    setAlwaysOnTop(flag: boolean): Promise<WindowOpResponse>;
    isAlwaysOnTop(): Promise<IsAlwaysOnTopResponse>;
    undo(): Promise<WindowOpResponse>;
    redo(): Promise<WindowOpResponse>;
    cut(): Promise<WindowOpResponse>;
    copy(): Promise<WindowOpResponse>;
    paste(): Promise<WindowOpResponse>;
    selectAll(): Promise<WindowOpResponse>;
    findInPage(text: string, options?: {
        forward?: boolean;
        matchCase?: boolean;
        findNext?: boolean;
    }): Promise<WindowOpResponse>;
    stopFindInPage(clearSelection?: boolean): Promise<WindowOpResponse>;
    printToPDF(path: string): Promise<{
        success: boolean;
    }>;
    capturePage(path: string, rect?: {
        x: number;
        y: number;
        width: number;
        height: number;
    }): Promise<{
        success: boolean;
    }>;
}
/**
 * Electron `WebContentsView` 패리티 OO facade — host 창에 합성하는 child view.
 * viewId 는 windowId 와 같은 풀이라 모든 webContents 메서드(loadURL/executeJavaScript 등)가
 * view 에 동작한다. view 합성/조작은 `windows.*` 에 위임(BrowserWindow 와 동형 패턴).
 */
export declare class WebContentsView {
    #private;
    private constructor();
    /** view 식별자(= windowId 풀). webContents 메서드 인자로 사용. */
    get id(): number;
    /** host 창에 child view 생성 후 인스턴스 반환 (Electron `new WebContentsView()` + addChildView). */
    static create(opts: ViewOptions): Promise<WebContentsView>;
    /** 기존 viewId 를 인스턴스로 래핑. */
    static fromId(id: number): WebContentsView;
    setBounds(bounds: SetBoundsArgs): Promise<ViewOpResponse>;
    getBounds(): Promise<ViewBoundsResponse>;
    setVisible(visible: boolean): Promise<ViewOpResponse>;
    setBackgroundColor(color: string): Promise<ViewOpResponse>;
    destroy(): Promise<ViewOpResponse>;
    loadURL(url: string): Promise<WindowOpResponse>;
    executeJavaScript(code: string): Promise<WindowOpResponse>;
    openDevTools(): Promise<WindowOpResponse>;
}
export declare const powerMonitor: {
    /** 시스템 유휴 시간 (초). 활성 입력 후 0으로 리셋.
     *  Electron `powerMonitor.getSystemIdleTime()` 동등. */
    getSystemIdleTime(): Promise<number>;
    /** 화면 잠금이면 "locked", 유휴 시간 ≥ threshold(초)면 "idle", 아니면 "active".
     *  Electron `powerMonitor.getSystemIdleState(threshold)` 동등. */
    getSystemIdleState(threshold: number): Promise<"active" | "idle" | "locked">;
    /** Electron `powerMonitor.isOnBatteryPower()` — 현재 배터리 전원 여부.
     *  macOS IOKit / Windows GetSystemPowerStatus / Linux /sys. 정보 없으면 false. */
    isOnBatteryPower(): Promise<boolean>;
};
export declare const clipboard: {
    /** 클립보드의 plain text 읽기. 비어 있거나 non-text면 빈 문자열. */
    readText(): Promise<string>;
    /** 클립보드에 plain text 쓰기. 성공 시 true. */
    writeText(text: string): Promise<boolean>;
    /** 클립보드 비우기. */
    clear(): Promise<boolean>;
    /** HTML read (NSPasteboard `public.html`). 비어 있거나 non-html이면 빈 문자열. */
    readHTML(): Promise<string>;
    /** HTML write — write 시 다른 type (text 등)도 함께 지움. */
    writeHTML(html: string): Promise<boolean>;
    /** RTF read (Electron `clipboard.readRTF`). 비어 있거나 non-rtf면 빈 문자열. */
    readRTF(): Promise<string>;
    /** RTF write (Electron `clipboard.writeRTF`). 다른 type 지움. */
    writeRTF(rtf: string): Promise<boolean>;
    /** 임의 UTI raw bytes 쓰기 (Electron `clipboard.writeBuffer(format, buffer)`).
     *  data는 base64 인코딩된 문자열 (raw ~8KB 한도). */
    writeBuffer(format: string, data: string): Promise<boolean>;
    /** 임의 UTI raw bytes 읽기 (Electron `clipboard.readBuffer(format)`). base64 string 반환. */
    readBuffer(format: string): Promise<string>;
    /** 클립보드에 주어진 format이 있는지 (Electron `clipboard.has(format)`).
     *  format은 macOS UTI ("public.utf8-plain-text", "public.html" 등). */
    has(format: string): Promise<boolean>;
    /** 클립보드에 등록된 모든 format (UTI) 배열. */
    availableFormats(): Promise<string[]>;
    /** PNG 이미지 쓰기 — base64 문자열. 다른 type 함께 지움. (Electron `writeImage`). */
    writeImage(pngBase64: string): Promise<boolean>;
    /** PNG 이미지 읽기 — base64 반환. PNG 아니면 빈 문자열. */
    readImage(): Promise<string>;
    /** TIFF 이미지 쓰기 — base64 문자열 (NSPasteboard `public.tiff`). writeImage 동형. */
    writeTiff(tiffBase64: string): Promise<boolean>;
    /** TIFF 이미지 읽기 — base64 반환. TIFF 아니면 빈 문자열. */
    readTiff(): Promise<string>;
    /** 북마크(title+url) 쓰기 (Electron `clipboard.writeBookmark`). macOS NSPasteboard
     *  public.url(+url-name). macOS only — Win/Linux false(bookmark 포맷 미지원). */
    writeBookmark(title: string, url: string): Promise<boolean>;
    /** Find 펜보드에 텍스트 쓰기 (Electron `clipboard.writeFindText`). macOS cross-app find
     *  pasteboard. macOS only — Win/Linux false. */
    writeFindText(text: string): Promise<boolean>;
    /** 여러 포맷 한 번에 쓰기 (Electron `clipboard.write({text,html,rtf})`). clear 1회 후
     *  제공된 필드만 기록. macOS=atomic, Win/Linux=best-effort 단일(text 우선). */
    write(data: {
        text?: string;
        html?: string;
        rtf?: string;
    }): Promise<boolean>;
};
export interface NotificationOptions {
    title: string;
    body: string;
    /** 사운드 묻음 */
    silent?: boolean;
    /** caller-supplied 식별자 (Electron NotificationOptions). 생략 시 자동 생성. */
    id?: string;
    /** 그룹 식별자 — macOS threadIdentifier(그룹화 + removeGroup 대상). Win/Linux 무시. */
    groupId?: string;
}
export declare const notification: {
    /** 플랫폼 지원 여부 — macOS bundle/권한, Linux daemon, Windows tray balloon 상태를 반영. */
    isSupported(): Promise<boolean>;
    /** 알림 권한 요청 — 첫 호출 시 OS 다이얼로그. 이후 캐시. */
    requestPermission(): Promise<boolean>;
    /** 알림 표시. 반환 `notificationId`로 close 가능. success=false면 권한/번들 문제. */
    show(options: NotificationOptions): Promise<{
        notificationId: string;
        success: boolean;
    }>;
    close(notificationId: string): Promise<boolean>;
    /** Electron `Notification` 전체 제거 — 표시/대기 모든 알림(macOS 실동작). */
    removeAll(): Promise<boolean>;
    /** 그룹(groupId=macOS threadIdentifier) 알림 제거 (Electron `Notification.removeGroup`).
     *  macOS only — Win/Linux false(그룹 개념 미지원). */
    removeGroup(groupId: string): Promise<boolean>;
};
/** Electron `Notification` 클래스 동등 — OO 래퍼. show() 후 `id` 로 식별자 조회 가능. */
export declare class Notification {
    #private;
    private readonly options;
    constructor(options: NotificationOptions);
    /** show() 이후의 알림 식별자(생성 전 null). Electron `notification.id` readonly. */
    get id(): string | null;
    /** 알림 표시 — 성공 시 id 가 채워진다. */
    show(): Promise<boolean>;
    /** 이 알림 닫기 (show 전이면 false). */
    close(): Promise<boolean>;
}
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
export declare const tray: {
    /** 새 시스템 트레이 아이콘 생성. 반환된 trayId로 이후 update/destroy. */
    create(options?: TrayCreateOptions): Promise<{
        trayId: number;
    }>;
    setTitle(trayId: number, title: string): Promise<boolean>;
    setTooltip(trayId: number, tooltip: string): Promise<boolean>;
    /** Electron 명명(`tray.setToolTip`) 별칭 — setTooltip 과 동일. */
    setToolTip(trayId: number, toolTip: string): Promise<boolean>;
    /** 트레이 아이콘 화면 좌표 rect (Electron `tray.getBounds()`). macOS NSStatusItem.button
     *  window frame. macOS only — Win/Linux 는 0 rect(미지원). */
    getBounds(trayId: number): Promise<{
        x: number;
        y: number;
        width: number;
        height: number;
    }>;
    /** 트레이 클릭 시 표시될 컨텍스트 메뉴 설정. macOS/Linux는 submenu/checkbox도 지원.
     *  메뉴 항목 클릭은 `suji.on('tray:menu-click', ({trayId, click}) => ...)` 로 수신. */
    setMenu(trayId: number, items: TrayMenuItem[]): Promise<boolean>;
    destroy(trayId: number): Promise<boolean>;
};
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
    /** Electron MenuItem.icon — 이미지 파일 경로. macOS NSImage(setImage:). fs sandbox
     *  allowedRoots 게이트 적용(렌더러 경로; 미설정=레거시 허용). macOS only. */
    icon?: string;
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
    /** Electron MenuItem.icon — 이미지 파일 경로. macOS NSImage(setImage:). fs sandbox 게이트. */
    icon?: string;
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
export declare const menu: {
    setApplicationMenu(items: MenuItem[]): Promise<boolean>;
    resetApplicationMenu(): Promise<boolean>;
    /** Electron `Menu.getApplicationMenu()` — 마지막 setApplicationMenu 의 items 스냅샷
     *  (없으면 []). 정직 경계: 라이브 mutation 아님(suji 메뉴는 fire-and-forget) — 변경하려면
     *  setApplicationMenu 로 전체 재설정. */
    getApplicationMenu(): Promise<MenuItem[]>;
    /** Electron `Menu.getMenuItemById(id)` — getApplicationMenu 스냅샷에서 id 로 재귀 탐색.
     *  없으면 null. (submenu 까지 깊이 탐색.) */
    getMenuItemById(id: string): Promise<MenuItem | null>;
    /** Electron `Menu.insert(pos, menuItem)` — getApplicationMenu 스냅샷 pos 위치에 항목 삽입
     *  후 전체 재설정(suji 메뉴 fire-and-forget — 스냅샷 splice + setApplicationMenu). pos clamp. */
    insert(pos: number, item: MenuItem): Promise<boolean>;
    /** Electron `Menu.sendActionToFirstResponder(action)` — macOS first responder(포커스된
     *  web view)에 표준 셀렉터 전달(예 "copy:", "selectAll:"). macOS only, Win/Linux no-op. */
    sendActionToFirstResponder(action: string): Promise<boolean>;
    /** 임의 위치 컨텍스트 메뉴 (Electron `Menu.popup({x?,y?})`). x/y 미지정 시
     *  현재 커서(화면 좌표, macOS bottom-up). 선택은 `suji.on('menu:click',
     *  ({click}) => ...)` 로 수신 (setApplicationMenu 와 동일). macOS NSMenu
     *  `popUpMenuPositioningItem:atLocation:inView:` — 동기 모달. */
    popup(items: MenuItem[], opts?: {
        x?: number;
        y?: number;
    }): Promise<boolean>;
};
export declare const globalShortcut: {
    register(accelerator: string, click: string): Promise<boolean>;
    unregister(accelerator: string): Promise<boolean>;
    unregisterAll(): Promise<boolean>;
    isRegistered(accelerator: string): Promise<boolean>;
    /** 여러 단축키를 같은 click 채널로 일괄 등록 (Electron `globalShortcut.registerAll`).
     *  모두 성공 시 true, 하나라도 실패 시 false(성공분은 그대로 유지 — 롤백 없음).
     *  ※ Electron 은 void 반환(per-accel silent fail) — suji 는 집계 bool 을 추가 제공. */
    registerAll(accelerators: string[], click: string): Promise<boolean>;
    /** 모든 등록 단축키를 일시 정지/재개 (Electron `globalShortcut.setSuspended`).
     *  등록은 유지되고 trigger 이벤트 발신만 차단(isRegistered 는 true 유지). */
    setSuspended(suspended: boolean): Promise<boolean>;
    /** 현재 suspended 상태 (Electron `globalShortcut.isSuspended`). */
    isSuspended(): Promise<boolean>;
};
export declare const shell: {
    /** URL을 시스템 기본 핸들러로 열기 (http(s) → 브라우저, mailto: → 메일 앱 등).
     *  잘못된 URL syntax면 false. */
    openExternal(url: string): Promise<boolean>;
    /** Finder/탐색기에서 파일/폴더 reveal — 부모 폴더 열리고 항목 선택. 경로 없으면 false. */
    showItemInFolder(path: string): Promise<boolean>;
    /** 시스템 비프음. */
    beep(): Promise<boolean>;
    /** 휴지통으로 이동. macOS NSFileManager `trashItemAtURL:`. 실패하면 false. */
    trashItem(path: string): Promise<boolean>;
    /** 파일/폴더를 기본 앱으로 열기 (`openExternal`은 URL용, 이건 로컬 path용).
     *  존재하지 않는 경로는 false. macOS NSWorkspace `openURL:` (file://). */
    openPath(path: string): Promise<boolean>;
};
export declare const nativeImage: {
    /** 이미지 파일 → 크기 {width, height} (point 단위, NSImage). 파일 없거나 디코딩 실패는 0/0.
     *  Electron `nativeImage.createFromPath(path).getSize()` 동등. */
    getSize(path: string): Promise<{
        width: number;
        height: number;
    }>;
    /** 이미지 파일 → PNG base64 (raw ~8KB 한도, 작은 아이콘용 1차).
     *  Electron `nativeImage.createFromPath(path).toPNG()` → base64.toString('base64'). */
    toPng(path: string): Promise<string>;
    /** 이미지 파일 → JPEG base64. quality 0~100 (기본 90). */
    toJpeg(path: string, quality?: number): Promise<string>;
    /** 이미지가 비어있는지 (로드 실패/크기 0) — Electron `nativeImage.isEmpty()`. */
    isEmpty(path: string): Promise<boolean>;
    /** template 이미지 여부 (macOS 메뉴바 자동 틴트 대상) — Electron `nativeImage.isTemplateImage()`.
     *  macOS NSImage.isTemplate. Win/Linux는 false(미지원). */
    isTemplateImage(path: string): Promise<boolean>;
};
export type ThemeSource = "system" | "light" | "dark";
export declare const nativeTheme: {
    /** 시스템 다크 모드 활성 여부 (Electron `nativeTheme.shouldUseDarkColors`).
     *  macOS NSApp.effectiveAppearance.name이 Dark 계열이면 true. */
    shouldUseDarkColors(): Promise<boolean>;
    /** `themeSource = "light" | "dark" | "system"` setter (Electron 동등).
     *  system은 OS 따름 (NSApp.appearance = nil), light/dark는 NSAppearance 강제.
     *  잘못된 값은 false. */
    setThemeSource(source: ThemeSource): Promise<boolean>;
    /** Electron `nativeTheme.themeSource` (getter) — 마지막 설정값(기본 "system"). */
    getThemeSource(): Promise<ThemeSource>;
    /** 고대비 모드 여부 (Electron `nativeTheme.shouldUseHighContrastColors`).
     *  macOS NSWorkspace.accessibilityDisplayShouldIncreaseContrast / Windows SPI_GETHIGHCONTRAST.
     *  Linux는 false(미지원). */
    shouldUseHighContrastColors(): Promise<boolean>;
    /** 투명도 감소 선호 여부 (Electron `nativeTheme.prefersReducedTransparency`).
     *  macOS NSWorkspace.accessibilityDisplayShouldReduceTransparency / Windows EnableTransparency==0.
     *  Linux는 false(미지원). */
    prefersReducedTransparency(): Promise<boolean>;
};
export type FileType = "file" | "directory" | "symlink" | "blockDevice" | "characterDevice" | "fifo" | "socket" | "whiteout" | "door" | "eventPort" | "unknown";
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
export declare const fs: {
    readFile(path: string): Promise<string>;
    writeFile(path: string, text: string): Promise<boolean>;
    stat(path: string): Promise<FsStat>;
    mkdir(path: string, options?: {
        recursive?: boolean;
    }): Promise<boolean>;
    readdir(path: string): Promise<FsDirEntry[]>;
    /** Remove `path`. `recursive` deletes directories; `force` ignores not-found (matches `node:fs.rm`). */
    rm(path: string, options?: {
        recursive?: boolean;
        force?: boolean;
    }): Promise<boolean>;
};
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
export type OpenDialogProperty = "openFile" | "openDirectory" | "multiSelections" | "showHiddenFiles" | "createDirectory" | "noResolveAliases" | "treatPackageAsDirectory";
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
export type SaveDialogProperty = "showHiddenFiles" | "createDirectory" | "treatPackageAsDirectory";
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
export type PermissionRequestHandler = (details: PermissionRequestDetails) => boolean | Promise<boolean>;
export declare const session: {
    /** 모든 cookie 삭제 (Electron `session.clearStorageData({storages:["cookies"]})`).
     *  fire-and-forget — 실제 cleanup은 비동기. */
    clearCookies(): Promise<boolean>;
    /** disk store flush (Electron `session.cookies.flushStore`). */
    flushStore(): Promise<boolean>;
    /**
     * Electron `session.setProxy(config)` — Chromium "proxy" preference 설정.
     * mode 미지정/`"direct"` → 프록시 해제. `proxyRules`: `"host:port"` 또는
     * `"http=foo:80;https=bar:80"`. 이후 요청에 적용. fire-and-forget(설정 성공 bool).
     */
    setProxy(config: {
        mode?: "direct" | "auto_detect" | "pac_script" | "fixed_servers" | "system";
        proxyRules?: string;
        proxyBypassRules?: string;
        pacScript?: string;
    }): Promise<boolean>;
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
    setPermissionRequestHandler(handler: PermissionRequestHandler | null): Promise<void>;
    /**
     * IndexedDB/localStorage/cache 삭제 (Electron `session.clearStorageData`).
     * origin 미지정 → 전역 HTTP 캐시만(웹 플랫폼상 origin 없이 storage 일괄
     * 삭제 불가 — 호출부가 자기 앱 origin 전달 시 그 origin storage 삭제).
     * storageTypes 기본 "all" (CDP 콤마구분: local_storage,indexeddb,...).
     */
    clearStorageData(origin?: string, storageTypes?: string): Promise<boolean>;
    /** Electron `session.cookies.set`. expires는 unix epoch second (0 → 세션 쿠키). */
    setCookie(cookie: CookieDescriptor): Promise<boolean>;
    /** Electron `session.cookies.remove`. url+name 매칭. */
    removeCookies(url: string, name: string): Promise<boolean>;
    /** Electron `session.cookies.get`. visitor 패턴 — `session:cookies-result` 이벤트로
     *  결과 도착, requestId 매칭으로 promise resolve.
     *
     *  Race-safe: listener 먼저 등록하지만 visit이 invoke 응답보다 빨리 emit하면 id=0 상태로
     *  도달. 그 emit을 buffer해두고 invoke 응답으로 id 받은 뒤 매칭.
     *
     *  Timeout 1초 — cookies 0개 case는 native visitor가 호출 안 돼 emit이 없으므로
     *  timeout으로 빈 array 반환. 1초면 사용자 느끼는 지연 충분히 짧고 visit 비동기성
     *  여유도 보장. */
    getCookies(filter?: CookieFilter): Promise<CookieRecord[]>;
};
export declare const dialog: {
    /** 메시지 박스. 첫 인자에 windowId(number) 주면 sheet — 그 창에 부착. 없으면 free-floating.
     *  반환: 사용자가 클릭한 버튼 index + checkbox 상태. */
    showMessageBox(arg1: MessageBoxOptions | number, arg2?: MessageBoxOptions): Promise<{
        response: number;
        checkboxChecked: boolean;
    }>;
    /** 단순 에러 popup (NSAlert critical style + OK 버튼). 응답 없음 — Electron 동등. */
    showErrorBox(title: string, content: string): Promise<void>;
    /** 파일/폴더 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePaths:[]}`. */
    showOpenDialog(arg1?: OpenDialogOptions | number, arg2?: OpenDialogOptions): Promise<{
        canceled: boolean;
        filePaths: string[];
    }>;
    /** 저장 경로 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePath:""}`. */
    showSaveDialog(arg1?: SaveDialogOptions | number, arg2?: SaveDialogOptions): Promise<{
        canceled: boolean;
        filePath: string;
    }>;
    /** Sync 변종 — `response: number`만 반환. windowId 첫 인자 지원. */
    showMessageBoxSync(arg1: MessageBoxOptions | number, arg2?: MessageBoxOptions): Promise<number>;
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string[]`. windowId 첫 인자 지원. */
    showOpenDialogSync(arg1?: OpenDialogOptions | number, arg2?: OpenDialogOptions): Promise<string[] | undefined>;
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string`. windowId 첫 인자 지원. */
    showSaveDialogSync(arg1?: SaveDialogOptions | number, arg2?: SaveDialogOptions): Promise<string | undefined>;
};
export interface WebRequestDetails {
    url: string;
    /** resolve용 internal id — `webRequest.resolve`에 그대로 전달. */
    id: number;
}
export interface WebRequestDecision {
    /** true면 요청 cancel, false/생략이면 통과. */
    cancel?: boolean;
}
type WebRequestListener = (details: WebRequestDetails, callback: (decision: WebRequestDecision) => void) => void;
export declare const webRequest: {
    /** blocklist 패턴 list 갱신 (전체 교체). 빈 list = 모든 요청 통과. 최대 32개, 256자/패턴. */
    setBlockedUrls(patterns: string[]): Promise<number>;
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
    onBeforeRequest(filter: {
        urls: string[];
    } | null, listener: WebRequestListener | null, options?: {
        timeoutMs?: number;
    }): Promise<void>;
    /** listener 직접 detach (파라미터 없는 onBeforeRequest와 동등). */
    clearListener(): Promise<void>;
};
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
export declare const screen: {
    /** 연결된 모든 모니터의 bounds/scale 정보. macOS NSScreen 기반. */
    getAllDisplays(): Promise<Display[]>;
    /** 마우스 포인터 화면 좌표 (macOS NSEvent.mouseLocation). bottom-up 좌표계. */
    getCursorScreenPoint(): Promise<{
        x: number;
        y: number;
    }>;
    /** (x,y)를 포함하는 display index. 어느 display에도 포함 안 되면 -1. */
    getDisplayNearestPoint(point: {
        x: number;
        y: number;
    }): Promise<number>;
    /** Primary display 객체 반환 (없으면 null) — getAllDisplays.find(isPrimary) wrapper. */
    getPrimaryDisplay(): Promise<Display | null>;
    /**
     * rect(보통 창 bounds)와 가장 많이 겹치는 Display (Electron `screen.getDisplayMatching`).
     * 듀얼/멀티모니터에서 "이 창이 있는 모니터" 판정 — 겹침 없으면 중심 최근접.
     * 매칭 계산은 코어 cmd `screen_get_display_matching`(전 언어 SDK 공유)이 수행하고,
     * 여기선 그 index 로 getAllDisplays 에서 Display 를 해석해 반환.
     */
    getDisplayMatching(rect: {
        x: number;
        y: number;
        width: number;
        height: number;
    }): Promise<Display | null>;
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
export declare const desktopCapturer: {
    /**
     * 화면/창 소스 열거 (Electron `desktopCapturer.getSources`). types 기본
     * 둘 다. ⚠️ Electron 과 달리 thumbnail/appIcon 미포함 — Screen Recording
     * TCC 권한 + base64 IPC 한도 때문(소스 열거만, 썸네일은 후속).
     */
    getSources(opts?: {
        types?: Array<"screen" | "window">;
    }): Promise<DesktopCapturerSource[]>;
    /**
     * 소스(`getSources()` 의 `id` — "screen:N:0"/"window:N:0") 썸네일을 PNG 로
     * `path` 에 캡처(파일경로 — base64 IPC 한도 우회, capture_page 동형).
     * ⚠️ Screen Recording TCC 권한 필요 — 미부여 시 `false`(정직 경계).
     */
    captureThumbnail(sourceId: string, path: string): Promise<boolean>;
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
export declare const crashReporter: {
    /** Runtime state 등록. 첫 프로세스 Crashpad enable은 suji.json app.crashReporter 필요. */
    start(options?: CrashReporterStartOptions): Promise<boolean>;
    getParameters(): Promise<Record<string, string>>;
    addExtraParameter(key: string, value: string): Promise<boolean>;
    removeExtraParameter(key: string): Promise<boolean>;
    getUploadToServer(): Promise<boolean>;
    setUploadToServer(uploadToServer: boolean): Promise<boolean>;
    getUploadedReports(): Promise<CrashReport[]>;
    getLastCrashReport(): Promise<CrashReport | null>;
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
export declare const autoUpdater: {
    /** manifest 객체 또는 manifest URL을 확인해 새 버전 여부를 반환. */
    checkForUpdates(input: string | AutoUpdaterManifest, options?: AutoUpdaterCheckOptions): Promise<AutoUpdaterCheckResult>;
    /** 다운로드된 파일의 SHA-256을 검증. mismatch면 success=false와 actualSha256 반환. */
    verifyFile(path: string, sha256: string): Promise<AutoUpdaterVerifyResult>;
    /** artifact URL 또는 manifest 객체를 지정 경로로 다운로드하고 optional SHA-256을 검증. */
    downloadArtifact(input: string | AutoUpdaterManifest, path: string, options?: AutoUpdaterDownloadOptions): Promise<AutoUpdaterDownloadResult>;
    /** artifact 포맷(.zip/.dmg/.app/.AppImage/.deb)을 quitAndInstall 또는 system package handoff 입력으로 정규화. */
    prepareInstall(input: string | AutoUpdaterDownloadResult, options?: AutoUpdaterPrepareInstallOptions): Promise<AutoUpdaterPrepareInstallResult>;
    /** staged artifact를 앱 종료 후 target으로 교체하고 quit을 요청. */
    quitAndInstall(input: string | AutoUpdaterDownloadResult | AutoUpdaterPrepareInstallResult, options?: AutoUpdaterQuitAndInstallOptions): Promise<AutoUpdaterQuitAndInstallResult>;
};
export type PowerSaveBlockerType = "prevent_app_suspension" | "prevent_display_sleep";
export declare const powerSaveBlocker: {
    /** sleep 차단 시작. 반환된 id로 stop. 0이면 실패. */
    start(type: PowerSaveBlockerType): Promise<number>;
    /** start로 받은 id를 해제. unknown id는 false. */
    stop(id: number): Promise<boolean>;
    /** blocker 가 활성(시작됨) 상태인지 (Electron `powerSaveBlocker.isStarted`). */
    isStarted(id: number): Promise<boolean>;
};
export declare const safeStorage: {
    /** service+account에 utf-8 value 저장. 같은 키면 update (idempotent). */
    setItem(service: string, account: string, value: string): Promise<boolean>;
    /** service+account로 저장된 value read. 없으면 빈 문자열. */
    getItem(service: string, account: string): Promise<string>;
    /** service+account 삭제. 존재하지 않아도 true (idempotent). */
    deleteItem(service: string, account: string): Promise<boolean>;
};
export type AppPathName = "home" | "appData" | "userData" | "temp" | "desktop" | "documents" | "downloads";
export declare const app: {
    /** suji.json `app.name` 반환 (Electron `app.getName`). */
    getName(): Promise<string>;
    /** suji.json `app.version` 반환 (Electron `app.getVersion`). */
    getVersion(): Promise<string>;
    /** 앱 init 완료 여부 (V8 binding이 호출 가능한 시점은 항상 true). Electron 동등. */
    isReady(): Promise<boolean>;
    /** `.app` 번들로 실행 중인지 (Electron `app.isPackaged`). dev mode (raw binary)에선 false. */
    isPackaged(): Promise<boolean>;
    /** 메인 번들 경로 (Electron `app.getAppPath`). dev mode에선 binary가 위치한 디렉토리. */
    getAppPath(): Promise<string>;
    /** 시스템 locale BCP 47 형식 (e.g. "en-US", "ko-KR"). Electron `app.getLocale()`. */
    getLocale(): Promise<string>;
    /** Electron `app.setBadgeCount(count)` 동등. 0 이하면 배지 제거. */
    setBadgeCount(count: number): Promise<boolean>;
    /** Electron `app.getBadgeCount()` 동등. */
    getBadgeCount(): Promise<number>;
    /** dock 진행률 표시. progress<0=hide, 0~1=ratio, >1=100%로 clamp.
     *  Electron `BrowserWindow.setProgressBar` 동등 (macOS는 NSApp.dockTile 공유). */
    setProgressBar(progress: number): Promise<boolean>;
    /** 앱 강제 종료 (Electron `app.exit(code)`). exit code는 무시 (cef.quit 경유). */
    exit(): Promise<boolean>;
    /**
     * Electron `app.requestSingleInstanceLock()` — 이 프로세스를 primary 로 만들고
     * true 반환. 다른 인스턴스가 이미 락을 보유 중이면 false (앱은 보통 quit).
     * 이미 보유 중이면 멱등적으로 true. macOS/Linux=userData flock, Windows=named mutex.
     */
    requestSingleInstanceLock(): Promise<boolean>;
    /** Electron `app.hasSingleInstanceLock()` — 이 프로세스가 락 보유 중인지. */
    hasSingleInstanceLock(): Promise<boolean>;
    /** Electron `app.releaseSingleInstanceLock()` — 보유 락 해제(없으면 no-op). */
    releaseSingleInstanceLock(): Promise<boolean>;
    /** 앱을 frontmost로 (NSApp `activateIgnoringOtherApps:`). */
    focus(): Promise<boolean>;
    /** 모든 윈도우 hide (macOS Cmd+H 동등). */
    hide(): Promise<boolean>;
    /** Electron `app.getPath` 동등. 표준 디렉토리 경로 반환. unknown 키는 빈 문자열. */
    getPath(name: AppPathName): Promise<string>;
    /** dock 아이콘 바운스 시작. 0이면 no-op (앱이 이미 active). 아니면 cancel용 id. */
    requestUserAttention(critical?: boolean): Promise<number>;
    /** requestUserAttention으로 받은 id 취소. id == 0은 false (guard). */
    cancelUserAttentionRequest(id: number): Promise<boolean>;
    /**
     * Security-scoped bookmark 생성 (App Sandbox 영속 파일 접근). 실패 시 null.
     * 비-sandbox 빌드에선 일반 bookmark 로 동작 (sandbox escapement no-op).
     */
    createSecurityScopedBookmark(path: string): Promise<string | null>;
    /** bookmark 해소 + 접근 시작. 실패 시 null. id 를 stop 에 전달. */
    startAccessingSecurityScopedResource(bookmark: string): Promise<{
        id: number;
        path: string;
        stale: boolean;
    } | null>;
    /** 접근 종료. 유효하지 않은 id 는 false. */
    stopAccessingSecurityScopedResource(id: number): Promise<boolean>;
    dock: {
        /** dock 배지 텍스트 — 빈 문자열로 제거. macOS만. */
        setBadge(text: string): Promise<void>;
        /** 현재 배지 텍스트. 미설정이면 빈 문자열. */
        getBadge(): Promise<string>;
    };
};
/**
 * 여러 백엔드에 동시 요청
 */
export declare function fanout<T = unknown>(backends: string[], channel: string, data?: Record<string, unknown>): Promise<T>;
/**
 * 체인 호출 (A → Core → B)
 */
export declare function chain<T = unknown>(from: string, to: string, channel: string, data?: Record<string, unknown>): Promise<T>;
export {};
