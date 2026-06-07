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
var __classPrivateFieldSet = (this && this.__classPrivateFieldSet) || function (receiver, state, value, kind, f) {
    if (kind === "m") throw new TypeError("Private method is not writable");
    if (kind === "a" && !f) throw new TypeError("Private accessor was defined without a setter");
    if (typeof state === "function" ? receiver !== state || !f : !state.has(receiver)) throw new TypeError("Cannot write private member to an object whose class did not declare it");
    return (kind === "a" ? f.call(receiver, value) : f ? f.value = value : state.set(receiver, value)), value;
};
var __classPrivateFieldGet = (this && this.__classPrivateFieldGet) || function (receiver, state, kind, f) {
    if (kind === "a" && !f) throw new TypeError("Private accessor was defined without a getter");
    if (typeof state === "function" ? receiver !== state || !f : !state.has(receiver)) throw new TypeError("Cannot read private member from an object whose class did not declare it");
    return kind === "m" ? f : kind === "a" ? f.call(receiver) : f ? f.value : state.get(receiver);
};
var _BrowserWindow_id;
function getBridge() {
    const bridge = window.__suji__;
    if (!bridge)
        throw new Error("Suji bridge not available. Are you running inside a Suji app?");
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
export async function invoke(cmd, ...rest) {
    const [data, options] = rest;
    return getBridge().invoke(cmd, data, options);
}
/**
 * 이벤트 구독 (Electron: ipcRenderer.on)
 *
 * @returns 리스너 해제 함수
 */
export function on(event, callback) {
    return getBridge().on(event, callback);
}
/**
 * 이벤트 한 번만 구독 (Electron: ipcRenderer.once)
 *
 * @returns 리스너 해제 함수
 */
export function once(event, callback) {
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
export function send(event, data, options) {
    getBridge().emit(event, JSON.stringify(data ?? {}), options?.to);
}
/**
 * 채널의 모든 리스너 해제 (Electron: ipcRenderer.removeAllListeners)
 */
export function off(event) {
    const bridge = window.__suji__;
    if (bridge?.off)
        bridge.off(event);
}
async function coreCall(request) {
    const raw = await getBridge().core(JSON.stringify(request));
    return (typeof raw === "string" ? JSON.parse(raw) : raw);
}
/** deferred-response(`printToPDF`/`capturePage`) 전용 타임아웃 가드. 코어 TTL(30s)
 *  보다 여유를 둔 35s 후 `{success:false}` 로 resolve — 코어가 끝내 응답을 못 보내는
 *  극단(렌더러/GPU 크래시) 에서도 Promise hang 방지. 코어가 늦게 응답해도 race 승자가
 *  이미 정해져 무해. getCookies 의 setTimeout 패턴과 동형. */
function withDeferTimeout(p, timeoutMs) {
    const ms = timeoutMs ?? 35000;
    let timer;
    const timeout = new Promise((resolve) => {
        timer = setTimeout(() => resolve({ success: false }), ms);
    });
    // race 승자 결정 후 clearTimeout — 호출당 dangling 35s 타이머 누수 방지.
    return Promise.race([p, timeout]).finally(() => clearTimeout(timer));
}
export const windows = {
    /**
     * 새 창 생성. Phase 3 옵션 풀 지원 — suji.json `windows[]` 항목과 동일한 키.
     * @returns `{ windowId }` — 후속 setTitle/setBounds 및 `send(_, { to: windowId })`에 사용
     */
    create(opts = {}) {
        return coreCall({ cmd: "create_window", ...opts });
    },
    /** 창 타이틀 변경 */
    setTitle(windowId, title) {
        return coreCall({ cmd: "set_title", windowId, title });
    },
    /** 창 크기/위치 변경. width/height=0이면 현재 유지 */
    setBounds(windowId, bounds) {
        return coreCall({ cmd: "set_bounds", windowId, ...bounds });
    },
    // ── Phase 4-A: webContents 네비/JS ──
    /** 창에 새 URL 로드 (Electron `webContents.loadURL`) */
    loadURL(windowId, url) {
        return coreCall({ cmd: "load_url", windowId, url });
    },
    /** 현재 페이지 reload. ignoreCache=true면 disk 캐시 무시 */
    reload(windowId, ignoreCache = false) {
        return coreCall({ cmd: "reload", windowId, ignoreCache });
    },
    /** 렌더러에서 임의 JS 실행 (Electron `webContents.executeJavaScript`).
     *  결과 회신은 미지원 — fire-and-forget. 결과가 필요하면 JS 측에서 `suji.send`로 회신. */
    executeJavaScript(windowId, code) {
        return coreCall({ cmd: "execute_javascript", windowId, code });
    },
    /** 현재 main frame URL 조회 (캐시된 값). 캐시 미스면 null */
    getURL(windowId) {
        return coreCall({ cmd: "get_url", windowId });
    },
    /** UA 동적 변경 (Electron `webContents.setUserAgent`). CDP
     *  Network.setUserAgentOverride — 이후 네비/요청에 적용. */
    setUserAgent(windowId, userAgent) {
        return coreCall({ cmd: "set_user_agent", windowId, userAgent });
    },
    /** 설정한 UA override 조회 (Electron `webContents.getUserAgent`).
     *  미설정 시 userAgent=null (브라우저 기본 — CEF 가 per-browser
     *  기본 UA getter 미제공). */
    getUserAgent(windowId) {
        return coreCall({ cmd: "get_user_agent", windowId });
    },
    /** 현재 로딩 중인지 조회 (Electron `webContents.isLoading`) */
    isLoading(windowId) {
        return coreCall({ cmd: "is_loading", windowId });
    },
    /** DevTools 열기 — 이미 열려있으면 멱등 no-op */
    openDevTools(windowId) {
        return coreCall({ cmd: "open_dev_tools", windowId });
    },
    /** DevTools 닫기 — 이미 닫혀있으면 no-op */
    closeDevTools(windowId) {
        return coreCall({ cmd: "close_dev_tools", windowId });
    },
    /** DevTools 열려있는지 조회 (Electron `webContents.isDevToolsOpened`) */
    isDevToolsOpened(windowId) {
        return coreCall({ cmd: "is_dev_tools_opened", windowId });
    },
    /** DevTools 토글 — F12 단축키와 동일 동작 */
    toggleDevTools(windowId) {
        return coreCall({ cmd: "toggle_dev_tools", windowId });
    },
    /** 줌 레벨 변경. Electron 호환 — 0 = 100%, 1 = 120%, -1 = 1/1.2 (logarithmic) */
    setZoomLevel(windowId, level) {
        return coreCall({ cmd: "set_zoom_level", windowId, level });
    },
    getZoomLevel(windowId) {
        return coreCall({ cmd: "get_zoom_level", windowId });
    },
    /** 줌 factor 변경. 1.0 = 100%, 1.5 = 150% (linear). 내부적으로 level = log(factor)/log(1.2) 변환 */
    setZoomFactor(windowId, factor) {
        return coreCall({ cmd: "set_zoom_factor", windowId, factor });
    },
    getZoomFactor(windowId) {
        return coreCall({ cmd: "get_zoom_factor", windowId });
    },
    /** 창 오디오 mute (Electron `webContents.setAudioMuted`). */
    setAudioMuted(windowId, muted) {
        return coreCall({ cmd: "set_audio_muted", windowId, muted });
    },
    /** 창 오디오 mute 상태 (Electron `webContents.isAudioMuted`). */
    isAudioMuted(windowId) {
        return coreCall({ cmd: "is_audio_muted", windowId });
    },
    /** 창 투명도 (0~1). Electron `BrowserWindow.setOpacity`. */
    setOpacity(windowId, opacity) {
        return coreCall({ cmd: "set_opacity", windowId, opacity });
    },
    /** 창 투명도 읽기. */
    getOpacity(windowId) {
        return coreCall({ cmd: "get_opacity", windowId });
    },
    /** 배경색 (`#RRGGBB` 또는 `#RRGGBBAA`). Electron `BrowserWindow.setBackgroundColor`. */
    setBackgroundColor(windowId, color) {
        return coreCall({ cmd: "set_background_color", windowId, color });
    },
    /** 그림자 표시 여부. Electron `BrowserWindow.setHasShadow`. */
    setHasShadow(windowId, hasShadow) {
        return coreCall({ cmd: "set_has_shadow", windowId, hasShadow });
    },
    /** 그림자 상태 읽기. Electron `BrowserWindow.hasShadow`. */
    hasShadow(windowId) {
        return coreCall({ cmd: "has_shadow", windowId });
    },
    // ── 창 생명주기 (Electron `BrowserWindow` 패리티 — Zig 백엔드 기존 구현 노출) ──
    minimize(windowId) {
        return coreCall({ cmd: "minimize", windowId });
    },
    maximize(windowId) {
        return coreCall({ cmd: "maximize", windowId });
    },
    unmaximize(windowId) {
        return coreCall({ cmd: "unmaximize", windowId });
    },
    restore(windowId) {
        return coreCall({ cmd: "restore_window", windowId });
    },
    show(windowId) {
        return coreCall({ cmd: "set_visible", windowId, visible: true });
    },
    hide(windowId) {
        return coreCall({ cmd: "set_visible", windowId, visible: false });
    },
    close(windowId) {
        return coreCall({ cmd: "destroy_window", windowId });
    },
    /** 강제 파괴 (Electron `BrowserWindow.destroy`). close 와 달리 `window:close`
     *  (취소 hook)를 스킵하고 `window:closed` 만 발화 — listener 가 막을 수 없음. */
    destroy(windowId) {
        return coreCall({ cmd: "destroy_window_force", windowId });
    },
    setFullScreen(windowId, flag) {
        return coreCall({ cmd: "set_fullscreen", windowId, flag });
    },
    isMinimized(windowId) {
        return coreCall({ cmd: "is_minimized", windowId });
    },
    isMaximized(windowId) {
        return coreCall({ cmd: "is_maximized", windowId });
    },
    isFullScreen(windowId) {
        return coreCall({ cmd: "is_fullscreen", windowId });
    },
    /** Electron BrowserWindow.focus() — 창을 포그라운드로 키 창으로. */
    focus(windowId) {
        return coreCall({ cmd: "focus", windowId });
    },
    /** Electron BrowserWindow.isNormal() — minimized/maximized/fullscreen 모두 아님. */
    isNormal(windowId) {
        return coreCall({ cmd: "is_normal", windowId });
    },
    /** Electron BrowserWindow.getBounds() — {x,y,width,height} (top-left 원점). */
    getBounds(windowId) {
        return coreCall({ cmd: "get_bounds", windowId });
    },
    /** Electron BrowserWindow.getSize() — [width, height]. getBounds 에서 파생. */
    async getSize(windowId) {
        const b = await windows.getBounds(windowId);
        return [b.width, b.height];
    },
    /** Electron BrowserWindow.getPosition() — [x, y]. getBounds 에서 파생. */
    async getPosition(windowId) {
        const b = await windows.getBounds(windowId);
        return [b.x, b.y];
    },
    /** Electron BrowserWindow.getContentBounds() — 콘텐츠 영역(프레임/타이틀바 제외). */
    getContentBounds(windowId) {
        return coreCall({ cmd: "get_content_bounds", windowId });
    },
    /** Electron BrowserWindow.setContentBounds() — 콘텐츠 영역을 지정 사각형으로. */
    setContentBounds(windowId, bounds) {
        return coreCall({ cmd: "set_content_bounds", windowId, ...bounds });
    },
    /** Electron BrowserWindow.getContentSize() — [width, height]. getContentBounds 에서 파생. */
    async getContentSize(windowId) {
        const b = await windows.getContentBounds(windowId);
        return [b.width, b.height];
    },
    /** Electron BrowserWindow.setSize(width, height) — 위치 유지(getBounds→setBounds 파생).
     *  `animate` 는 받되 무시(CEF Views set_bounds 비애니메이션 — 정직). */
    async setSize(windowId, width, height, _animate) {
        const b = await windows.getBounds(windowId);
        if (!b.ok)
            return b; // getBounds 실패(창 없음) → 0,0 으로 이동 방지
        return windows.setBounds(windowId, { x: b.x, y: b.y, width, height });
    },
    /** Electron BrowserWindow.setPosition(x, y) — 크기 유지(getBounds→setBounds 파생). `animate` 무시. */
    async setPosition(windowId, x, y, _animate) {
        const b = await windows.getBounds(windowId);
        if (!b.ok)
            return b; // getBounds 실패 → 0 크기로 collapse 방지
        return windows.setBounds(windowId, { x, y, width: b.width, height: b.height });
    },
    /** Electron BrowserWindow.setMinimumSize(width, height). 0 = 제한 없음. */
    setMinimumSize(windowId, width, height) {
        return coreCall({ cmd: "set_minimum_size", windowId, width, height });
    },
    /** Electron BrowserWindow.getMinimumSize() — [width, height] (추적된 제약값, 0=없음). */
    async getMinimumSize(windowId) {
        const r = await coreCall({ cmd: "get_minimum_size", windowId });
        return [r.width, r.height];
    },
    /** Electron BrowserWindow.setMaximumSize(width, height). 0 = 제한 없음. */
    setMaximumSize(windowId, width, height) {
        return coreCall({ cmd: "set_maximum_size", windowId, width, height });
    },
    /** Electron BrowserWindow.getMaximumSize() — [width, height] (추적된 제약값, 0=없음). */
    async getMaximumSize(windowId) {
        const r = await coreCall({ cmd: "get_maximum_size", windowId });
        return [r.width, r.height];
    },
    /** Electron BrowserWindow.setResizable(resizable). false 면 사용자 리사이즈 불가. */
    setResizable(windowId, resizable) {
        return coreCall({ cmd: "set_resizable", windowId, resizable });
    },
    /** Electron BrowserWindow.isResizable(). */
    isResizable(windowId) {
        return coreCall({ cmd: "is_resizable", windowId });
    },
    /** Electron BrowserWindow.setMinimizable(minimizable). */
    setMinimizable(windowId, minimizable) {
        return coreCall({ cmd: "set_minimizable", windowId, minimizable });
    },
    /** Electron BrowserWindow.isMinimizable(). */
    isMinimizable(windowId) {
        return coreCall({ cmd: "is_minimizable", windowId });
    },
    /** Electron BrowserWindow.setMaximizable(maximizable). */
    setMaximizable(windowId, maximizable) {
        return coreCall({ cmd: "set_maximizable", windowId, maximizable });
    },
    /** Electron BrowserWindow.isMaximizable(). */
    isMaximizable(windowId) {
        return coreCall({ cmd: "is_maximizable", windowId });
    },
    /** Electron BrowserWindow.setClosable(closable). false 면 닫기 불가. */
    setClosable(windowId, closable) {
        return coreCall({ cmd: "set_closable", windowId, closable });
    },
    /** Electron BrowserWindow.isClosable(). */
    isClosable(windowId) {
        return coreCall({ cmd: "is_closable", windowId });
    },
    /** Electron BrowserWindow.blur() — 창 포커스 해제. */
    blur(windowId) {
        return coreCall({ cmd: "blur", windowId });
    },
    /** Electron BrowserWindow.isFocused(). */
    isFocused(windowId) {
        return coreCall({ cmd: "is_focused", windowId });
    },
    /** Electron BrowserWindow.isVisible(). */
    isVisible(windowId) {
        return coreCall({ cmd: "is_visible", windowId });
    },
    /** Electron BrowserWindow.setAlwaysOnTop(flag). */
    setAlwaysOnTop(windowId, flag) {
        return coreCall({ cmd: "set_always_on_top", windowId, onTop: flag });
    },
    /** Electron BrowserWindow.isAlwaysOnTop(). */
    isAlwaysOnTop(windowId) {
        return coreCall({ cmd: "is_always_on_top", windowId });
    },
    /** Electron BrowserWindow.getAllWindows() — 살아있는 top-level 창 id (view 제외). */
    getAllWindows() {
        return coreCall({ cmd: "get_all_windows" });
    },
    /** Electron BrowserWindow.getFocusedWindow() — 포커스 창 id 또는 null. */
    getFocusedWindow() {
        return coreCall({ cmd: "get_focused_window" });
    },
    // Phase 4-E: 편집 — 모두 main frame에 위임. 응답은 ok만.
    undo(windowId) {
        return coreCall({ cmd: "undo", windowId });
    },
    redo(windowId) {
        return coreCall({ cmd: "redo", windowId });
    },
    cut(windowId) {
        return coreCall({ cmd: "cut", windowId });
    },
    copy(windowId) {
        return coreCall({ cmd: "copy", windowId });
    },
    paste(windowId) {
        return coreCall({ cmd: "paste", windowId });
    },
    selectAll(windowId) {
        return coreCall({ cmd: "select_all", windowId });
    },
    /** 페이지 텍스트 검색. 첫 호출은 findNext=false, 이후 같은 단어 다음 매치는 true.
     *  결과 보고는 cef_find_handler_t로 (현재 미노출 — 추후 이벤트). */
    findInPage(windowId, text, options) {
        return coreCall({
            cmd: "find_in_page",
            windowId,
            text,
            forward: options?.forward ?? true,
            matchCase: options?.matchCase ?? false,
            findNext: options?.findNext ?? false,
        });
    },
    stopFindInPage(windowId, clearSelection = false) {
        return coreCall({ cmd: "stop_find_in_page", windowId, clearSelection });
    },
    /** PDF로 인쇄 (Electron `webContents.printToPDF`). 코어가 CDP 완료까지 응답
     *  보류 → 단일 await 로 결과(`{success}`) 받음. EventBus `window:pdf-print-
     *  finished` emit 은 다른 구독자(다른 백엔드/창) 호환 유지.
     *
     *  defense-in-depth: 코어가 CDP 콜백 미발화(렌더러/GPU 크래시 등)로 응답을
     *  영영 안 보내는 극단 경우, SDK 타임아웃(기본 35s)이 `{success:false}`로
     *  settle 해 Promise 영구 hang 방지. 코어가 늦게 응답해도 무해(이미 settled). */
    async printToPDF(windowId, path, opts) {
        const r = await withDeferTimeout(coreCall({ cmd: "print_to_pdf", windowId, path }), opts?.timeoutMs);
        return { success: r?.success === true };
    },
    /** 페이지 스크린샷 PNG 저장 (Electron `webContents.capturePage` — CDP
     *  Page.captureScreenshot). 코어 deferred response 로 단일 await.
     *  base64 가 IPC 한도(64KB) 초과 가능해 path 파일 방식.
     *  rect 지정 시 부분 영역만; 미지정=전체. defense-in-depth 타임아웃은 printToPDF 동일. */
    async capturePage(windowId, path, rect, opts) {
        const r = await withDeferTimeout(coreCall({
            cmd: "capture_page", windowId, path,
            ...(rect ? { clipX: rect.x, clipY: rect.y, clipWidth: rect.width, clipHeight: rect.height } : {}),
        }), opts?.timeoutMs);
        return { success: r?.success === true };
    },
    // ── Phase 17-A: WebContentsView ──
    // viewId는 windowId와 같은 풀이라 loadURL/executeJavaScript/openDevTools/setZoomFactor
    // 등 모든 webContents API에 viewId를 그대로 넘기면 동작.
    /** host 창 contentView 안에 새 view 합성 (Electron `WebContentsView`). 자동으로 host의
     *  view_children top에 추가됨 — 이후 addChildView로 z-order 변경 가능. bounds 미지정 시
     *  800x600 @ 0,0 (코어의 parseBoundsFromJson은 누락 키를 0으로 채워 SDK가 default 적용). */
    createView(opts) {
        return coreCall({
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
    destroyView(viewId) {
        return coreCall({ cmd: "destroy_view", viewId });
    },
    /** view를 host children에 추가/재배치. index 생략 시 top. 같은 view 재호출 시 위치 갱신
     *  (Electron WebContentsView idiom). host 이동은 미지원. */
    addChildView(hostId, viewId, index) {
        return coreCall({ cmd: "add_child_view", hostId, viewId, index });
    },
    /** view를 host children에서 분리 (destroy X). native에서 setHidden(true). 다시 addChildView
     *  로 같은 host에 붙일 수 있음. */
    removeChildView(hostId, viewId) {
        return coreCall({ cmd: "remove_child_view", hostId, viewId });
    },
    /** addChildView(host, view, undefined) 편의 — Electron `setTopBrowserView` 동등 */
    setTopView(hostId, viewId) {
        return coreCall({ cmd: "set_top_view", hostId, viewId });
    },
    /** view 위치/크기 변경. host contentView 좌표계 (top-left). */
    setViewBounds(viewId, bounds) {
        return coreCall({ cmd: "set_view_bounds", viewId, ...bounds });
    },
    /** view 표시/숨김 토글. CEF host.was_hidden도 함께 호출 (렌더링/입력 일시정지) */
    setViewVisible(viewId, visible) {
        return coreCall({ cmd: "set_view_visible", viewId, visible });
    },
    /** host의 child view id들을 z-order 순서로 조회 (0=bottom, 마지막=top) */
    getChildViews(hostId) {
        return coreCall({ cmd: "get_child_views", hostId });
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
    constructor(id) {
        _BrowserWindow_id.set(this, void 0);
        __classPrivateFieldSet(this, _BrowserWindow_id, id, "f");
    }
    /** 후속 IPC/`send(_, { to })` 및 view host 인자로 쓰는 창 id. */
    get id() {
        return __classPrivateFieldGet(this, _BrowserWindow_id, "f");
    }
    /** 새 창 생성 후 인스턴스 반환 (Electron `new BrowserWindow(opts)`). */
    static async create(opts = {}) {
        const res = await windows.create(opts);
        // windowId 부재 시 좀비 인스턴스 방지 — Rust None / Go error 와 시맨틱 일치.
        if (typeof res.windowId !== "number") {
            throw new Error(`create_window: no windowId in response (${JSON.stringify(res)})`);
        }
        return new BrowserWindow(res.windowId);
    }
    /** 기존 windowId(예: 메인 창, 이벤트의 windowId)를 인스턴스로 래핑. */
    static fromId(id) {
        return new BrowserWindow(id);
    }
    /** Electron BrowserWindow.getAllWindows() — 살아있는 top-level 창 인스턴스 배열. */
    static async getAllWindows() {
        const r = await windows.getAllWindows();
        return r.windowIds.map((id) => BrowserWindow.fromId(id));
    }
    /** Electron BrowserWindow.getFocusedWindow() — 포커스 창 인스턴스 또는 null. */
    static async getFocusedWindow() {
        const r = await windows.getFocusedWindow();
        return r.windowId == null ? null : BrowserWindow.fromId(r.windowId);
    }
    setTitle(title) {
        return windows.setTitle(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), title);
    }
    setBounds(bounds) {
        return windows.setBounds(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), bounds);
    }
    loadURL(url) {
        return windows.loadURL(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), url);
    }
    reload(ignoreCache = false) {
        return windows.reload(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), ignoreCache);
    }
    executeJavaScript(code) {
        return windows.executeJavaScript(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), code);
    }
    getURL() {
        return windows.getURL(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setUserAgent(userAgent) {
        return windows.setUserAgent(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), userAgent);
    }
    getUserAgent() {
        return windows.getUserAgent(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    isLoading() {
        return windows.isLoading(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    openDevTools() {
        return windows.openDevTools(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    closeDevTools() {
        return windows.closeDevTools(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    isDevToolsOpened() {
        return windows.isDevToolsOpened(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    toggleDevTools() {
        return windows.toggleDevTools(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setZoomLevel(level) {
        return windows.setZoomLevel(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), level);
    }
    getZoomLevel() {
        return windows.getZoomLevel(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setZoomFactor(factor) {
        return windows.setZoomFactor(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), factor);
    }
    getZoomFactor() {
        return windows.getZoomFactor(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setAudioMuted(muted) {
        return windows.setAudioMuted(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), muted);
    }
    isAudioMuted() {
        return windows.isAudioMuted(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setOpacity(opacity) {
        return windows.setOpacity(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), opacity);
    }
    getOpacity() {
        return windows.getOpacity(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setBackgroundColor(color) {
        return windows.setBackgroundColor(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), color);
    }
    setHasShadow(hasShadow) {
        return windows.setHasShadow(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), hasShadow);
    }
    hasShadow() {
        return windows.hasShadow(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    // ── 창 생명주기 (Electron BrowserWindow 패리티) ──
    minimize() {
        return windows.minimize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    maximize() {
        return windows.maximize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    unmaximize() {
        return windows.unmaximize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    restore() {
        return windows.restore(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    show() {
        return windows.show(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    hide() {
        return windows.hide(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    close() {
        return windows.close(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    /** 강제 파괴 (Electron `BrowserWindow.destroy`) — `window:close` 스킵, `window:closed` 만. */
    destroy() {
        return windows.destroy(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setFullScreen(flag) {
        return windows.setFullScreen(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), flag);
    }
    isMinimized() {
        return windows.isMinimized(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    isMaximized() {
        return windows.isMaximized(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    isFullScreen() {
        return windows.isFullScreen(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    focus() {
        return windows.focus(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    isNormal() {
        return windows.isNormal(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    getBounds() {
        return windows.getBounds(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    getSize() {
        return windows.getSize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    getPosition() {
        return windows.getPosition(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    getContentBounds() {
        return windows.getContentBounds(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setContentBounds(bounds) {
        return windows.setContentBounds(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), bounds);
    }
    getContentSize() {
        return windows.getContentSize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setSize(width, height, animate) {
        return windows.setSize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), width, height, animate);
    }
    setPosition(x, y, animate) {
        return windows.setPosition(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), x, y, animate);
    }
    setMinimumSize(width, height) {
        return windows.setMinimumSize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), width, height);
    }
    getMinimumSize() {
        return windows.getMinimumSize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setMaximumSize(width, height) {
        return windows.setMaximumSize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), width, height);
    }
    getMaximumSize() {
        return windows.getMaximumSize(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setResizable(resizable) {
        return windows.setResizable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), resizable);
    }
    isResizable() {
        return windows.isResizable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setMinimizable(minimizable) {
        return windows.setMinimizable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), minimizable);
    }
    isMinimizable() {
        return windows.isMinimizable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setMaximizable(maximizable) {
        return windows.setMaximizable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), maximizable);
    }
    isMaximizable() {
        return windows.isMaximizable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setClosable(closable) {
        return windows.setClosable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), closable);
    }
    isClosable() {
        return windows.isClosable(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    blur() {
        return windows.blur(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    isFocused() {
        return windows.isFocused(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    isVisible() {
        return windows.isVisible(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    setAlwaysOnTop(flag) {
        return windows.setAlwaysOnTop(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), flag);
    }
    isAlwaysOnTop() {
        return windows.isAlwaysOnTop(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    undo() {
        return windows.undo(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    redo() {
        return windows.redo(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    cut() {
        return windows.cut(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    copy() {
        return windows.copy(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    paste() {
        return windows.paste(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    selectAll() {
        return windows.selectAll(__classPrivateFieldGet(this, _BrowserWindow_id, "f"));
    }
    findInPage(text, options) {
        return windows.findInPage(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), text, options);
    }
    stopFindInPage(clearSelection = false) {
        return windows.stopFindInPage(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), clearSelection);
    }
    printToPDF(path) {
        return windows.printToPDF(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), path);
    }
    capturePage(path, rect) {
        return windows.capturePage(__classPrivateFieldGet(this, _BrowserWindow_id, "f"), path, rect);
    }
}
_BrowserWindow_id = new WeakMap();
// ============================================
// clipboard — 시스템 클립보드 (Electron `clipboard.readText/writeText`)
// ============================================
// macOS NSPasteboard, Linux GTK clipboard, Windows CF_UNICODETEXT/CF_HTML.
export const powerMonitor = {
    /** 시스템 유휴 시간 (초). 활성 입력 후 0으로 리셋.
     *  Electron `powerMonitor.getSystemIdleTime()` 동등. */
    async getSystemIdleTime() {
        const r = await coreCall({ cmd: "power_monitor_get_idle_time" });
        return r.seconds;
    },
    /** 화면 잠금이면 "locked", 유휴 시간 ≥ threshold(초)면 "idle", 아니면 "active".
     *  Electron `powerMonitor.getSystemIdleState(threshold)` 동등. */
    async getSystemIdleState(threshold) {
        const r = await coreCall({
            cmd: "power_monitor_get_idle_state",
            threshold,
        });
        return r.state;
    },
    /** Electron `powerMonitor.isOnBatteryPower()` — 현재 배터리 전원 여부.
     *  macOS IOKit / Windows GetSystemPowerStatus / Linux /sys. 정보 없으면 false. */
    async isOnBatteryPower() {
        const r = await coreCall({ cmd: "power_monitor_is_on_battery" });
        return r.onBattery === true;
    },
};
export const clipboard = {
    /** 클립보드의 plain text 읽기. 비어 있거나 non-text면 빈 문자열. */
    async readText() {
        const r = await coreCall({ cmd: "clipboard_read_text" });
        return r.text ?? "";
    },
    /** 클립보드에 plain text 쓰기. 성공 시 true. */
    async writeText(text) {
        const r = await coreCall({ cmd: "clipboard_write_text", text });
        return r.success === true;
    },
    /** 클립보드 비우기. */
    async clear() {
        const r = await coreCall({ cmd: "clipboard_clear" });
        return r.success === true;
    },
    /** HTML read (NSPasteboard `public.html`). 비어 있거나 non-html이면 빈 문자열. */
    async readHTML() {
        const r = await coreCall({ cmd: "clipboard_read_html" });
        return r.html ?? "";
    },
    /** HTML write — write 시 다른 type (text 등)도 함께 지움. */
    async writeHTML(html) {
        const r = await coreCall({ cmd: "clipboard_write_html", html });
        return r.success === true;
    },
    /** RTF read (Electron `clipboard.readRTF`). 비어 있거나 non-rtf면 빈 문자열. */
    async readRTF() {
        const r = await coreCall({ cmd: "clipboard_read_rtf" });
        return r.rtf ?? "";
    },
    /** RTF write (Electron `clipboard.writeRTF`). 다른 type 지움. */
    async writeRTF(rtf) {
        const r = await coreCall({ cmd: "clipboard_write_rtf", rtf });
        return r.success === true;
    },
    /** 임의 UTI raw bytes 쓰기 (Electron `clipboard.writeBuffer(format, buffer)`).
     *  data는 base64 인코딩된 문자열 (raw ~8KB 한도). */
    async writeBuffer(format, data) {
        const r = await coreCall({ cmd: "clipboard_write_buffer", format, data });
        return r.success === true;
    },
    /** 임의 UTI raw bytes 읽기 (Electron `clipboard.readBuffer(format)`). base64 string 반환. */
    async readBuffer(format) {
        const r = await coreCall({ cmd: "clipboard_read_buffer", format });
        return r.data ?? "";
    },
    /** 클립보드에 주어진 format이 있는지 (Electron `clipboard.has(format)`).
     *  format은 macOS UTI ("public.utf8-plain-text", "public.html" 등). */
    async has(format) {
        const r = await coreCall({ cmd: "clipboard_has", format });
        return r.present === true;
    },
    /** 클립보드에 등록된 모든 format (UTI) 배열. */
    async availableFormats() {
        const r = await coreCall({ cmd: "clipboard_available_formats" });
        return r.formats ?? [];
    },
    /** PNG 이미지 쓰기 — base64 문자열. 다른 type 함께 지움. (Electron `writeImage`). */
    async writeImage(pngBase64) {
        const r = await coreCall({ cmd: "clipboard_write_image", data: pngBase64 });
        return r.success === true;
    },
    /** PNG 이미지 읽기 — base64 반환. PNG 아니면 빈 문자열. */
    async readImage() {
        const r = await coreCall({ cmd: "clipboard_read_image" });
        return r.data ?? "";
    },
    /** TIFF 이미지 쓰기 — base64 문자열 (NSPasteboard `public.tiff`). writeImage 동형. */
    async writeTiff(tiffBase64) {
        const r = await coreCall({ cmd: "clipboard_write_tiff", data: tiffBase64 });
        return r.success === true;
    },
    /** TIFF 이미지 읽기 — base64 반환. TIFF 아니면 빈 문자열. */
    async readTiff() {
        const r = await coreCall({ cmd: "clipboard_read_tiff" });
        return r.data ?? "";
    },
};
export const notification = {
    /** 플랫폼 지원 여부 — macOS bundle/권한, Linux daemon, Windows tray balloon 상태를 반영. */
    async isSupported() {
        const r = await coreCall({ cmd: "notification_is_supported" });
        return r.supported === true;
    },
    /** 알림 권한 요청 — 첫 호출 시 OS 다이얼로그. 이후 캐시. */
    async requestPermission() {
        const r = await coreCall({ cmd: "notification_request_permission" });
        return r.granted === true;
    },
    /** 알림 표시. 반환 `notificationId`로 close 가능. success=false면 권한/번들 문제. */
    async show(options) {
        return coreCall({
            cmd: "notification_show",
            ...options,
        });
    },
    async close(notificationId) {
        const r = await coreCall({ cmd: "notification_close", notificationId });
        return r.success === true;
    },
    /** Electron `Notification` 전체 제거 — 표시/대기 모든 알림(macOS 실동작). */
    async removeAll() {
        const r = await coreCall({ cmd: "notification_remove_all" });
        return r.success === true;
    },
};
export const tray = {
    /** 새 시스템 트레이 아이콘 생성. 반환된 trayId로 이후 update/destroy. */
    async create(options = {}) {
        return coreCall({ cmd: "tray_create", ...options });
    },
    async setTitle(trayId, title) {
        const r = await coreCall({ cmd: "tray_set_title", trayId, title });
        return r.success === true;
    },
    async setTooltip(trayId, tooltip) {
        const r = await coreCall({ cmd: "tray_set_tooltip", trayId, tooltip });
        return r.success === true;
    },
    /** 트레이 클릭 시 표시될 컨텍스트 메뉴 설정. macOS/Linux는 submenu/checkbox도 지원.
     *  메뉴 항목 클릭은 `suji.on('tray:menu-click', ({trayId, click}) => ...)` 로 수신. */
    async setMenu(trayId, items) {
        const r = await coreCall({ cmd: "tray_set_menu", trayId, items });
        return r.success === true;
    },
    async destroy(trayId) {
        const r = await coreCall({ cmd: "tray_destroy", trayId });
        return r.success === true;
    },
};
export const menu = {
    async setApplicationMenu(items) {
        const r = await coreCall({ cmd: "menu_set_application_menu", items });
        return r.success === true;
    },
    async resetApplicationMenu() {
        const r = await coreCall({ cmd: "menu_reset_application_menu" });
        return r.success === true;
    },
    /** 임의 위치 컨텍스트 메뉴 (Electron `Menu.popup({x?,y?})`). x/y 미지정 시
     *  현재 커서(화면 좌표, macOS bottom-up). 선택은 `suji.on('menu:click',
     *  ({click}) => ...)` 로 수신 (setApplicationMenu 와 동일). macOS NSMenu
     *  `popUpMenuPositioningItem:atLocation:inView:` — 동기 모달. */
    async popup(items, opts = {}) {
        const r = await coreCall({
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
    async register(accelerator, click) {
        const r = await coreCall({ cmd: "global_shortcut_register", accelerator, click });
        return r.success === true;
    },
    async unregister(accelerator) {
        const r = await coreCall({ cmd: "global_shortcut_unregister", accelerator });
        return r.success === true;
    },
    async unregisterAll() {
        const r = await coreCall({ cmd: "global_shortcut_unregister_all" });
        return r.success === true;
    },
    async isRegistered(accelerator) {
        const r = await coreCall({ cmd: "global_shortcut_is_registered", accelerator });
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
    async openExternal(url) {
        const r = await coreCall({ cmd: "shell_open_external", url });
        return r.success === true;
    },
    /** Finder/탐색기에서 파일/폴더 reveal — 부모 폴더 열리고 항목 선택. 경로 없으면 false. */
    async showItemInFolder(path) {
        const r = await coreCall({ cmd: "shell_show_item_in_folder", path });
        return r.success === true;
    },
    /** 시스템 비프음. */
    async beep() {
        const r = await coreCall({ cmd: "shell_beep" });
        return r.success === true;
    },
    /** 휴지통으로 이동. macOS NSFileManager `trashItemAtURL:`. 실패하면 false. */
    async trashItem(path) {
        const r = await coreCall({ cmd: "shell_trash_item", path });
        return r.success === true;
    },
    /** 파일/폴더를 기본 앱으로 열기 (`openExternal`은 URL용, 이건 로컬 path용).
     *  존재하지 않는 경로는 false. macOS NSWorkspace `openURL:` (file://). */
    async openPath(path) {
        const r = await coreCall({ cmd: "shell_open_path", path });
        return r.success === true;
    },
};
export const nativeImage = {
    /** 이미지 파일 → 크기 {width, height} (point 단위, NSImage). 파일 없거나 디코딩 실패는 0/0.
     *  Electron `nativeImage.createFromPath(path).getSize()` 동등. */
    async getSize(path) {
        const r = await coreCall({ cmd: "native_image_get_size", path });
        return { width: r.width, height: r.height };
    },
    /** 이미지 파일 → PNG base64 (raw ~8KB 한도, 작은 아이콘용 1차).
     *  Electron `nativeImage.createFromPath(path).toPNG()` → base64.toString('base64'). */
    async toPng(path) {
        const r = await coreCall({ cmd: "native_image_to_png", path });
        return r.data ?? "";
    },
    /** 이미지 파일 → JPEG base64. quality 0~100 (기본 90). */
    async toJpeg(path, quality = 90) {
        const r = await coreCall({ cmd: "native_image_to_jpeg", path, quality });
        return r.data ?? "";
    },
};
export const nativeTheme = {
    /** 시스템 다크 모드 활성 여부 (Electron `nativeTheme.shouldUseDarkColors`).
     *  macOS NSApp.effectiveAppearance.name이 Dark 계열이면 true. */
    async shouldUseDarkColors() {
        const r = await coreCall({ cmd: "native_theme_should_use_dark_colors" });
        return r.dark === true;
    },
    /** `themeSource = "light" | "dark" | "system"` setter (Electron 동등).
     *  system은 OS 따름 (NSApp.appearance = nil), light/dark는 NSAppearance 강제.
     *  잘못된 값은 false. */
    async setThemeSource(source) {
        const r = await coreCall({ cmd: "native_theme_set_source", source });
        return r.success === true;
    },
    /** Electron `nativeTheme.themeSource` (getter) — 마지막 설정값(기본 "system"). */
    async getThemeSource() {
        const r = await coreCall({ cmd: "native_theme_get_source" });
        return r.source;
    },
};
export const fs = {
    async readFile(path) {
        const r = await coreCall({ cmd: "fs_read_file", path });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_read_file failed");
        return r.text;
    },
    async writeFile(path, text) {
        const r = await coreCall({ cmd: "fs_write_file", path, text });
        return r.success === true;
    },
    async stat(path) {
        const r = await coreCall({ cmd: "fs_stat", path });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_stat failed");
        return r;
    },
    async mkdir(path, options = {}) {
        const r = await coreCall({ cmd: "fs_mkdir", path, recursive: options.recursive === true });
        return r.success === true;
    },
    async readdir(path) {
        const r = await coreCall({ cmd: "fs_readdir", path });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_readdir failed");
        return r.entries;
    },
    /** Remove `path`. `recursive` deletes directories; `force` ignores not-found (matches `node:fs.rm`). */
    async rm(path, options = {}) {
        const r = await coreCall({
            cmd: "fs_rm",
            path,
            recursive: options.recursive === true,
            force: options.force === true,
        });
        if (r.success !== true)
            throw new Error(r.error ?? "fs_rm failed");
        return true;
    },
};
/// Dialog 함수의 Electron 두-인자 오버로드 분해. 첫 인자가 number면 windowId(=sheet 부모),
/// 아니면 options 단일 인자로 free-floating modal.
function splitDialogArgs(arg1, arg2) {
    if (typeof arg1 === "number") {
        return { windowId: arg1, options: (arg2 ?? {}) };
    }
    return { options: arg1 };
}
let activePermissionOff = null;
export const session = {
    /** 모든 cookie 삭제 (Electron `session.clearStorageData({storages:["cookies"]})`).
     *  fire-and-forget — 실제 cleanup은 비동기. */
    async clearCookies() {
        const r = await coreCall({ cmd: "session_clear_cookies" });
        return r.success === true;
    },
    /** disk store flush (Electron `session.cookies.flushStore`). */
    async flushStore() {
        const r = await coreCall({ cmd: "session_flush_store" });
        return r.success === true;
    },
    /**
     * Electron `session.setProxy(config)` — Chromium "proxy" preference 설정.
     * mode 미지정/`"direct"` → 프록시 해제. `proxyRules`: `"host:port"` 또는
     * `"http=foo:80;https=bar:80"`. 이후 요청에 적용. fire-and-forget(설정 성공 bool).
     */
    async setProxy(config) {
        const r = await coreCall({
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
    async setPermissionRequestHandler(handler) {
        if (activePermissionOff) {
            activePermissionOff();
            activePermissionOff = null;
        }
        if (!handler) {
            await coreCall({ cmd: "session_set_permission_handler", enabled: false });
            return;
        }
        activePermissionOff = on("session:permission-request", (payload) => {
            let ev;
            try {
                ev = typeof payload === "string" ? JSON.parse(payload) : payload;
            }
            catch {
                // malformed payload: 응답할 permissionId 가 없음 — 무시(핸들러 안 깨지게).
                return;
            }
            let settled = false;
            const respond = (granted) => {
                if (settled)
                    return;
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
    async clearStorageData(origin = "", storageTypes = "all") {
        const r = await coreCall({
            cmd: "session_clear_storage_data", origin, storageTypes,
        });
        return r.success === true;
    },
    /** Electron `session.cookies.set`. expires는 unix epoch second (0 → 세션 쿠키). */
    async setCookie(cookie) {
        const r = await coreCall({
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
    async removeCookies(url, name) {
        const r = await coreCall({
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
    async getCookies(filter = {}) {
        return new Promise((resolve) => {
            let id = 0;
            let pending = null;
            const timer = setTimeout(() => {
                off();
                resolve([]);
            }, 1000);
            const off = on("session:cookies-result", (data) => {
                const raw = typeof data === "string" ? JSON.parse(data) : data;
                const ev = raw;
                if (id === 0) {
                    pending = ev;
                    return;
                }
                if (ev.requestId !== id)
                    return;
                clearTimeout(timer);
                off();
                resolve(ev.cookies ?? []);
            });
            coreCall({
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
    async showMessageBox(arg1, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        return coreCall({
            cmd: "dialog_show_message_box",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
    },
    /** 단순 에러 popup (NSAlert critical style + OK 버튼). 응답 없음 — Electron 동등. */
    async showErrorBox(title, content) {
        await coreCall({ cmd: "dialog_show_error_box", title, content });
    },
    /** 파일/폴더 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePaths:[]}`. */
    async showOpenDialog(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        return coreCall({
            cmd: "dialog_show_open_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
    },
    /** 저장 경로 선택. 첫 인자 windowId면 sheet. 취소면 `{canceled:true, filePath:""}`. */
    async showSaveDialog(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        return coreCall({
            cmd: "dialog_show_save_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
    },
    // ── Sync 변종 — Electron 호환. modal 동안 부모 창 입력 차단되는 건 async와 동일.
    // JS 측 응답 shape만 다름: number / string[] | undefined / string | undefined.
    /** Sync 변종 — `response: number`만 반환. windowId 첫 인자 지원. */
    async showMessageBoxSync(arg1, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        const r = await coreCall({
            cmd: "dialog_show_message_box",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
        return r.response;
    },
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string[]`. windowId 첫 인자 지원. */
    async showOpenDialogSync(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        const r = await coreCall({
            cmd: "dialog_show_open_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
        return r.canceled ? undefined : r.filePaths;
    },
    /** Sync 변종 — 취소면 `undefined`, 아니면 `string`. windowId 첫 인자 지원. */
    async showSaveDialogSync(arg1 = {}, arg2) {
        const { windowId, options } = splitDialogArgs(arg1, arg2);
        const r = await coreCall({
            cmd: "dialog_show_save_dialog",
            ...(windowId !== undefined ? { windowId } : {}),
            ...options,
        });
        return r.canceled ? undefined : r.filePath;
    },
};
let activeListenerOff = null;
export const webRequest = {
    /** blocklist 패턴 list 갱신 (전체 교체). 빈 list = 모든 요청 통과. 최대 32개, 256자/패턴. */
    async setBlockedUrls(patterns) {
        const r = await coreCall({
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
    async onBeforeRequest(filter, listener, options) {
        if (activeListenerOff) {
            activeListenerOff();
            activeListenerOff = null;
        }
        const patterns = filter && listener ? filter.urls : [];
        await coreCall({ cmd: "web_request_set_listener_filter", patterns });
        if (!listener || patterns.length === 0)
            return;
        const timeoutMs = options?.timeoutMs ?? 5000;
        activeListenerOff = on("webRequest:will-request", (payload) => {
            let ev;
            try {
                ev = typeof payload === "string" ? JSON.parse(payload) : payload;
            }
            catch {
                // malformed payload: resolve할 id가 없음 — 무시 (listener 안 깨지게).
                return;
            }
            let settled = false;
            let timer = null;
            const resolveOnce = (cancel) => {
                if (settled)
                    return;
                settled = true;
                if (timer)
                    clearTimeout(timer);
                void coreCall({ cmd: "web_request_resolve", id: ev.id, cancel });
            };
            if (timeoutMs > 0) {
                // 미응답 → 자동 통과(fail-open). 네이티브 hold 해제.
                timer = setTimeout(() => resolveOnce(false), timeoutMs);
            }
            try {
                listener({ url: ev.url, id: ev.id }, (decision) => resolveOnce(!!decision?.cancel));
            }
            catch {
                // listener 동기 throw → fail-open(통과). hang 방지.
                resolveOnce(false);
            }
        });
    },
    /** listener 직접 detach (파라미터 없는 onBeforeRequest와 동등). */
    async clearListener() {
        return this.onBeforeRequest(null, null);
    },
};
export const screen = {
    /** 연결된 모든 모니터의 bounds/scale 정보. macOS NSScreen 기반. */
    async getAllDisplays() {
        const r = await coreCall({ cmd: "screen_get_all_displays" });
        return r.displays;
    },
    /** 마우스 포인터 화면 좌표 (macOS NSEvent.mouseLocation). bottom-up 좌표계. */
    async getCursorScreenPoint() {
        const r = await coreCall({ cmd: "screen_get_cursor_point" });
        return { x: r.x, y: r.y };
    },
    /** (x,y)를 포함하는 display index. 어느 display에도 포함 안 되면 -1. */
    async getDisplayNearestPoint(point) {
        const r = await coreCall({ cmd: "screen_get_display_nearest_point", x: point.x, y: point.y });
        return r.index;
    },
    /** Primary display 객체 반환 (없으면 null) — getAllDisplays.find(isPrimary) wrapper. */
    async getPrimaryDisplay() {
        const all = await this.getAllDisplays();
        return all.find((d) => d.isPrimary) ?? all[0] ?? null;
    },
    /**
     * rect(보통 창 bounds)와 가장 많이 겹치는 Display (Electron `screen.getDisplayMatching`).
     * 듀얼/멀티모니터에서 "이 창이 있는 모니터" 판정 — 겹침 없으면 중심 최근접.
     * 매칭 계산은 코어 cmd `screen_get_display_matching`(전 언어 SDK 공유)이 수행하고,
     * 여기선 그 index 로 getAllDisplays 에서 Display 를 해석해 반환.
     */
    async getDisplayMatching(rect) {
        const r = await coreCall({ cmd: "screen_get_display_matching", ...rect });
        if (r.index < 0)
            return null;
        return (await this.getAllDisplays())[r.index] ?? null;
    },
};
export const desktopCapturer = {
    /**
     * 화면/창 소스 열거 (Electron `desktopCapturer.getSources`). types 기본
     * 둘 다. ⚠️ Electron 과 달리 thumbnail/appIcon 미포함 — Screen Recording
     * TCC 권한 + base64 IPC 한도 때문(소스 열거만, 썸네일은 후속).
     */
    async getSources(opts = {}) {
        const types = (opts.types ?? ["screen", "window"]).join(",");
        const r = await coreCall({
            cmd: "desktop_capturer_get_sources", types,
        });
        return r.sources;
    },
    /**
     * 소스(`getSources()` 의 `id` — "screen:N:0"/"window:N:0") 썸네일을 PNG 로
     * `path` 에 캡처(파일경로 — base64 IPC 한도 우회, capture_page 동형).
     * ⚠️ Screen Recording TCC 권한 필요 — 미부여 시 `false`(정직 경계).
     */
    async captureThumbnail(sourceId, path) {
        const r = await coreCall({
            cmd: "desktop_capturer_capture_thumbnail", sourceId, path,
        });
        return r.success === true;
    },
};
export const crashReporter = {
    /** Runtime state 등록. 첫 프로세스 Crashpad enable은 suji.json app.crashReporter 필요. */
    async start(options = {}) {
        const r = await coreCall({ cmd: "crash_reporter_start", ...options });
        return r.success === true;
    },
    async getParameters() {
        const r = await coreCall({ cmd: "crash_reporter_get_parameters" });
        return r.parameters ?? {};
    },
    async addExtraParameter(key, value) {
        const r = await coreCall({ cmd: "crash_reporter_add_extra_parameter", key, value });
        return r.success === true;
    },
    async removeExtraParameter(key) {
        const r = await coreCall({ cmd: "crash_reporter_remove_extra_parameter", key });
        return r.success === true;
    },
    async getUploadToServer() {
        const r = await coreCall({ cmd: "crash_reporter_get_upload_to_server" });
        return r.uploadToServer === true;
    },
    async setUploadToServer(uploadToServer) {
        const r = await coreCall({ cmd: "crash_reporter_set_upload_to_server", uploadToServer });
        return r.success === true;
    },
    async getUploadedReports() {
        const r = await coreCall({ cmd: "crash_reporter_get_uploaded_reports" });
        return r.reports ?? [];
    },
    async getLastCrashReport() {
        const r = await coreCall({ cmd: "crash_reporter_get_last_crash_report" });
        return r.report ?? null;
    },
};
async function resolveAutoUpdaterManifest(input) {
    if (typeof input !== "string")
        return input;
    const res = await fetch(input);
    if (!res.ok)
        throw new Error(`autoUpdater manifest request failed: ${res.status}`);
    return (await res.json());
}
export const autoUpdater = {
    /** manifest 객체 또는 manifest URL을 확인해 새 버전 여부를 반환. */
    async checkForUpdates(input, options = {}) {
        const manifest = await resolveAutoUpdaterManifest(input);
        const currentVersion = options.currentVersion ?? (await app.getVersion());
        return coreCall({
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
    async verifyFile(path, sha256) {
        return coreCall({
            cmd: "auto_updater_verify_file",
            path,
            sha256,
        });
    },
    /** artifact URL 또는 manifest 객체를 지정 경로로 다운로드하고 optional SHA-256을 검증. */
    async downloadArtifact(input, path, options = {}) {
        const url = typeof input === "string" ? input : input.url;
        const sha256 = options.sha256 ?? (typeof input === "string" ? "" : input.sha256 ?? "");
        return coreCall({
            cmd: "auto_updater_download_artifact",
            url,
            path,
            sha256,
        });
    },
    /** artifact 포맷(.zip/.dmg/.app/.AppImage/.deb)을 quitAndInstall 또는 system package handoff 입력으로 정규화. */
    async prepareInstall(input, options = {}) {
        const path = typeof input === "string" ? input : input.path;
        const sha256 = options.sha256 ?? (typeof input === "string" ? "" : input.sha256 ?? "");
        return coreCall({
            cmd: "auto_updater_prepare_install",
            path,
            target: options.target ?? "",
            stageDir: options.stageDir ?? "",
            format: options.format ?? "auto",
            sha256,
        });
    },
    /** staged artifact를 앱 종료 후 target으로 교체하고 quit을 요청. */
    async quitAndInstall(input, options = {}) {
        const path = typeof input === "string" ? input : input.path;
        const sha256 = options.sha256 ?? (typeof input === "string" ? "" : "sha256" in input ? input.sha256 ?? "" : "");
        const target = options.target ?? (typeof input === "string" ? "" : "target" in input ? input.target ?? "" : "");
        return coreCall({
            cmd: "auto_updater_quit_and_install",
            path,
            target,
            sha256,
            relaunch: options.relaunch ?? true,
            helperPath: options.helperPath ?? "",
        });
    },
};
export const powerSaveBlocker = {
    /** sleep 차단 시작. 반환된 id로 stop. 0이면 실패. */
    async start(type) {
        const r = await coreCall({ cmd: "power_save_blocker_start", type });
        return r.id;
    },
    /** start로 받은 id를 해제. unknown id는 false. */
    async stop(id) {
        const r = await coreCall({ cmd: "power_save_blocker_stop", id });
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
    async setItem(service, account, value) {
        const r = await coreCall({
            cmd: "safe_storage_set",
            service,
            account,
            value,
        });
        return r.success === true;
    },
    /** service+account로 저장된 value read. 없으면 빈 문자열. */
    async getItem(service, account) {
        const r = await coreCall({
            cmd: "safe_storage_get",
            service,
            account,
        });
        return r.value;
    },
    /** service+account 삭제. 존재하지 않아도 true (idempotent). */
    async deleteItem(service, account) {
        const r = await coreCall({
            cmd: "safe_storage_delete",
            service,
            account,
        });
        return r.success === true;
    },
};
export const app = {
    /** suji.json `app.name` 반환 (Electron `app.getName`). */
    async getName() {
        const r = await coreCall({ cmd: "app_get_name" });
        return r.name;
    },
    /** suji.json `app.version` 반환 (Electron `app.getVersion`). */
    async getVersion() {
        const r = await coreCall({ cmd: "app_get_version" });
        return r.version;
    },
    /** 앱 init 완료 여부 (V8 binding이 호출 가능한 시점은 항상 true). Electron 동등. */
    async isReady() {
        const r = await coreCall({ cmd: "app_is_ready" });
        return r.ready === true;
    },
    /** `.app` 번들로 실행 중인지 (Electron `app.isPackaged`). dev mode (raw binary)에선 false. */
    async isPackaged() {
        const r = await coreCall({ cmd: "app_is_packaged" });
        return r.packaged === true;
    },
    /** 메인 번들 경로 (Electron `app.getAppPath`). dev mode에선 binary가 위치한 디렉토리. */
    async getAppPath() {
        const r = await coreCall({ cmd: "app_get_app_path" });
        return r.path ?? "";
    },
    /** 시스템 locale BCP 47 형식 (e.g. "en-US", "ko-KR"). Electron `app.getLocale()`. */
    async getLocale() {
        const r = await coreCall({ cmd: "app_get_locale" });
        return r.locale;
    },
    /** Electron `app.setBadgeCount(count)` 동등. 0 이하면 배지 제거. */
    async setBadgeCount(count) {
        const r = await coreCall({ cmd: "app_set_badge_count", count });
        return r.success === true;
    },
    /** Electron `app.getBadgeCount()` 동등. */
    async getBadgeCount() {
        const r = await coreCall({ cmd: "app_get_badge_count" });
        return r.count ?? 0;
    },
    /** dock 진행률 표시. progress<0=hide, 0~1=ratio, >1=100%로 clamp.
     *  Electron `BrowserWindow.setProgressBar` 동등 (macOS는 NSApp.dockTile 공유). */
    async setProgressBar(progress) {
        const r = await coreCall({ cmd: "app_set_progress_bar", progress });
        return r.success === true;
    },
    /** 앱 강제 종료 (Electron `app.exit(code)`). exit code는 무시 (cef.quit 경유). */
    async exit() {
        const r = await coreCall({ cmd: "app_exit" });
        return r.success === true;
    },
    /**
     * Electron `app.requestSingleInstanceLock()` — 이 프로세스를 primary 로 만들고
     * true 반환. 다른 인스턴스가 이미 락을 보유 중이면 false (앱은 보통 quit).
     * 이미 보유 중이면 멱등적으로 true. macOS/Linux=userData flock, Windows=named mutex.
     */
    async requestSingleInstanceLock() {
        const r = await coreCall({ cmd: "app_request_single_instance_lock" });
        return r.locked === true;
    },
    /** Electron `app.hasSingleInstanceLock()` — 이 프로세스가 락 보유 중인지. */
    async hasSingleInstanceLock() {
        const r = await coreCall({ cmd: "app_has_single_instance_lock" });
        return r.locked === true;
    },
    /** Electron `app.releaseSingleInstanceLock()` — 보유 락 해제(없으면 no-op). */
    async releaseSingleInstanceLock() {
        const r = await coreCall({ cmd: "app_release_single_instance_lock" });
        return r.success === true;
    },
    /** 앱을 frontmost로 (NSApp `activateIgnoringOtherApps:`). */
    async focus() {
        const r = await coreCall({ cmd: "app_focus" });
        return r.success === true;
    },
    /** 모든 윈도우 hide (macOS Cmd+H 동등). */
    async hide() {
        const r = await coreCall({ cmd: "app_hide" });
        return r.success === true;
    },
    /** Electron `app.getPath` 동등. 표준 디렉토리 경로 반환. unknown 키는 빈 문자열. */
    async getPath(name) {
        const r = await coreCall({ cmd: "app_get_path", name });
        return r.path;
    },
    /** dock 아이콘 바운스 시작. 0이면 no-op (앱이 이미 active). 아니면 cancel용 id. */
    async requestUserAttention(critical = true) {
        const r = await coreCall({ cmd: "app_attention_request", critical });
        return r.id;
    },
    /** requestUserAttention으로 받은 id 취소. id == 0은 false (guard). */
    async cancelUserAttentionRequest(id) {
        const r = await coreCall({ cmd: "app_attention_cancel", id });
        return r.success === true;
    },
    /**
     * Security-scoped bookmark 생성 (App Sandbox 영속 파일 접근). 실패 시 null.
     * 비-sandbox 빌드에선 일반 bookmark 로 동작 (sandbox escapement no-op).
     */
    async createSecurityScopedBookmark(path) {
        const r = await coreCall({ cmd: "security_scoped_bookmark_create", path });
        return r.success === true ? r.bookmark ?? null : null;
    },
    /** bookmark 해소 + 접근 시작. 실패 시 null. id 를 stop 에 전달. */
    async startAccessingSecurityScopedResource(bookmark) {
        const r = await coreCall({
            cmd: "security_scoped_access_start",
            bookmark,
        });
        return r.success === true ? { id: r.id, path: r.path, stale: r.stale } : null;
    },
    /** 접근 종료. 유효하지 않은 id 는 false. */
    async stopAccessingSecurityScopedResource(id) {
        const r = await coreCall({ cmd: "security_scoped_access_stop", id });
        return r.success === true;
    },
    dock: {
        /** dock 배지 텍스트 — 빈 문자열로 제거. macOS만. */
        async setBadge(text) {
            await coreCall({ cmd: "dock_set_badge", text });
        },
        /** 현재 배지 텍스트. 미설정이면 빈 문자열. */
        async getBadge() {
            const r = await coreCall({ cmd: "dock_get_badge" });
            return r.text;
        },
    },
};
/**
 * 여러 백엔드에 동시 요청
 */
export async function fanout(backends, channel, data) {
    const request = JSON.stringify({ cmd: channel, ...data });
    return getBridge().fanout(backends.join(","), request);
}
/**
 * 체인 호출 (A → Core → B)
 */
export async function chain(from, to, channel, data) {
    const request = JSON.stringify({ cmd: channel, ...data });
    return getBridge().chain(from, to, request);
}
