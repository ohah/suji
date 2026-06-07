//! # Suji Rust SDK
//!
//! ```rust
//! use suji::prelude::*;
//!
//! #[suji::handle]
//! fn ping() -> String { "pong".to_string() }
//!
//! #[suji::handle]
//! fn greet(name: String) -> String { format!("Hello, {}!", name) }
//!
//! suji::export_handlers!(ping, greet);
//! ```

// `#[suji::handle]` 매크로가 `::suji::InvokeEvent::from_request(...)` 경로를 확장한다.
// crate 내부 (테스트 포함)에서도 그 경로를 유효하게 하려면 self를 `suji`라는 이름으로 노출.
extern crate self as suji;

pub use serde;
pub use serde_json;
pub use suji_macros::command as handle;

/// `specta` crate re-export — Rust 타입 → TypeScript 변환을 위한 derive macro 제공.
/// 사용자는 `#[derive(suji::Type)]`로 req/res struct에 attach 후 `specta::ts::export::<T>()`로
/// ts 시그니처 emit. SujiHandlers declaration manual 작성 (`@suji/api` interface
/// augmentation)에 그대로 사용.
///
/// `typescript` cargo feature 가 켜져 있어야 함 — specta 2.0.0-rc.25 가 unstable
/// Rust feature `debug_closure_helpers` 를 쓰므로 stable Rust 빌드에선 default
/// off. TypeScript 생성이 필요한 사용자만 `--features typescript` 로 opt-in (이때
/// nightly Rust 또는 RUSTC_BOOTSTRAP=1 + #![feature(...)] 패치 필요 — specta-rs
/// 안정화 머지까지 임시).
///
/// ```ignore
/// use suji::{specta, Type};
///
/// #[derive(Type, serde::Serialize, serde::Deserialize)]
/// pub struct GreetReq { pub name: String }
/// #[derive(Type, serde::Serialize, serde::Deserialize)]
/// pub struct GreetRes { pub greeting: String }
/// ```
#[cfg(feature = "typescript")]
pub use specta::{self, Type};

/// TypeScript declaration helpers for Rust backends.
///
/// Rust cannot be inspected by `suji types` at runtime without user-authored type metadata, so
/// this module turns explicit `#[derive(suji::Type)]` request/response types into the same
/// `SujiHandlers` module augmentation used by the frontend and Node SDKs.
///
/// `typescript` cargo feature 가 켜져 있어야 컴파일 — 위 `specta` re-export 참조.
///
/// ```ignore
/// use serde::{Deserialize, Serialize};
/// use suji::{specta, Type, typescript::SujiHandlers};
///
/// #[derive(Type, Serialize, Deserialize)]
/// struct GreetReq {
///     name: String,
/// }
///
/// #[derive(Type, Serialize, Deserialize)]
/// struct GreetRes {
///     greeting: String,
/// }
///
/// let dts = SujiHandlers::new()
///     .handler::<GreetReq, GreetRes>("greet")
///     .export()
///     .unwrap();
///
/// assert!(dts.contains("declare module '@suji/api'"));
/// ```
#[cfg(feature = "typescript")]
pub mod typescript {
    use std::{any::TypeId, borrow::Cow};

    pub use specta_typescript::{Error, Typescript};

    use specta::datatype::DataType;
    use specta_typescript::Exporter;

    const DEFAULT_MODULE: &str = "@suji/api";

    #[derive(Debug, Clone)]
    enum HandlerType {
        Void,
        Specta(DataType),
    }

    #[derive(Debug, Clone)]
    struct Handler {
        channel: String,
        req: HandlerType,
        res: HandlerType,
    }

    /// Builder for `declare module '@suji/api' { interface SujiHandlers { ... } }`.
    ///
    /// Register each backend command with its Rust request/response types, then call
    /// [`export`](Self::export). `()` is rendered as `void`; named `#[derive(suji::Type)]`
    /// structs/enums are emitted as normal TypeScript aliases and referenced from the handler.
    #[derive(Debug, Clone, Default)]
    pub struct SujiHandlers {
        types: specta::Types,
        handlers: Vec<Handler>,
    }

    impl SujiHandlers {
        pub fn new() -> Self {
            Self::default()
        }

        /// Register one command channel with its request and response types.
        pub fn handler<Req, Res>(mut self, channel: impl Into<String>) -> Self
        where
            Req: specta::Type + 'static,
            Res: specta::Type + 'static,
        {
            self.add_handler::<Req, Res>(channel);
            self
        }

        /// Mutable form of [`handler`](Self::handler) for code generators.
        pub fn add_handler<Req, Res>(&mut self, channel: impl Into<String>) -> &mut Self
        where
            Req: specta::Type + 'static,
            Res: specta::Type + 'static,
        {
            let req = handler_type::<Req>(&mut self.types);
            let res = handler_type::<Res>(&mut self.types);
            self.handlers.push(Handler {
                channel: channel.into(),
                req,
                res,
            });
            self
        }

        /// Export declarations for the frontend package module (`@suji/api`).
        pub fn export(self) -> Result<String, Error> {
            self.export_for(DEFAULT_MODULE)
        }

        /// Export declarations for a specific module, for example `@suji/node`.
        pub fn export_for(self, module_name: impl Into<String>) -> Result<String, Error> {
            let handlers = self.handlers;
            let module_name = module_name.into();
            let exporter: Exporter = Typescript::default().into();
            let exporter = exporter.framework_runtime(move |ctx| {
                let mut out = String::new();
                out.push_str("declare module '");
                out.push_str(&escape_single_quoted(&module_name));
                out.push_str("' {\n  interface SujiHandlers {\n");
                for handler in &handlers {
                    let req = render_handler_type(&ctx, &handler.req)?;
                    let res = render_handler_type(&ctx, &handler.res)?;
                    out.push_str("    ");
                    out.push_str(&ts_property_key(&handler.channel));
                    out.push_str(": { req: ");
                    out.push_str(&req);
                    out.push_str("; res: ");
                    out.push_str(&res);
                    out.push_str(" };\n");
                }
                out.push_str("  }\n}\n");
                Ok(Cow::Owned(out))
            });

            Typescript::from(exporter)
                .header("// auto-generated - do not edit\n")
                .export(&self.types, specta_serde::Format)
        }
    }

    fn handler_type<T>(types: &mut specta::Types) -> HandlerType
    where
        T: specta::Type + 'static,
    {
        if TypeId::of::<T>() == TypeId::of::<()>() {
            HandlerType::Void
        } else {
            HandlerType::Specta(T::definition(types))
        }
    }

    fn render_handler_type(
        ctx: &specta_typescript::FrameworkExporter<'_>,
        ty: &HandlerType,
    ) -> Result<String, Error> {
        match ty {
            HandlerType::Void => Ok("void".to_string()),
            HandlerType::Specta(DataType::Reference(reference)) => ctx.reference(reference),
            HandlerType::Specta(dt) => ctx.inline(dt),
        }
    }

    fn ts_property_key(channel: &str) -> String {
        if is_ts_identifier(channel) {
            channel.to_string()
        } else {
            serde_json::to_string(channel).expect("serializing TS property key")
        }
    }

    fn is_ts_identifier(s: &str) -> bool {
        let mut chars = s.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        if !(first == '_' || first == '$' || first.is_ascii_alphabetic()) {
            return false;
        }
        chars.all(|c| c == '_' || c == '$' || c.is_ascii_alphanumeric())
    }

    fn escape_single_quoted(s: &str) -> String {
        s.replace('\\', "\\\\").replace('\'', "\\'")
    }
}

/// IPC 요청의 sender 창 컨텍스트 — Electron의 `event.sender`/`BrowserWindow.fromWebContents` 대응.
///
/// 2-arity 핸들러 `fn(..., event: InvokeEvent)`의 두 번째 파라미터로 받는다.
/// 파싱 실패/누락 시 id=0, name=None.
///
/// ```ignore
/// #[suji::handle]
/// fn save(filename: String, event: suji::InvokeEvent) -> serde_json::Value {
///     if event.window.name.as_deref() == Some("settings") { /* ... */ }
///     serde_json::json!({ "ok": true, "from": event.window.id })
/// }
/// ```
#[derive(Debug, Clone, Default)]
pub struct InvokeEvent {
    pub window: Window,
}

#[derive(Debug, Clone, Default)]
pub struct Window {
    pub id: u32,
    pub name: Option<String>,
    /// sender 창의 main frame URL (Electron `event.sender.url` 대응).
    /// wire 레벨 `__window_url`에서 파생. 로드 전/빈 페이지면 None.
    pub url: Option<String>,
    /// sender frame이 페이지의 main frame인지 (false면 iframe 내부 호출).
    /// wire의 `__window_main_frame`에서 파생.
    pub is_main_frame: Option<bool>,
}

impl InvokeEvent {
    /// wire의 `__window` / `__window_name` / `__window_url` / `__window_main_frame` 필드에서 파생.
    /// #[doc(hidden)] 루트 request JSON Value를 받아 구성 — proc macro가 자동 호출.
    #[doc(hidden)]
    pub fn from_request(parsed: &serde_json::Value) -> Self {
        let id = parsed
            .get("__window")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32)
            .unwrap_or(0);
        let name = parsed
            .get("__window_name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let url = parsed
            .get("__window_url")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let is_main_frame = parsed.get("__window_main_frame").and_then(|v| v.as_bool());
        Self {
            window: Window {
                id,
                name,
                url,
                is_main_frame,
            },
        }
    }
}

#[repr(C)]
pub struct SujiWindowApi {
    pub request_json: extern "C" fn(*const std::os::raw::c_char) -> *const std::os::raw::c_char,
    pub free_response: extern "C" fn(*const std::os::raw::c_char),
}

#[repr(C)]
pub struct SujiCore {
    pub invoke: extern "C" fn(
        *const std::os::raw::c_char,
        *const std::os::raw::c_char,
    ) -> *const std::os::raw::c_char,
    pub free: extern "C" fn(*const std::os::raw::c_char),
    pub emit: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char),
    pub on: extern "C" fn(
        *const std::os::raw::c_char,
        Option<
            extern "C" fn(
                *const std::os::raw::c_char,
                *const std::os::raw::c_char,
                *mut std::os::raw::c_void,
            ),
        >,
        *mut std::os::raw::c_void,
    ) -> u64,
    pub off: extern "C" fn(u64),
    pub register: extern "C" fn(*const std::os::raw::c_char),
    /// Zig plugin 전용. Rust plugin은 `std::sync`/`std::fs` 사용 권장.
    pub get_io: extern "C" fn() -> *const std::os::raw::c_void,
    /// 앱 종료 요청 (Electron `app.quit()` 호환). 메인 프로세스가 종료 함수를 주입.
    pub quit: extern "C" fn(),
    /// 플랫폼 이름 — "macos" | "linux" | "windows" | "other".
    pub platform: extern "C" fn() -> *const std::os::raw::c_char,
    /// 특정 창(WindowManager id)에만 이벤트 전달 (Electron `webContents.send`).
    pub emit_to: extern "C" fn(u32, *const std::os::raw::c_char, *const std::os::raw::c_char),
    /// WindowManager 전용 API table. 없으면 null 포인터 반환.
    pub get_window_api: extern "C" fn() -> *const SujiWindowApi,
}

unsafe impl Send for SujiCore {}
unsafe impl Sync for SujiCore {}

/// 코어 포인터 — `backend_init` 호출마다 replace. OnceLock으로는 테스트 격리에서
/// reg1 deinit 후 reg2의 backend_init이 silently set 실패해 stale 포인터로 use-after-free
/// crash (Linux GP exception). AtomicPtr는 항상 최신 포인터로 atomic store.
#[doc(hidden)]
pub static __SUJI_CORE: std::sync::atomic::AtomicPtr<SujiCore> =
    std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());

#[doc(hidden)]
#[inline]
pub fn __get_core() -> Option<&'static SujiCore> {
    let p = __SUJI_CORE.load(std::sync::atomic::Ordering::Acquire);
    if p.is_null() {
        None
    } else {
        Some(unsafe { &*p })
    }
}

pub fn invoke(backend: &str, request: &str) -> Option<String> {
    let core = __get_core()?;
    let c_name = std::ffi::CString::new(backend).ok()?;
    let c_req = std::ffi::CString::new(request).ok()?;
    let resp = (core.invoke)(c_name.as_ptr(), c_req.as_ptr());
    if resp.is_null() {
        return None;
    }
    Some(
        unsafe { std::ffi::CStr::from_ptr(resp) }
            .to_str()
            .ok()?
            .to_string(),
    )
}

pub fn send(channel: &str, data: &str) {
    if let Some(core) = __get_core() {
        let c_ch = std::ffi::CString::new(channel).unwrap_or_default();
        let c_data = std::ffi::CString::new(data).unwrap_or_default();
        (core.emit)(c_ch.as_ptr(), c_data.as_ptr());
    }
}

/// 특정 창(window id)에만 이벤트 전달 (Electron `webContents.send`).
/// 대상 창이 닫혔거나 core가 주입 전이면 silent no-op.
pub fn send_to(window_id: u32, channel: &str, data: &str) {
    if let Some(core) = __get_core() {
        let c_ch = std::ffi::CString::new(channel).unwrap_or_default();
        let c_data = std::ffi::CString::new(data).unwrap_or_default();
        (core.emit_to)(window_id, c_ch.as_ptr(), c_data.as_ptr());
    }
}

/// 이벤트 수신 (Electron: ipcMain.on)
/// 리스너 ID를 반환 (off로 해제 가능)
pub fn on(
    channel: &str,
    callback: extern "C" fn(
        *const std::os::raw::c_char,
        *const std::os::raw::c_char,
        *mut std::os::raw::c_void,
    ),
    arg: *mut std::os::raw::c_void,
) -> u64 {
    if let Some(core) = __get_core() {
        let c_ch = std::ffi::CString::new(channel).unwrap_or_default();
        (core.on)(c_ch.as_ptr(), Some(callback), arg)
    } else {
        0
    }
}

/// 리스너 해제
pub fn off(listener_id: u64) {
    if let Some(core) = __get_core() {
        (core.off)(listener_id);
    }
}

/// 앱 종료 요청 (Electron `app.quit()` 호환).
/// 주로 `on("window:all-closed", ...)` 핸들러에서 플랫폼 확인 후 호출.
/// core 주입 전이면 silent no-op.
pub fn quit() {
    if let Some(core) = __get_core() {
        (core.quit)();
    }
}

// ============================================
// windows API — Phase 4-A 백엔드 SDK
// dlopen 환경에선 in-process 코어 접근 불가 → 모두 invoke("__core__", ...) 경유.
// Frontend `@suji/api` windows.* 와 동일한 cmd JSON 형식.
// ============================================

pub mod windows {
    use super::{escape_json_full, invoke};

    /// 새 창 생성. `opts_json`은 cmd 객체 안에 들어갈 필드 (예: `r#""title":"x","frame":false"#`).
    /// caller가 JSON-safe 보장. 단순 경우는 `create_simple()` 사용.
    pub fn create(opts_json: &str) -> Option<String> {
        let req = if opts_json.is_empty() {
            r#"{"cmd":"create_window"}"#.to_string()
        } else {
            format!(r#"{{"cmd":"create_window",{}}}"#, opts_json)
        };
        invoke("__core__", &req)
    }

    /// 단축: title + url만으로 익명 창 생성.
    pub fn create_simple(title: &str, url: &str) -> Option<String> {
        let opts = format!(
            r#""title":"{}","url":"{}""#,
            escape_json(title),
            escape_json(url),
        );
        create(&opts)
    }

    pub fn load_url(window_id: u32, url: &str) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"load_url","windowId":{},"url":"{}"}}"#,
            window_id,
            escape_json(url),
        );
        invoke("__core__", &req)
    }

    pub fn reload(window_id: u32, ignore_cache: bool) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"reload","windowId":{},"ignoreCache":{}}}"#,
            window_id, ignore_cache,
        );
        invoke("__core__", &req)
    }

    /// 렌더러에 임의 JS 실행. fire-and-forget — 결과 회신 없음.
    pub fn execute_javascript(window_id: u32, code: &str) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"execute_javascript","windowId":{},"code":"{}"}}"#,
            window_id,
            escape_json(code),
        );
        invoke("__core__", &req)
    }

    pub fn get_url(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"get_url","windowId":{}}}"#, window_id),
        )
    }

    /// UA 동적 변경 (Electron `webContents.setUserAgent`, CDP override).
    pub fn set_user_agent(window_id: u32, user_agent: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_user_agent","windowId":{},"userAgent":"{}"}}"#,
                window_id,
                escape_json(user_agent),
            ),
        )
    }

    /// 설정한 UA override 조회. 미설정 시 응답 userAgent=null.
    pub fn get_user_agent(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"get_user_agent","windowId":{}}}"#, window_id),
        )
    }

    pub fn is_loading(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"is_loading","windowId":{}}}"#, window_id),
        )
    }

    pub fn open_dev_tools(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"open_dev_tools","windowId":{}}}"#, window_id),
        )
    }
    pub fn close_dev_tools(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"close_dev_tools","windowId":{}}}"#, window_id),
        )
    }
    pub fn is_dev_tools_opened(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"is_dev_tools_opened","windowId":{}}}"#,
                window_id
            ),
        )
    }
    pub fn toggle_dev_tools(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"toggle_dev_tools","windowId":{}}}"#, window_id),
        )
    }

    pub fn set_zoom_level(window_id: u32, level: f64) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_zoom_level","windowId":{},"level":{}}}"#,
                window_id, level
            ),
        )
    }
    pub fn get_zoom_level(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"get_zoom_level","windowId":{}}}"#, window_id),
        )
    }
    pub fn set_zoom_factor(window_id: u32, factor: f64) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_zoom_factor","windowId":{},"factor":{}}}"#,
                window_id, factor
            ),
        )
    }
    pub fn get_zoom_factor(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"get_zoom_factor","windowId":{}}}"#, window_id),
        )
    }

    /// 창 오디오 mute (Electron `webContents.setAudioMuted`). raw JSON: windowOp.
    pub fn set_audio_muted(window_id: u32, muted: bool) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_audio_muted","windowId":{},"muted":{}}}"#,
                window_id, muted
            ),
        )
    }

    /// 창 오디오 mute 상태. raw JSON: `{"muted":bool,"ok":bool}`.
    pub fn is_audio_muted(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"is_audio_muted","windowId":{}}}"#, window_id),
        )
    }

    /// 창 알파값 (0~1). Electron `BrowserWindow.setOpacity`. raw JSON: windowOp.
    pub fn set_opacity(window_id: u32, opacity: f64) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_opacity","windowId":{},"opacity":{}}}"#,
                window_id, opacity
            ),
        )
    }

    /// raw JSON: `{"opacity":f64,"ok":bool}`.
    pub fn get_opacity(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"get_opacity","windowId":{}}}"#, window_id),
        )
    }

    /// 배경색 (`#RRGGBB` 또는 `#RRGGBBAA`). raw JSON: windowOp.
    pub fn set_background_color(window_id: u32, color: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_background_color","windowId":{},"color":"{}"}}"#,
                window_id,
                escape_json_full(color)
            ),
        )
    }

    /// 그림자 표시 여부. raw JSON: windowOp.
    pub fn set_has_shadow(window_id: u32, has: bool) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_has_shadow","windowId":{},"hasShadow":{}}}"#,
                window_id, has
            ),
        )
    }

    /// raw JSON: `{"hasShadow":bool,"ok":bool}`.
    pub fn has_shadow(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"has_shadow","windowId":{}}}"#, window_id),
        )
    }

    pub fn undo(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"undo","windowId":{}}}"#, window_id),
        )
    }
    pub fn redo(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"redo","windowId":{}}}"#, window_id),
        )
    }
    pub fn cut(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"cut","windowId":{}}}"#, window_id),
        )
    }
    pub fn copy(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"copy","windowId":{}}}"#, window_id),
        )
    }
    pub fn paste(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"paste","windowId":{}}}"#, window_id),
        )
    }
    pub fn select_all(window_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"select_all","windowId":{}}}"#, window_id),
        )
    }

    #[derive(Default, Clone, Copy)]
    pub struct FindOptions {
        pub forward: bool,
        pub match_case: bool,
        pub find_next: bool,
    }

    pub fn find_in_page(window_id: u32, text: &str, opts: FindOptions) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"find_in_page","windowId":{},"text":"{}","forward":{},"matchCase":{},"findNext":{}}}"#,
                window_id,
                escape_json(text),
                opts.forward,
                opts.match_case,
                opts.find_next,
            ),
        )
    }

    pub fn stop_find_in_page(window_id: u32, clear_selection: bool) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"stop_find_in_page","windowId":{},"clearSelection":{}}}"#,
                window_id, clear_selection,
            ),
        )
    }

    /// PDF 인쇄. 코어가 CDP 완료까지 응답 보류 → 응답 JSON 에 `success` 직접 포함
    /// (예: `{"from":"zig-core","cmd":"print_to_pdf","path":"...","success":true}`).
    /// EventBus emit `window:pdf-print-finished` 도 동시 발화(다른 구독자 호환).
    pub fn print_to_pdf(window_id: u32, path: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"print_to_pdf","windowId":{},"path":"{}"}}"#,
                window_id,
                escape_json(path),
            ),
        )
    }

    /// 페이지 스크린샷 PNG 저장 (Electron `webContents.capturePage`, CDP
    /// Page.captureScreenshot). 코어 deferred response — 응답 JSON 에 `success`
    /// 직접 포함. EventBus emit `window:page-captured` 도 동시 발화.
    pub fn capture_page(window_id: u32, path: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"capture_page","windowId":{},"path":"{}"}}"#,
                window_id,
                escape_json(path),
            ),
        )
    }

    /// 부분 영역 스크린샷 (Electron `webContents.capturePage(rect)`). CSS px.
    /// Rust 는 기본인자 없음 → capture_page 와 별도 fn(무회귀).
    pub fn capture_page_rect(
        window_id: u32,
        path: &str,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    ) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"capture_page","windowId":{},"path":"{}","clipX":{},"clipY":{},"clipWidth":{},"clipHeight":{}}}"#,
                window_id,
                escape_json(path),
                x as i64,
                y as i64,
                width as i64,
                height as i64,
            ),
        )
    }

    pub fn set_title(window_id: u32, title: &str) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"set_title","windowId":{},"title":"{}"}}"#,
            window_id,
            escape_json(title),
        );
        invoke("__core__", &req)
    }

    #[derive(Default, Clone, Copy)]
    pub struct SetBoundsArgs {
        pub x: i32,
        pub y: i32,
        pub width: u32,
        pub height: u32,
    }

    pub fn set_bounds(window_id: u32, b: SetBoundsArgs) -> Option<String> {
        let req = format!(
            r#"{{"cmd":"set_bounds","windowId":{},"x":{},"y":{},"width":{},"height":{}}}"#,
            window_id, b.x, b.y, b.width, b.height,
        );
        invoke("__core__", &req)
    }

    // ── Electron BrowserWindow 생명주기/상태 (JS @suji/api 패리티) ──
    // 대부분 `{"cmd":"X","windowId":N}` 동형 → window_op 로 DRY. 응답은 raw JSON.
    fn window_op_request(cmd: &str, window_id: u32) -> String {
        format!(r#"{{"cmd":"{}","windowId":{}}}"#, cmd, window_id)
    }
    fn set_visible_request(window_id: u32, visible: bool) -> String {
        format!(r#"{{"cmd":"set_visible","windowId":{},"visible":{}}}"#, window_id, visible)
    }
    fn set_fullscreen_request(window_id: u32, flag: bool) -> String {
        format!(r#"{{"cmd":"set_fullscreen","windowId":{},"flag":{}}}"#, window_id, flag)
    }
    fn set_always_on_top_request(window_id: u32, on_top: bool) -> String {
        format!(r#"{{"cmd":"set_always_on_top","windowId":{},"onTop":{}}}"#, window_id, on_top)
    }

    pub fn minimize(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("minimize", window_id))
    }
    pub fn maximize(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("maximize", window_id))
    }
    pub fn unmaximize(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("unmaximize", window_id))
    }
    pub fn restore(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("restore_window", window_id))
    }
    pub fn close(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("destroy_window", window_id))
    }
    /// 강제 파괴 (Electron `BrowserWindow.destroy`) — `window:close`(취소 hook) 스킵, `window:closed` 만.
    pub fn destroy(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("destroy_window_force", window_id))
    }
    pub fn show(window_id: u32) -> Option<String> {
        invoke("__core__", &set_visible_request(window_id, true))
    }
    pub fn hide(window_id: u32) -> Option<String> {
        invoke("__core__", &set_visible_request(window_id, false))
    }
    pub fn set_fullscreen(window_id: u32, flag: bool) -> Option<String> {
        invoke("__core__", &set_fullscreen_request(window_id, flag))
    }
    pub fn is_minimized(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("is_minimized", window_id))
    }
    pub fn is_maximized(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("is_maximized", window_id))
    }
    pub fn is_fullscreen(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("is_fullscreen", window_id))
    }
    pub fn is_normal(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("is_normal", window_id))
    }
    pub fn focus(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("focus", window_id))
    }
    pub fn blur(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("blur", window_id))
    }
    pub fn is_focused(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("is_focused", window_id))
    }
    pub fn is_visible(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("is_visible", window_id))
    }
    pub fn get_bounds(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("get_bounds", window_id))
    }
    /// 콘텐츠 영역(프레임/타이틀바 제외) raw JSON. `{"x","y","width","height","ok"}`.
    pub fn get_content_bounds(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("get_content_bounds", window_id))
    }
    /// 콘텐츠 영역을 지정 사각형으로 (Electron `setContentBounds`).
    pub fn set_content_bounds(window_id: u32, b: SetBoundsArgs) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"set_content_bounds","windowId":{},"x":{},"y":{},"width":{},"height":{}}}"#,
                window_id, b.x, b.y, b.width, b.height,
            ),
        )
    }
    pub fn set_always_on_top(window_id: u32, on_top: bool) -> Option<String> {
        invoke("__core__", &set_always_on_top_request(window_id, on_top))
    }
    pub fn is_always_on_top(window_id: u32) -> Option<String> {
        invoke("__core__", &window_op_request("is_always_on_top", window_id))
    }
    pub fn get_all_windows() -> Option<String> {
        invoke("__core__", r#"{"cmd":"get_all_windows"}"#)
    }
    pub fn get_focused_window() -> Option<String> {
        invoke("__core__", r#"{"cmd":"get_focused_window"}"#)
    }

    #[derive(Default, Clone, Copy)]
    pub struct ViewBoundsArgs {
        pub x: i32,
        pub y: i32,
        pub width: u32,
        pub height: u32,
    }

    pub struct CreateViewOptions<'a> {
        pub host_id: u32,
        pub name: Option<&'a str>,
        pub url: Option<&'a str>,
        pub bounds: ViewBoundsArgs,
    }

    impl<'a> CreateViewOptions<'a> {
        pub fn new(host_id: u32) -> Self {
            Self {
                host_id,
                name: None,
                url: None,
                bounds: ViewBoundsArgs::default(),
            }
        }
    }

    pub fn create_view(opts: CreateViewOptions<'_>) -> Option<String> {
        invoke("__core__", &create_view_request(opts))
    }

    pub fn destroy_view(view_id: u32) -> Option<String> {
        invoke("__core__", &destroy_view_request(view_id))
    }

    pub fn add_child_view(host_id: u32, view_id: u32, index: Option<usize>) -> Option<String> {
        invoke("__core__", &add_child_view_request(host_id, view_id, index))
    }

    pub fn remove_child_view(host_id: u32, view_id: u32) -> Option<String> {
        invoke("__core__", &remove_child_view_request(host_id, view_id))
    }

    pub fn set_top_view(host_id: u32, view_id: u32) -> Option<String> {
        invoke("__core__", &set_top_view_request(host_id, view_id))
    }

    pub fn set_view_bounds(view_id: u32, b: ViewBoundsArgs) -> Option<String> {
        invoke("__core__", &set_view_bounds_request(view_id, b))
    }

    pub fn set_view_visible(view_id: u32, visible: bool) -> Option<String> {
        invoke("__core__", &set_view_visible_request(view_id, visible))
    }

    pub fn get_child_views(host_id: u32) -> Option<String> {
        invoke("__core__", &get_child_views_request(host_id))
    }

    fn create_view_request(opts: CreateViewOptions<'_>) -> String {
        let mut req = format!(r#"{{"cmd":"create_view","hostId":{}"#, opts.host_id);
        if let Some(name) = opts.name {
            req.push_str(&format!(r#","name":"{}""#, escape_json(name)));
        }
        if let Some(url) = opts.url {
            req.push_str(&format!(r#","url":"{}""#, escape_json(url)));
        }
        req.push_str(&format!(
            r#","x":{},"y":{},"width":{},"height":{}}}"#,
            opts.bounds.x, opts.bounds.y, opts.bounds.width, opts.bounds.height,
        ));
        req
    }

    fn add_child_view_request(host_id: u32, view_id: u32, index: Option<usize>) -> String {
        let mut req = format!(
            r#"{{"cmd":"add_child_view","hostId":{},"viewId":{}"#,
            host_id, view_id
        );
        if let Some(i) = index {
            req.push_str(&format!(r#","index":{}"#, i));
        }
        req.push('}');
        req
    }

    fn destroy_view_request(view_id: u32) -> String {
        format!(r#"{{"cmd":"destroy_view","viewId":{}}}"#, view_id)
    }

    fn remove_child_view_request(host_id: u32, view_id: u32) -> String {
        format!(
            r#"{{"cmd":"remove_child_view","hostId":{},"viewId":{}}}"#,
            host_id, view_id
        )
    }

    fn set_top_view_request(host_id: u32, view_id: u32) -> String {
        format!(
            r#"{{"cmd":"set_top_view","hostId":{},"viewId":{}}}"#,
            host_id, view_id
        )
    }

    fn set_view_bounds_request(view_id: u32, b: ViewBoundsArgs) -> String {
        format!(
            r#"{{"cmd":"set_view_bounds","viewId":{},"x":{},"y":{},"width":{},"height":{}}}"#,
            view_id, b.x, b.y, b.width, b.height,
        )
    }

    fn set_view_visible_request(view_id: u32, visible: bool) -> String {
        format!(
            r#"{{"cmd":"set_view_visible","viewId":{},"visible":{}}}"#,
            view_id, visible
        )
    }

    fn get_child_views_request(host_id: u32) -> String {
        format!(r#"{{"cmd":"get_child_views","hostId":{}}}"#, host_id)
    }

    /// JSON 문자열 escape — `"` `\\` 이스케이프 + control char drop.
    fn escape_json(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        for ch in s.chars() {
            match ch {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                c if (c as u32) < 0x20 => continue,
                c => out.push(c),
            }
        }
        out
    }

    /// create 응답 JSON 에서 windowId 추출 (순수 — 테스트 가능).
    pub(super) fn parse_window_id(resp: &str) -> Option<u32> {
        let v: crate::serde_json::Value = crate::serde_json::from_str(resp).ok()?;
        Some(v.get("windowId")?.as_u64()? as u32)
    }

    /// `windows::*`(raw window_id)의 객체지향 facade (Electron `BrowserWindow`
    /// 패리티, @suji/api 와 동형). 각 메서드는 `<fn>(self.id, ...)` 위임 —
    /// 로직 무중복, windows 변경에 자동 동기화.
    pub struct BrowserWindow {
        id: u32,
    }

    impl BrowserWindow {
        /// 새 창 생성 후 인스턴스 반환. 코어 미연결/파싱 실패 시 None.
        pub fn create(opts_json: &str) -> Option<BrowserWindow> {
            let resp = create(opts_json)?;
            Some(BrowserWindow {
                id: parse_window_id(&resp)?,
            })
        }
        /// 기존 window_id(메인 창/이벤트 sender)를 인스턴스로 래핑.
        pub fn from_id(id: u32) -> BrowserWindow {
            BrowserWindow { id }
        }
        pub fn id(&self) -> u32 {
            self.id
        }

        pub fn load_url(&self, url: &str) -> Option<String> {
            load_url(self.id, url)
        }
        pub fn reload(&self, ignore_cache: bool) -> Option<String> {
            reload(self.id, ignore_cache)
        }
        pub fn execute_javascript(&self, code: &str) -> Option<String> {
            execute_javascript(self.id, code)
        }
        pub fn get_url(&self) -> Option<String> {
            get_url(self.id)
        }
        pub fn set_user_agent(&self, user_agent: &str) -> Option<String> {
            set_user_agent(self.id, user_agent)
        }
        pub fn get_user_agent(&self) -> Option<String> {
            get_user_agent(self.id)
        }
        pub fn is_loading(&self) -> Option<String> {
            is_loading(self.id)
        }
        pub fn open_dev_tools(&self) -> Option<String> {
            open_dev_tools(self.id)
        }
        pub fn close_dev_tools(&self) -> Option<String> {
            close_dev_tools(self.id)
        }
        pub fn is_dev_tools_opened(&self) -> Option<String> {
            is_dev_tools_opened(self.id)
        }
        pub fn toggle_dev_tools(&self) -> Option<String> {
            toggle_dev_tools(self.id)
        }
        pub fn set_zoom_level(&self, level: f64) -> Option<String> {
            set_zoom_level(self.id, level)
        }
        pub fn get_zoom_level(&self) -> Option<String> {
            get_zoom_level(self.id)
        }
        pub fn set_zoom_factor(&self, factor: f64) -> Option<String> {
            set_zoom_factor(self.id, factor)
        }
        pub fn get_zoom_factor(&self) -> Option<String> {
            get_zoom_factor(self.id)
        }
        pub fn set_audio_muted(&self, muted: bool) -> Option<String> {
            set_audio_muted(self.id, muted)
        }
        pub fn is_audio_muted(&self) -> Option<String> {
            is_audio_muted(self.id)
        }
        pub fn set_opacity(&self, opacity: f64) -> Option<String> {
            set_opacity(self.id, opacity)
        }
        pub fn get_opacity(&self) -> Option<String> {
            get_opacity(self.id)
        }
        pub fn set_background_color(&self, color: &str) -> Option<String> {
            set_background_color(self.id, color)
        }
        pub fn set_has_shadow(&self, has: bool) -> Option<String> {
            set_has_shadow(self.id, has)
        }
        pub fn has_shadow(&self) -> Option<String> {
            has_shadow(self.id)
        }
        pub fn undo(&self) -> Option<String> {
            undo(self.id)
        }
        pub fn redo(&self) -> Option<String> {
            redo(self.id)
        }
        pub fn cut(&self) -> Option<String> {
            cut(self.id)
        }
        pub fn copy(&self) -> Option<String> {
            copy(self.id)
        }
        pub fn paste(&self) -> Option<String> {
            paste(self.id)
        }
        pub fn select_all(&self) -> Option<String> {
            select_all(self.id)
        }
        pub fn find_in_page(&self, text: &str, opts: FindOptions) -> Option<String> {
            find_in_page(self.id, text, opts)
        }
        pub fn stop_find_in_page(&self, clear_selection: bool) -> Option<String> {
            stop_find_in_page(self.id, clear_selection)
        }
        pub fn print_to_pdf(&self, path: &str) -> Option<String> {
            print_to_pdf(self.id, path)
        }
        pub fn capture_page(&self, path: &str) -> Option<String> {
            capture_page(self.id, path)
        }
        pub fn capture_page_rect(
            &self,
            path: &str,
            x: f64,
            y: f64,
            width: f64,
            height: f64,
        ) -> Option<String> {
            capture_page_rect(self.id, path, x, y, width, height)
        }
        pub fn set_title(&self, title: &str) -> Option<String> {
            set_title(self.id, title)
        }
        pub fn set_bounds(&self, b: SetBoundsArgs) -> Option<String> {
            set_bounds(self.id, b)
        }
        // Electron BrowserWindow 생명주기/상태 (JS @suji/api 패리티).
        pub fn minimize(&self) -> Option<String> {
            minimize(self.id)
        }
        pub fn maximize(&self) -> Option<String> {
            maximize(self.id)
        }
        pub fn unmaximize(&self) -> Option<String> {
            unmaximize(self.id)
        }
        pub fn restore(&self) -> Option<String> {
            restore(self.id)
        }
        pub fn close(&self) -> Option<String> {
            close(self.id)
        }
        /// 강제 파괴 (Electron `BrowserWindow.destroy`) — `window:close` 스킵, `window:closed` 만.
        pub fn destroy(&self) -> Option<String> {
            destroy(self.id)
        }
        pub fn show(&self) -> Option<String> {
            show(self.id)
        }
        pub fn hide(&self) -> Option<String> {
            hide(self.id)
        }
        pub fn set_fullscreen(&self, flag: bool) -> Option<String> {
            set_fullscreen(self.id, flag)
        }
        pub fn is_minimized(&self) -> Option<String> {
            is_minimized(self.id)
        }
        pub fn is_maximized(&self) -> Option<String> {
            is_maximized(self.id)
        }
        pub fn is_fullscreen(&self) -> Option<String> {
            is_fullscreen(self.id)
        }
        pub fn is_normal(&self) -> Option<String> {
            is_normal(self.id)
        }
        pub fn focus(&self) -> Option<String> {
            focus(self.id)
        }
        pub fn blur(&self) -> Option<String> {
            blur(self.id)
        }
        pub fn is_focused(&self) -> Option<String> {
            is_focused(self.id)
        }
        pub fn is_visible(&self) -> Option<String> {
            is_visible(self.id)
        }
        pub fn get_bounds(&self) -> Option<String> {
            get_bounds(self.id)
        }
        pub fn get_content_bounds(&self) -> Option<String> {
            get_content_bounds(self.id)
        }
        pub fn set_content_bounds(&self, b: SetBoundsArgs) -> Option<String> {
            set_content_bounds(self.id, b)
        }
        pub fn set_always_on_top(&self, on_top: bool) -> Option<String> {
            set_always_on_top(self.id, on_top)
        }
        pub fn is_always_on_top(&self) -> Option<String> {
            is_always_on_top(self.id)
        }
        pub fn create_view(&self, mut opts: CreateViewOptions<'_>) -> Option<String> {
            opts.host_id = self.id;
            create_view(opts)
        }
        pub fn destroy_view(&self, view_id: u32) -> Option<String> {
            destroy_view(view_id)
        }
        pub fn add_child_view(&self, view_id: u32, index: Option<usize>) -> Option<String> {
            add_child_view(self.id, view_id, index)
        }
        pub fn remove_child_view(&self, view_id: u32) -> Option<String> {
            remove_child_view(self.id, view_id)
        }
        pub fn set_top_view(&self, view_id: u32) -> Option<String> {
            set_top_view(self.id, view_id)
        }
        pub fn set_view_bounds(&self, view_id: u32, b: ViewBoundsArgs) -> Option<String> {
            set_view_bounds(view_id, b)
        }
        pub fn set_view_visible(&self, view_id: u32, visible: bool) -> Option<String> {
            set_view_visible(view_id, visible)
        }
        pub fn get_child_views(&self) -> Option<String> {
            get_child_views(self.id)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::{
            add_child_view_request, create_view_request, destroy_view_request, escape_json,
            get_child_views_request, parse_window_id, remove_child_view_request,
            set_always_on_top_request, set_fullscreen_request, set_top_view_request,
            set_view_bounds_request, set_view_visible_request, set_visible_request, window_op_request,
            BrowserWindow, CreateViewOptions, ViewBoundsArgs,
        };

        #[test]
        fn window_state_request_shapes() {
            assert_eq!(window_op_request("minimize", 3), r#"{"cmd":"minimize","windowId":3}"#);
            assert_eq!(window_op_request("is_visible", 7), r#"{"cmd":"is_visible","windowId":7}"#);
            assert_eq!(window_op_request("get_bounds", 1), r#"{"cmd":"get_bounds","windowId":1}"#);
            // 리네임 트랩 cmd 문서/가드 — restore→restore_window, close→destroy_window (Go 테스트 대칭).
            assert_eq!(window_op_request("restore_window", 2), r#"{"cmd":"restore_window","windowId":2}"#);
            assert_eq!(window_op_request("destroy_window", 2), r#"{"cmd":"destroy_window","windowId":2}"#);
            assert_eq!(window_op_request("destroy_window_force", 2), r#"{"cmd":"destroy_window_force","windowId":2}"#);
            assert_eq!(set_visible_request(2, true), r#"{"cmd":"set_visible","windowId":2,"visible":true}"#);
            assert_eq!(set_visible_request(2, false), r#"{"cmd":"set_visible","windowId":2,"visible":false}"#);
            assert_eq!(set_fullscreen_request(4, true), r#"{"cmd":"set_fullscreen","windowId":4,"flag":true}"#);
            assert_eq!(set_always_on_top_request(5, true), r#"{"cmd":"set_always_on_top","windowId":5,"onTop":true}"#);
        }

        #[test]
        fn parse_window_id_extracts() {
            assert_eq!(parse_window_id(r#"{"windowId":7}"#), Some(7));
            assert_eq!(
                parse_window_id(r#"{"from":"x","windowId":42,"ok":true}"#),
                Some(42)
            );
            assert_eq!(parse_window_id(r#"{"no":1}"#), None);
            assert_eq!(parse_window_id("not json"), None);
        }

        #[test]
        fn from_id_roundtrip() {
            assert_eq!(BrowserWindow::from_id(5).id(), 5);
        }

        #[test]
        fn escape_quote_and_backslash() {
            assert_eq!(escape_json("a\"b\\c"), "a\\\"b\\\\c");
        }

        #[test]
        fn drop_control_chars() {
            assert_eq!(escape_json("a\nb\tc"), "abc");
        }

        #[test]
        fn passthrough_normal() {
            assert_eq!(escape_json("hello world!"), "hello world!");
        }

        #[test]
        fn create_view_request_builds_core_json() {
            let req = create_view_request(CreateViewOptions {
                host_id: 7,
                name: Some("side\"bar"),
                url: Some("https://example.com/a"),
                bounds: ViewBoundsArgs {
                    x: 10,
                    y: 20,
                    width: 300,
                    height: 400,
                },
            });
            assert_eq!(
                req,
                r#"{"cmd":"create_view","hostId":7,"name":"side\"bar","url":"https://example.com/a","x":10,"y":20,"width":300,"height":400}"#
            );
        }

        #[test]
        fn add_child_view_request_omits_or_includes_index() {
            assert_eq!(
                add_child_view_request(1, 2, None),
                r#"{"cmd":"add_child_view","hostId":1,"viewId":2}"#
            );
            assert_eq!(
                add_child_view_request(1, 2, Some(0)),
                r#"{"cmd":"add_child_view","hostId":1,"viewId":2,"index":0}"#
            );
        }

        #[test]
        fn view_operation_requests_build_core_json() {
            assert_eq!(
                destroy_view_request(2),
                r#"{"cmd":"destroy_view","viewId":2}"#
            );
            assert_eq!(
                remove_child_view_request(1, 2),
                r#"{"cmd":"remove_child_view","hostId":1,"viewId":2}"#
            );
            assert_eq!(
                set_top_view_request(1, 2),
                r#"{"cmd":"set_top_view","hostId":1,"viewId":2}"#
            );
            assert_eq!(
                set_view_bounds_request(
                    2,
                    ViewBoundsArgs {
                        x: 1,
                        y: 2,
                        width: 3,
                        height: 4,
                    }
                ),
                r#"{"cmd":"set_view_bounds","viewId":2,"x":1,"y":2,"width":3,"height":4}"#
            );
            assert_eq!(
                set_view_visible_request(2, false),
                r#"{"cmd":"set_view_visible","viewId":2,"visible":false}"#
            );
            assert_eq!(
                get_child_views_request(1),
                r#"{"cmd":"get_child_views","hostId":1}"#
            );
        }
    }
}

// ============================================
// clipboard / shell / dialog — frontend `@suji/api`와 동일 cmd 사용.
// 응답은 raw JSON String — caller가 serde_json::from_str로 파싱.
// ============================================

/// Full JSON escape — `\n`/`\t`/`\r`은 escape sequence로 보존 (windows::escape_json은
/// drop 처리). 클립보드 / dialog 메시지처럼 줄바꿈/탭 의미가 있는 payload용.
fn escape_json_full(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\x08' => out.push_str("\\b"),
            '\x0c' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

pub mod clipboard {
    use crate::{escape_json_full, invoke};

    /// 시스템 클립보드 plain text 읽기. 응답 JSON: `{"from","cmd","text":"..."}`.
    pub fn read_text() -> Option<String> {
        invoke("__core__", r#"{"cmd":"clipboard_read_text"}"#)
    }

    /// 시스템 클립보드 plain text 쓰기. 응답: `{"from","cmd","success":bool}`.
    pub fn write_text(text: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"clipboard_write_text","text":"{}"}}"#,
                escape_json_full(text)
            ),
        )
    }

    pub fn clear() -> Option<String> {
        invoke("__core__", r#"{"cmd":"clipboard_clear"}"#)
    }

    /// HTML 읽기 raw JSON. `{"html":"..."}`.
    pub fn read_html() -> Option<String> {
        invoke("__core__", r#"{"cmd":"clipboard_read_html"}"#)
    }

    /// HTML 쓰기. 응답: `{"success":bool}`.
    pub fn write_html(html: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"clipboard_write_html","html":"{}"}}"#,
                escape_json_full(html)
            ),
        )
    }

    /// RTF 읽기 (Electron `clipboard.readRTF`). raw JSON: `{"rtf":"..."}`.
    pub fn read_rtf() -> Option<String> {
        invoke("__core__", r#"{"cmd":"clipboard_read_rtf"}"#)
    }

    /// RTF 쓰기 (Electron `clipboard.writeRTF`). raw JSON: `{"success":bool}`.
    pub fn write_rtf(rtf: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"clipboard_write_rtf","rtf":"{}"}}"#,
                escape_json_full(rtf)
            ),
        )
    }

    /// 임의 UTI raw bytes 쓰기. data_b64는 base64 인코딩된 문자열.
    pub fn write_buffer(format: &str, data_b64: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"clipboard_write_buffer","format":"{}","data":"{}"}}"#,
                escape_json_full(format),
                escape_json_full(data_b64)
            ),
        )
    }

    /// 임의 UTI raw bytes 읽기. raw JSON: `{"data":"<base64>"}`.
    pub fn read_buffer(format: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"clipboard_read_buffer","format":"{}"}}"#,
                escape_json_full(format)
            ),
        )
    }

    /// format(UTI)이 클립보드에 있는지. 응답: `{"present":bool}`.
    pub fn has(format: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"clipboard_has","format":"{}"}}"#,
                escape_json_full(format)
            ),
        )
    }

    /// 클립보드 등록된 format 배열. 응답: `{"formats":[...]}`.
    pub fn available_formats() -> Option<String> {
        invoke("__core__", r#"{"cmd":"clipboard_available_formats"}"#)
    }

    /// PNG 이미지 쓰기 — base64. 응답: `{"success":bool}`.
    /// 한도: raw PNG ~8KB (1차).
    pub fn write_image(png_base64: &str) -> Option<String> {
        invoke(
            "__core__",
            &crate::serde_json::json!({ "cmd": "clipboard_write_image", "data": png_base64 }).to_string(),
        )
    }

    /// PNG 이미지 읽기 (base64). raw JSON: `{"data":"..."}`.
    pub fn read_image() -> Option<String> {
        invoke("__core__", r#"{"cmd":"clipboard_read_image"}"#)
    }

    /// TIFF 이미지 쓰기 — base64 (NSPasteboard `public.tiff`). write_image 동형.
    pub fn write_tiff(tiff_base64: &str) -> Option<String> {
        invoke(
            "__core__",
            &crate::serde_json::json!({ "cmd": "clipboard_write_tiff", "data": tiff_base64 }).to_string(),
        )
    }

    /// TIFF 이미지 읽기 (base64). raw JSON: `{"data":"..."}`.
    pub fn read_tiff() -> Option<String> {
        invoke("__core__", r#"{"cmd":"clipboard_read_tiff"}"#)
    }
}

pub mod power_monitor {
    use crate::{invoke, serde_json};

    /// 시스템 유휴 시간 raw JSON. `{"seconds":f64}`.
    pub fn get_system_idle_time() -> Option<String> {
        invoke("__core__", r#"{"cmd":"power_monitor_get_idle_time"}"#)
    }

    /// 화면 잠금이면 "locked", 유휴 시간 ≥ threshold(초)면 "idle", 아니면 "active".
    /// raw JSON: `{"state":"active"|"idle"|"locked"}`.
    pub fn get_system_idle_state(threshold: i64) -> Option<String> {
        invoke(
            "__core__",
            &serde_json::json!({ "cmd": "power_monitor_get_idle_state", "threshold": threshold }).to_string(),
        )
    }

    /// 배터리 전원 여부 raw JSON: `{"onBattery":bool}` (Electron `powerMonitor.isOnBatteryPower`).
    pub fn is_on_battery() -> Option<String> {
        invoke("__core__", r#"{"cmd":"power_monitor_is_on_battery"}"#)
    }
}

pub mod shell {
    use crate::{escape_json_full, invoke};

    pub fn open_external(url: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"shell_open_external","url":"{}"}}"#,
                escape_json_full(url)
            ),
        )
    }

    pub fn show_item_in_folder(path: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"shell_show_item_in_folder","path":"{}"}}"#,
                escape_json_full(path)
            ),
        )
    }

    pub fn beep() -> Option<String> {
        invoke("__core__", r#"{"cmd":"shell_beep"}"#)
    }

    pub(crate) fn trash_item_request(path: &str) -> String {
        crate::serde_json::json!({ "cmd": "shell_trash_item", "path": path }).to_string()
    }

    /// 휴지통으로 이동. 응답: `{"success":bool}`.
    pub fn trash_item(path: &str) -> Option<String> {
        invoke("__core__", &trash_item_request(path))
    }

    pub(crate) fn open_path_request(path: &str) -> String {
        crate::serde_json::json!({ "cmd": "shell_open_path", "path": path }).to_string()
    }

    /// 로컬 파일/폴더를 기본 앱으로 열기. 응답: `{"success":bool}`.
    pub fn open_path(path: &str) -> Option<String> {
        invoke("__core__", &open_path_request(path))
    }
}

pub mod native_image {
    use crate::{invoke, serde_json};

    /// 이미지 파일 dimensions. raw JSON: `{"width":N,"height":N}`.
    pub fn get_size(path: &str) -> Option<String> {
        invoke(
            "__core__",
            &serde_json::json!({ "cmd": "native_image_get_size", "path": path }).to_string(),
        )
    }

    /// 이미지 파일 → PNG base64. raw JSON: `{"data":"..."}` (raw ~8KB 한도).
    pub fn to_png(path: &str) -> Option<String> {
        invoke(
            "__core__",
            &serde_json::json!({ "cmd": "native_image_to_png", "path": path }).to_string(),
        )
    }

    /// 이미지 파일 → JPEG base64. quality는 0~100.
    pub fn to_jpeg(path: &str, quality: f64) -> Option<String> {
        invoke(
            "__core__",
            &serde_json::json!({ "cmd": "native_image_to_jpeg", "path": path, "quality": quality }).to_string(),
        )
    }
}

pub mod native_theme {
    use crate::{escape_json_full, invoke};

    /// 시스템 다크 모드 여부 raw JSON. `{"dark":bool}`.
    pub fn should_use_dark_colors() -> Option<String> {
        invoke("__core__", r#"{"cmd":"native_theme_should_use_dark_colors"}"#)
    }

    /// "light"|"dark"|"system" 강제. raw JSON: `{"success":bool}`.
    pub fn set_theme_source(source: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"native_theme_set_source","source":"{}"}}"#,
                escape_json_full(source)
            ),
        )
    }

    /// themeSource getter — 마지막 설정값 raw JSON: `{"source":"system"|"light"|"dark"}`.
    pub fn get_theme_source() -> Option<String> {
        invoke("__core__", r#"{"cmd":"native_theme_get_source"}"#)
    }
}

pub mod fs {
    use crate::{invoke, serde_json};

    pub(crate) fn read_file_request(path: &str) -> String {
        serde_json::json!({
            "cmd": "fs_read_file",
            "path": path,
        })
        .to_string()
    }

    pub(crate) fn write_file_request(path: &str, text: &str) -> String {
        serde_json::json!({
            "cmd": "fs_write_file",
            "path": path,
            "text": text,
        })
        .to_string()
    }

    pub(crate) fn stat_request(path: &str) -> String {
        serde_json::json!({
            "cmd": "fs_stat",
            "path": path,
        })
        .to_string()
    }

    pub(crate) fn mkdir_request(path: &str, recursive: bool) -> String {
        serde_json::json!({
            "cmd": "fs_mkdir",
            "path": path,
            "recursive": recursive,
        })
        .to_string()
    }

    pub(crate) fn readdir_request(path: &str) -> String {
        serde_json::json!({
            "cmd": "fs_readdir",
            "path": path,
        })
        .to_string()
    }

    pub(crate) fn rm_request(path: &str, recursive: bool, force: bool) -> String {
        serde_json::json!({
            "cmd": "fs_rm",
            "path": path,
            "recursive": recursive,
            "force": force,
        })
        .to_string()
    }

    /// Read UTF-8 text. Response JSON: `{"success":true,"text":"..."}`.
    pub fn read_file(path: &str) -> Option<String> {
        invoke("__core__", &read_file_request(path))
    }

    /// Write UTF-8 text, replacing the file if it exists.
    pub fn write_file(path: &str, text: &str) -> Option<String> {
        invoke("__core__", &write_file_request(path, text))
    }

    /// File metadata. Response JSON: `{"success":true,"type":"file","size":N,"mtime":N_ms}`.
    /// `mtime` is milliseconds since UTC epoch (compatible with `Date.now()`).
    pub fn stat(path: &str) -> Option<String> {
        invoke("__core__", &stat_request(path))
    }

    pub fn mkdir(path: &str, recursive: bool) -> Option<String> {
        invoke("__core__", &mkdir_request(path, recursive))
    }

    pub fn readdir(path: &str) -> Option<String> {
        invoke("__core__", &readdir_request(path))
    }

    /// Remove a path. `recursive=true` for directory tree, `force=true` to ignore not-found
    /// (Node `fs.rm({recursive,force})` semantics).
    pub fn rm(path: &str, recursive: bool, force: bool) -> Option<String> {
        invoke("__core__", &rm_request(path, recursive, force))
    }

    /// File type — fs.statTyped / fs.readdirTyped 결과 타입.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum FileType {
        File,
        Directory,
        Symlink,
        Other,
    }

    impl FileType {
        pub(crate) fn from_str(s: &str) -> Self {
            match s {
                "file" => FileType::File,
                "directory" => FileType::Directory,
                "symlink" => FileType::Symlink,
                _ => FileType::Other,
            }
        }
    }

    /// `fs.stat`의 typed 결과. mtime_ms는 epoch ms (JS `Date(mtime)`).
    #[derive(Debug, Clone)]
    pub struct Stat {
        pub r#type: FileType,
        pub size: u64,
        pub mtime_ms: i64,
    }

    /// `fs.readdir` 한 entry.
    #[derive(Debug, Clone)]
    pub struct DirEntry {
        pub name: String,
        pub r#type: FileType,
    }

    /// `stat`의 typed wrapper. 실패 시 None (path 거부 / not_found / sandbox forbidden).
    pub fn stat_typed(path: &str) -> Option<Stat> {
        let raw = stat(path)?;
        let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
        if !v.get("success")?.as_bool()? {
            return None;
        }
        Some(Stat {
            r#type: FileType::from_str(v.get("type")?.as_str()?),
            size: v.get("size")?.as_u64()?,
            mtime_ms: v.get("mtime")?.as_i64()?,
        })
    }

    /// `readdir`의 typed wrapper. 실패 시 None.
    pub fn readdir_typed(path: &str) -> Option<Vec<DirEntry>> {
        let raw = readdir(path)?;
        let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
        if !v.get("success")?.as_bool()? {
            return None;
        }
        let entries = v.get("entries")?.as_array()?;
        Some(
            entries
                .iter()
                .filter_map(|e| {
                    Some(DirEntry {
                        name: e.get("name")?.as_str()?.to_string(),
                        r#type: FileType::from_str(e.get("type")?.as_str()?),
                    })
                })
                .collect(),
        )
    }
}

pub mod notification {
    use crate::{escape_json_full, invoke};

    /// 플랫폼 지원 여부 — `{"supported":bool}` raw JSON 응답.
    pub fn is_supported() -> Option<String> {
        invoke("__core__", r#"{"cmd":"notification_is_supported"}"#)
    }

    /// 권한 요청 — `{"granted":bool}` 응답. 첫 호출 시 OS 다이얼로그.
    pub fn request_permission() -> Option<String> {
        invoke("__core__", r#"{"cmd":"notification_request_permission"}"#)
    }

    /// 알림 표시 — `{"notificationId":"...","success":bool}` 응답.
    pub fn show(title: &str, body: &str, silent: bool) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"notification_show","title":"{}","body":"{}","silent":{}}}"#,
                escape_json_full(title),
                escape_json_full(body),
                silent,
            ),
        )
    }

    pub fn close(notification_id: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"notification_close","notificationId":"{}"}}"#,
                escape_json_full(notification_id),
            ),
        )
    }

    /// 표시/대기 모든 알림 제거 raw JSON: `{"success":bool}` (Electron `Notification.removeAll`, macOS 실동작).
    pub fn remove_all() -> Option<String> {
        invoke("__core__", r#"{"cmd":"notification_remove_all"}"#)
    }
}

pub mod tray {
    use crate::{escape_json_full, invoke, serde_json};

    /// 메뉴 항목 — item/checkbox/separator/submenu.
    pub enum MenuItem<'a> {
        Item {
            label: &'a str,
            click: &'a str,
        },
        ItemWithOptions {
            label: &'a str,
            click: &'a str,
            enabled: bool,
        },
        Checkbox {
            label: &'a str,
            click: &'a str,
            checked: bool,
            enabled: bool,
        },
        Separator,
        Submenu {
            label: &'a str,
            enabled: bool,
            submenu: Vec<MenuItem<'a>>,
        },
    }

    /// 새 트레이 생성. 응답 JSON: `{"from","cmd","trayId":N}`. trayId=0이면 실패.
    pub fn create(title: &str, tooltip: &str) -> Option<String> {
        create_with_icon(title, tooltip, "")
    }

    /// macOS/Linux에서는 icon_path를 tray icon 이미지로 사용한다. Windows는 현재 기본 icon.
    pub fn create_with_icon(title: &str, tooltip: &str, icon_path: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"tray_create","title":"{}","tooltip":"{}","iconPath":"{}"}}"#,
                escape_json_full(title),
                escape_json_full(tooltip),
                escape_json_full(icon_path),
            ),
        )
    }

    pub fn set_title(tray_id: u32, title: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"tray_set_title","trayId":{},"title":"{}"}}"#,
                tray_id,
                escape_json_full(title),
            ),
        )
    }

    pub fn set_tooltip(tray_id: u32, tooltip: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"tray_set_tooltip","trayId":{},"tooltip":"{}"}}"#,
                tray_id,
                escape_json_full(tooltip),
            ),
        )
    }

    /// 메뉴 설정 — items 배열을 serde_json으로 안전하게 직렬화.
    /// 클릭 시 `tray:menu-click {trayId, click}` 이벤트 발화.
    pub fn set_menu(tray_id: u32, items: &[MenuItem]) -> Option<String> {
        let req = set_menu_request(tray_id, items);
        invoke("__core__", &req)
    }

    pub(crate) fn set_menu_request(tray_id: u32, items: &[MenuItem]) -> String {
        serde_json::json!({
            "cmd": "tray_set_menu",
            "trayId": tray_id,
            "items": items.iter().map(item_to_json).collect::<Vec<_>>(),
        })
        .to_string()
    }

    fn item_to_json(item: &MenuItem) -> serde_json::Value {
        match item {
            MenuItem::Item { label, click } => serde_json::json!({
                "label": label,
                "click": click,
            }),
            MenuItem::ItemWithOptions {
                label,
                click,
                enabled,
            } => serde_json::json!({
                "type": "item",
                "label": label,
                "click": click,
                "enabled": enabled,
            }),
            MenuItem::Checkbox {
                label,
                click,
                checked,
                enabled,
            } => serde_json::json!({
                "type": "checkbox",
                "label": label,
                "click": click,
                "checked": checked,
                "enabled": enabled,
            }),
            MenuItem::Separator => serde_json::json!({"type": "separator"}),
            MenuItem::Submenu {
                label,
                enabled,
                submenu,
            } => serde_json::json!({
                "type": "submenu",
                "label": label,
                "enabled": enabled,
                "submenu": submenu.iter().map(item_to_json).collect::<Vec<_>>(),
            }),
        }
    }

    pub fn destroy(tray_id: u32) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"tray_destroy","trayId":{}}}"#, tray_id),
        )
    }
}

pub mod menu {
    use crate::{invoke, serde_json};

    /// Application menu item — top-level entries should be Submenu.
    pub enum MenuItem<'a> {
        Item {
            label: &'a str,
            click: &'a str,
            enabled: bool,
        },
        Checkbox {
            label: &'a str,
            click: &'a str,
            checked: bool,
            enabled: bool,
        },
        Separator,
        Submenu {
            label: &'a str,
            enabled: bool,
            submenu: Vec<MenuItem<'a>>,
        },
    }

    fn item_to_json(item: &MenuItem) -> serde_json::Value {
        match item {
            MenuItem::Item {
                label,
                click,
                enabled,
            } => serde_json::json!({
                "type": "item",
                "label": label,
                "click": click,
                "enabled": enabled,
            }),
            MenuItem::Checkbox {
                label,
                click,
                checked,
                enabled,
            } => serde_json::json!({
                "type": "checkbox",
                "label": label,
                "click": click,
                "checked": checked,
                "enabled": enabled,
            }),
            MenuItem::Separator => serde_json::json!({"type": "separator"}),
            MenuItem::Submenu {
                label,
                enabled,
                submenu,
            } => serde_json::json!({
                "type": "submenu",
                "label": label,
                "enabled": enabled,
                "submenu": submenu.iter().map(item_to_json).collect::<Vec<_>>(),
            }),
        }
    }

    pub(crate) fn set_application_menu_request(items: &[MenuItem]) -> String {
        serde_json::json!({
            "cmd": "menu_set_application_menu",
            "items": items.iter().map(item_to_json).collect::<Vec<_>>(),
        })
        .to_string()
    }

    /// Set the macOS application menu. Clicks emit `menu:click {click}`.
    pub fn set_application_menu(items: &[MenuItem]) -> Option<String> {
        let req = set_application_menu_request(items);
        invoke("__core__", &req)
    }

    pub fn reset_application_menu() -> Option<String> {
        invoke("__core__", r#"{"cmd":"menu_reset_application_menu"}"#)
    }
}

/// macOS Carbon Hot Key wrapper. Accelerator syntax: `"Cmd+Shift+K"`,
/// `"CommandOrControl+P"`, `"Alt+F4"`, etc. Triggers fire on the EventBus channel
/// `globalShortcut:trigger {accelerator, click}`. macOS/Linux(X11)/Windows are supported.
pub mod global_shortcut {
    use crate::{invoke, serde_json};

    pub(crate) fn register_request(accelerator: &str, click: &str) -> String {
        serde_json::json!({
            "cmd": "global_shortcut_register",
            "accelerator": accelerator,
            "click": click,
        })
        .to_string()
    }

    pub(crate) fn unregister_request(accelerator: &str) -> String {
        serde_json::json!({
            "cmd": "global_shortcut_unregister",
            "accelerator": accelerator,
        })
        .to_string()
    }

    pub(crate) fn is_registered_request(accelerator: &str) -> String {
        serde_json::json!({
            "cmd": "global_shortcut_is_registered",
            "accelerator": accelerator,
        })
        .to_string()
    }

    pub fn register(accelerator: &str, click: &str) -> Option<String> {
        invoke("__core__", &register_request(accelerator, click))
    }

    pub fn unregister(accelerator: &str) -> Option<String> {
        invoke("__core__", &unregister_request(accelerator))
    }

    pub fn unregister_all() -> Option<String> {
        invoke("__core__", r#"{"cmd":"global_shortcut_unregister_all"}"#)
    }

    pub fn is_registered(accelerator: &str) -> Option<String> {
        invoke("__core__", &is_registered_request(accelerator))
    }
}

pub mod dialog {
    use crate::{escape_json_full, invoke, serde_json};

    /// MessageBox 옵션 — Electron 호환 필드. window_id로 sheet, 없으면 free-floating.
    /// raw fields_json 직접 넘기는 [`show_message_box_raw`]도 노출 — 정교 케이스용.
    #[derive(Default)]
    pub struct MessageBoxOpts<'a> {
        pub window_id: Option<u32>,
        pub r#type: Option<&'a str>, // "info" | "warning" | "error" | "question" | "none"
        pub title: Option<&'a str>,
        pub message: &'a str,
        pub detail: Option<&'a str>,
        pub buttons: Vec<&'a str>,
        pub default_id: Option<usize>,
        pub cancel_id: Option<usize>,
        pub checkbox_label: Option<&'a str>,
        pub checkbox_checked: bool,
    }

    pub fn show_message_box(opts: MessageBoxOpts) -> Option<String> {
        let mut req = serde_json::Map::new();
        req.insert(
            "cmd".into(),
            serde_json::Value::String("dialog_show_message_box".into()),
        );
        req.insert(
            "message".into(),
            serde_json::Value::String(opts.message.into()),
        );
        if let Some(id) = opts.window_id {
            req.insert("windowId".into(), serde_json::Value::from(id));
        }
        if let Some(t) = opts.r#type {
            req.insert("type".into(), serde_json::Value::String(t.into()));
        }
        if let Some(t) = opts.title {
            req.insert("title".into(), serde_json::Value::String(t.into()));
        }
        if let Some(d) = opts.detail {
            req.insert("detail".into(), serde_json::Value::String(d.into()));
        }
        if !opts.buttons.is_empty() {
            req.insert(
                "buttons".into(),
                serde_json::Value::Array(
                    opts.buttons
                        .iter()
                        .map(|s| serde_json::Value::String((*s).into()))
                        .collect(),
                ),
            );
        }
        if let Some(d) = opts.default_id {
            req.insert("defaultId".into(), serde_json::Value::from(d));
        }
        if let Some(c) = opts.cancel_id {
            req.insert("cancelId".into(), serde_json::Value::from(c));
        }
        if let Some(c) = opts.checkbox_label {
            req.insert("checkboxLabel".into(), serde_json::Value::String(c.into()));
        }
        if opts.checkbox_checked {
            req.insert("checkboxChecked".into(), serde_json::Value::Bool(true));
        }
        invoke("__core__", &serde_json::Value::Object(req).to_string())
    }

    /// raw JSON fields. 정교한 옵션 조합 (filters 등)이 필요할 때.
    pub fn show_message_box_raw(fields_json: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"dialog_show_message_box",{}}}"#, fields_json),
        )
    }

    pub fn show_error_box(title: &str, content: &str) -> Option<String> {
        invoke(
            "__core__",
            &format!(
                r#"{{"cmd":"dialog_show_error_box","title":"{}","content":"{}"}}"#,
                escape_json_full(title),
                escape_json_full(content),
            ),
        )
    }

    /// raw fields. 옵션은 `{"properties":["openFile"],"filters":[...]}` 등.
    pub fn show_open_dialog(fields_json: &str) -> Option<String> {
        if fields_json.is_empty() {
            return invoke("__core__", r#"{"cmd":"dialog_show_open_dialog"}"#);
        }
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"dialog_show_open_dialog",{}}}"#, fields_json),
        )
    }

    pub fn show_save_dialog(fields_json: &str) -> Option<String> {
        if fields_json.is_empty() {
            return invoke("__core__", r#"{"cmd":"dialog_show_save_dialog"}"#);
        }
        invoke(
            "__core__",
            &format!(r#"{{"cmd":"dialog_show_save_dialog",{}}}"#, fields_json),
        )
    }
}

// ============================================
// screen / power_save_blocker / safe_storage / dock / requestUserAttention
// frontend `@suji/api`와 동일 cmd로 backend 호출.
// ============================================

pub mod screen {
    use crate::invoke;

    /// 모든 모니터 정보 raw JSON. `{"displays":[{...}]}`.
    pub fn get_all_displays() -> Option<String> {
        invoke("__core__", r#"{"cmd":"screen_get_all_displays"}"#)
    }

    /// 마우스 포인터 화면 좌표 raw JSON. `{"x":..,"y":..}`.
    pub fn get_cursor_screen_point() -> Option<String> {
        invoke("__core__", r#"{"cmd":"screen_get_cursor_point"}"#)
    }

    /// (x,y)에 가장 가까운 display index raw JSON. `{"index":N}` (-1 if none).
    pub fn get_display_nearest_point(x: f64, y: f64) -> Option<String> {
        invoke("__core__", &crate::serde_json::json!({
            "cmd": "screen_get_display_nearest_point",
            "x": x,
            "y": y,
        }).to_string())
    }

    /// rect 와 겹침 면적이 최대인 display index raw JSON. `{"index":N}` (없으면 -1).
    /// 겹침 없으면 rect 중심 최근접 (Electron `screen.getDisplayMatching`, 듀얼모니터).
    pub fn get_display_matching(x: f64, y: f64, width: f64, height: f64) -> Option<String> {
        invoke("__core__", &crate::serde_json::json!({
            "cmd": "screen_get_display_matching",
            "x": x,
            "y": y,
            "width": width,
            "height": height,
        }).to_string())
    }
}

/// Electron `desktopCapturer`. 화면/창 소스 열거(썸네일 미포함 — 정직 경계).
pub mod desktop_capturer {
    use crate::{invoke, serde_json};

    pub(crate) fn get_sources_request(types: &str) -> String {
        serde_json::json!({
            "cmd": "desktop_capturer_get_sources",
            "types": types,
        })
        .to_string()
    }

    pub(crate) fn capture_thumbnail_request(source_id: &str, path: &str) -> String {
        serde_json::json!({
            "cmd": "desktop_capturer_capture_thumbnail",
            "sourceId": source_id,
            "path": path,
        })
        .to_string()
    }

    /// 소스 목록 raw JSON. types: "screen" | "window" | "screen,window".
    /// `{"sources":[{id,name,type,x,y,width,height,displayId?}]}`.
    pub fn get_sources(types: &str) -> Option<String> {
        invoke("__core__", &get_sources_request(types))
    }

    /// 소스 썸네일을 PNG 로 `path` 에 캡처(파일경로 — base64 IPC 한도 우회).
    /// raw JSON `{"success":bool}`. ⚠️ Screen Recording TCC 권한 필요 —
    /// 미부여 시 success:false(정직 경계).
    pub fn capture_thumbnail(source_id: &str, path: &str) -> Option<String> {
        invoke("__core__", &capture_thumbnail_request(source_id, path))
    }
}

pub mod web_request {
    use crate::{invoke, serde_json};

    pub(crate) fn set_blocked_urls_request(patterns: &[&str]) -> String {
        serde_json::json!({
            "cmd": "web_request_set_blocked_urls",
            "patterns": patterns,
        })
        .to_string()
    }

    pub(crate) fn set_listener_filter_request(patterns: &[&str]) -> String {
        serde_json::json!({
            "cmd": "web_request_set_listener_filter",
            "patterns": patterns,
        })
        .to_string()
    }

    pub(crate) fn resolve_request(id: u64, cancel: bool) -> String {
        serde_json::json!({
            "cmd": "web_request_resolve",
            "id": id,
            "cancel": cancel,
        })
        .to_string()
    }

    /// URL glob blocklist 등록 (Electron `session.webRequest.onBeforeRequest({urls})`).
    /// `*` wildcard만. 응답: `{"count":N}`.
    pub fn set_blocked_urls(patterns: &[&str]) -> Option<String> {
        invoke("__core__", &set_blocked_urls_request(patterns))
    }

    /// dynamic listener filter. 매칭 요청은 RV_CONTINUE_ASYNC + webRequest:will-request 이벤트.
    pub fn set_listener_filter(patterns: &[&str]) -> Option<String> {
        invoke("__core__", &set_listener_filter_request(patterns))
    }

    /// pending 요청 결정 — id는 will-request 이벤트의 id 필드.
    pub fn resolve(id: u64, cancel: bool) -> Option<String> {
        invoke("__core__", &resolve_request(id, cancel))
    }
}

pub mod crash_reporter {
    use crate::{invoke, serde_json};

    pub(crate) fn start_request(upload_to_server: bool) -> String {
        serde_json::json!({
            "cmd": "crash_reporter_start",
            "uploadToServer": upload_to_server,
        })
        .to_string()
    }

    pub(crate) fn add_extra_parameter_request(key: &str, value: &str) -> String {
        serde_json::json!({
            "cmd": "crash_reporter_add_extra_parameter",
            "key": key,
            "value": value,
        })
        .to_string()
    }

    pub(crate) fn remove_extra_parameter_request(key: &str) -> String {
        serde_json::json!({
            "cmd": "crash_reporter_remove_extra_parameter",
            "key": key,
        })
        .to_string()
    }

    /// Runtime start. 첫 프로세스 Crashpad enable은 suji.json app.crashReporter 필요.
    pub fn start(upload_to_server: bool) -> Option<String> {
        invoke("__core__", &start_request(upload_to_server))
    }

    pub fn get_parameters() -> Option<String> {
        invoke("__core__", r#"{"cmd":"crash_reporter_get_parameters"}"#)
    }

    pub fn add_extra_parameter(key: &str, value: &str) -> Option<String> {
        invoke("__core__", &add_extra_parameter_request(key, value))
    }

    pub fn remove_extra_parameter(key: &str) -> Option<String> {
        invoke("__core__", &remove_extra_parameter_request(key))
    }

    pub fn get_upload_to_server() -> Option<String> {
        invoke("__core__", r#"{"cmd":"crash_reporter_get_upload_to_server"}"#)
    }

    pub fn set_upload_to_server(upload_to_server: bool) -> Option<String> {
        invoke("__core__", &serde_json::json!({
            "cmd": "crash_reporter_set_upload_to_server",
            "uploadToServer": upload_to_server,
        }).to_string())
    }

    pub fn get_uploaded_reports() -> Option<String> {
        invoke("__core__", r#"{"cmd":"crash_reporter_get_uploaded_reports"}"#)
    }

    pub fn get_last_crash_report() -> Option<String> {
        invoke("__core__", r#"{"cmd":"crash_reporter_get_last_crash_report"}"#)
    }
}

pub mod power_save_blocker {
    use crate::{invoke, serde_json};

    pub(crate) fn start_request(type_str: &str) -> String {
        serde_json::json!({ "cmd": "power_save_blocker_start", "type": type_str }).to_string()
    }

    pub(crate) fn stop_request(id: u32) -> String {
        serde_json::json!({ "cmd": "power_save_blocker_stop", "id": id }).to_string()
    }

    /// `"prevent_app_suspension"` | `"prevent_display_sleep"`. 응답: `{"id":N}`.
    pub fn start(type_str: &str) -> Option<String> {
        invoke("__core__", &start_request(type_str))
    }

    /// 응답: `{"success":bool}`.
    pub fn stop(id: u32) -> Option<String> {
        invoke("__core__", &stop_request(id))
    }
}

pub mod safe_storage {
    use crate::{invoke, serde_json};

    pub(crate) fn set_request(service: &str, account: &str, value: &str) -> String {
        serde_json::json!({
            "cmd": "safe_storage_set",
            "service": service,
            "account": account,
            "value": value,
        })
        .to_string()
    }

    pub(crate) fn get_request(service: &str, account: &str) -> String {
        serde_json::json!({
            "cmd": "safe_storage_get",
            "service": service,
            "account": account,
        })
        .to_string()
    }

    pub(crate) fn delete_request(service: &str, account: &str) -> String {
        serde_json::json!({
            "cmd": "safe_storage_delete",
            "service": service,
            "account": account,
        })
        .to_string()
    }

    /// macOS Keychain에 utf-8 value 저장. 응답: `{"success":bool}`.
    pub fn set_item(service: &str, account: &str, value: &str) -> Option<String> {
        invoke("__core__", &set_request(service, account, value))
    }

    /// 응답: `{"value":"..."}` (없으면 빈 문자열).
    pub fn get_item(service: &str, account: &str) -> Option<String> {
        invoke("__core__", &get_request(service, account))
    }

    /// 응답: `{"success":bool}` (없는 키도 idempotent true).
    pub fn delete_item(service: &str, account: &str) -> Option<String> {
        invoke("__core__", &delete_request(service, account))
    }
}

pub mod dock {
    use crate::{invoke, serde_json};

    pub(crate) fn set_badge_request(text: &str) -> String {
        serde_json::json!({ "cmd": "dock_set_badge", "text": text }).to_string()
    }

    /// dock 배지 텍스트 (빈 문자열 = 제거). 응답: `{"success":bool}`.
    pub fn set_badge(text: &str) -> Option<String> {
        invoke("__core__", &set_badge_request(text))
    }

    /// 응답: `{"text":"..."}`.
    pub fn get_badge() -> Option<String> {
        invoke("__core__", r#"{"cmd":"dock_get_badge"}"#)
    }
}

/// Electron `session.cookies.*`. CEF cookie_manager fire-and-forget +
/// 비동기 visitor 패턴 (get).
pub mod session {
    use crate::invoke;
    use serde_json::json;

    /// `session.cookies.set` 인자 (Electron `Cookie`). expires는 unix epoch second
    /// (0 또는 미지정 → 세션 쿠키).
    #[derive(Debug, Default, Clone)]
    pub struct CookieDescriptor<'a> {
        pub url: &'a str,
        pub name: &'a str,
        pub value: &'a str,
        pub domain: &'a str,
        pub path: &'a str,
        pub secure: bool,
        pub httponly: bool,
        pub expires_unix_sec: f64,
    }

    /// 모든 cookie 삭제. 실 cleanup은 비동기.
    pub fn clear_cookies() -> Option<String> {
        invoke("__core__", r#"{"cmd":"session_clear_cookies"}"#)
    }

    /// disk store flush.
    pub fn flush_store() -> Option<String> {
        invoke("__core__", r#"{"cmd":"session_flush_store"}"#)
    }

    /// Electron `session.setProxy(config)` — Chromium "proxy" preference 설정.
    /// mode "" → "direct"(프록시 해제). proxy_rules: "host:port". raw: `{"success":bool}`.
    pub fn set_proxy(mode: &str, proxy_rules: &str, proxy_bypass_rules: &str, pac_script: &str) -> Option<String> {
        let req = json!({
            "cmd": "session_set_proxy",
            "mode": mode,
            "proxyRules": proxy_rules,
            "proxyBypassRules": proxy_bypass_rules,
            "pacScript": pac_script,
        })
        .to_string();
        invoke("__core__", &req)
    }

    /// 렌더러(웹 콘텐츠) 권한 요청 정보 — `set_permission_request_handler` 핸들러 인자.
    #[derive(Debug, Clone)]
    pub struct PermissionRequest {
        /// 응답 매칭용 CEF prompt id.
        pub permission_id: u64,
        /// 요청 origin (file:// 페이지는 빈 문자열 가능).
        pub origin: String,
        /// 요청된 권한 이름 (예: ["geolocation"]).
        pub permissions: Vec<String>,
    }

    /// Electron `session.setPermissionRequestHandler(handler)` 동등. 렌더러가 geolocation/
    /// notifications/clipboard 등 권한을 요청하면 `handler` 가 호출돼 `true`(허용)/`false`(거부)
    /// 를 반환한다. 한 번 등록(앱 수명). 정직 경계: camera/mic(getUserMedia)는 별도 CEF
    /// 경로라 미포함 — on_show_permission_prompt 권한군 대상.
    ///
    /// `session:permission-request` 이벤트를 구독해 결정 후 `session_permission_response`
    /// 로 응답한다(JS/Node SDK 와 동일 wire). 핸들러는 leak 되어 앱 수명 동안 유지.
    pub fn set_permission_request_handler<F>(handler: F)
    where
        F: Fn(PermissionRequest) -> bool + Send + Sync + 'static,
    {
        type BoxedHandler = Box<dyn Fn(PermissionRequest) -> bool + Send + Sync>;
        let boxed: Box<BoxedHandler> = Box::new(Box::new(handler));
        let arg = Box::into_raw(boxed) as *mut std::os::raw::c_void;
        crate::on("session:permission-request", permission_trampoline, arg);
        invoke(
            "__core__",
            r#"{"cmd":"session_set_permission_handler","enabled":true}"#,
        );
    }

    /// 권한 핸들러 해제(이후 CEF 기본 처리).
    pub fn clear_permission_request_handler() {
        invoke(
            "__core__",
            r#"{"cmd":"session_set_permission_handler","enabled":false}"#,
        );
    }

    extern "C" fn permission_trampoline(
        _channel: *const std::os::raw::c_char,
        data: *const std::os::raw::c_char,
        arg: *mut std::os::raw::c_void,
    ) {
        // arg = leaked Box<Box<dyn Fn>> — 빌림만(앱 수명 동안 유지).
        if arg.is_null() || data.is_null() {
            return;
        }
        let handler =
            unsafe { &*(arg as *const Box<dyn Fn(PermissionRequest) -> bool + Send + Sync>) };
        let payload = unsafe { std::ffi::CStr::from_ptr(data) }
            .to_str()
            .unwrap_or("");
        let v: serde_json::Value = serde_json::from_str(payload).unwrap_or(serde_json::Value::Null);
        let permission_id = v.get("permissionId").and_then(|x| x.as_u64()).unwrap_or(0);
        let origin = v
            .get("origin")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let permissions: Vec<String> = v
            .get("permissions")
            .and_then(|x| x.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|s| s.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        // 패닉이 FFI 경계 넘으면 UB → catch 후 deny(안전 기본).
        let granted = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            handler(PermissionRequest {
                permission_id,
                origin,
                permissions,
            })
        }))
        .unwrap_or(false);
        let resp = json!({
            "cmd": "session_permission_response",
            "permissionId": permission_id,
            "granted": granted,
        })
        .to_string();
        invoke("__core__", &resp);
    }

    /// IndexedDB/localStorage/cache 삭제 (Electron `session.clearStorageData`).
    /// origin "" → 전역 HTTP 캐시만(웹 플랫폼상 origin 없이 storage 일괄
    /// 삭제 불가). storage_types None → "all".
    pub fn clear_storage_data(origin: &str, storage_types: Option<&str>) -> Option<String> {
        let req = json!({
            "cmd": "session_clear_storage_data",
            "origin": origin,
            "storageTypes": storage_types.unwrap_or("all"),
        })
        .to_string();
        invoke("__core__", &req)
    }

    /// cookie set (Electron `session.cookies.set`).
    pub fn set_cookie(c: CookieDescriptor) -> Option<String> {
        let req = json!({
            "cmd": "session_set_cookie",
            "url": c.url,
            "name": c.name,
            "value": c.value,
            "domain": c.domain,
            "path": c.path,
            "secure": c.secure,
            "httponly": c.httponly,
            "expires": c.expires_unix_sec,
        })
        .to_string();
        invoke("__core__", &req)
    }

    /// cookie 삭제 (Electron `session.cookies.remove`).
    pub fn remove_cookies(url: &str, name: &str) -> Option<String> {
        let req = json!({
            "cmd": "session_remove_cookies",
            "url": url,
            "name": name,
        })
        .to_string();
        invoke("__core__", &req)
    }

    /// cookie 조회 — 비동기 visitor. 응답: `{success, requestId}`. 결과는
    /// `session:cookies-result` 이벤트(`{requestId, cookies:[...], truncated}`).
    pub fn get_cookies(url: &str, include_http_only: bool) -> Option<String> {
        let req = json!({
            "cmd": "session_get_cookies",
            "url": url,
            "includeHttpOnly": include_http_only,
        })
        .to_string();
        invoke("__core__", &req)
    }
}

pub(crate) fn get_path_request(name: &str) -> String {
    serde_json::json!({ "cmd": "app_get_path", "name": name }).to_string()
}

/// Electron `app.getPath` 동등. name = "home"|"appData"|"userData"|"temp"|"desktop"|"documents"|"downloads".
pub fn get_path(name: &str) -> Option<String> {
    invoke("__core__", &get_path_request(name))
}

/// suji.json `app.name` 반환. raw JSON: `{"name":"..."}`.
pub fn get_name() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_get_name"}"#)
}

/// suji.json `app.version` 반환. raw JSON: `{"version":"..."}`.
pub fn get_version() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_get_version"}"#)
}

/// 앱 init 완료 여부 raw JSON. `{"ready":bool}`.
pub fn is_ready() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_is_ready"}"#)
}

/// 시스템 locale (BCP 47) raw JSON. `{"locale":"en-US"}`.
pub fn get_locale() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_get_locale"}"#)
}

/// `.app` 번들로 실행 중인지 (Electron `app.isPackaged`). raw JSON: `{"packaged":bool}`.
pub fn is_packaged() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_is_packaged"}"#)
}

/// 메인 번들 경로 (Electron `app.getAppPath`). raw JSON: `{"path":"..."}`.
pub fn get_app_path() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_get_app_path"}"#)
}

/// dock 진행률 (NSDockTile.contentView NSProgressIndicator). progress<0=hide, 0~1=ratio.
pub fn set_progress_bar(progress: f64) -> Option<String> {
    invoke(
        "__core__",
        &serde_json::json!({ "cmd": "app_set_progress_bar", "progress": progress }).to_string(),
    )
}

pub(crate) fn set_badge_count_request(count: i64) -> String {
    serde_json::json!({ "cmd": "app_set_badge_count", "count": count }).to_string()
}

/// Electron `app.setBadgeCount(count)` 동등. 0 이하면 제거.
pub fn set_badge_count(count: i64) -> Option<String> {
    invoke("__core__", &set_badge_count_request(count))
}

/// Electron `app.getBadgeCount()` 동등. raw JSON: `{"count":N}`.
pub fn get_badge_count() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_get_badge_count"}"#)
}

/// 앱 강제 종료 (Electron `app.exit(code)`). exit code는 무시.
pub fn exit() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_exit"}"#)
}

/// Electron `app.requestSingleInstanceLock()` — primary 면 `{"locked":true}`,
/// 다른 인스턴스가 이미 보유 중이면 `{"locked":false}` (보통 앱 quit). 이미 보유
/// 중이면 멱등적으로 true. macOS/Linux=userData flock, Windows=named mutex.
pub fn request_single_instance_lock() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_request_single_instance_lock"}"#)
}

/// Electron `app.hasSingleInstanceLock()` — 이 프로세스가 락 보유 중인지. raw: `{"locked":bool}`.
pub fn has_single_instance_lock() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_has_single_instance_lock"}"#)
}

/// Electron `app.releaseSingleInstanceLock()` — 보유 락 해제. raw: `{"success":bool}`.
pub fn release_single_instance_lock() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_release_single_instance_lock"}"#)
}

/// 앱 frontmost로. raw JSON: `{"success":bool}`.
pub fn focus() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_focus"}"#)
}

/// 앱 모든 윈도우 hide (macOS Cmd+H). raw JSON: `{"success":bool}`.
pub fn hide() -> Option<String> {
    invoke("__core__", r#"{"cmd":"app_hide"}"#)
}

pub(crate) fn attention_request_json(critical: bool) -> String {
    serde_json::json!({ "cmd": "app_attention_request", "critical": critical }).to_string()
}

pub(crate) fn attention_cancel_json(id: u32) -> String {
    serde_json::json!({ "cmd": "app_attention_cancel", "id": id }).to_string()
}

/// dock 바운스 시작. 응답: `{"id":N}` (0이면 앱이 active라 no-op).
pub fn request_user_attention(critical: bool) -> Option<String> {
    invoke("__core__", &attention_request_json(critical))
}

/// 응답: `{"success":bool}`.
pub fn cancel_user_attention_request(id: u32) -> Option<String> {
    invoke("__core__", &attention_cancel_json(id))
}

pub(crate) fn scoped_bookmark_create_json(path: &str) -> String {
    serde_json::json!({ "cmd": "security_scoped_bookmark_create", "path": path }).to_string()
}

pub(crate) fn scoped_access_start_json(bookmark: &str) -> String {
    serde_json::json!({ "cmd": "security_scoped_access_start", "bookmark": bookmark }).to_string()
}

pub(crate) fn scoped_access_stop_json(id: u32) -> String {
    serde_json::json!({ "cmd": "security_scoped_access_stop", "id": id }).to_string()
}

/// Security-scoped bookmark 생성 (App Sandbox 영속 파일 접근). 응답:
/// `{"success":bool,"bookmark":"<base64>"}`. 비-sandbox 빌드에선 일반 bookmark.
pub fn create_security_scoped_bookmark(path: &str) -> Option<String> {
    invoke("__core__", &scoped_bookmark_create_json(path))
}

/// bookmark 해소 + 접근 시작. 응답: `{"success":bool,"id":N,"path":"...","stale":bool}`.
pub fn start_accessing_security_scoped_resource(bookmark: &str) -> Option<String> {
    invoke("__core__", &scoped_access_start_json(bookmark))
}

/// 응답: `{"success":bool}`. 유효하지 않은 id 는 success:false.
pub fn stop_accessing_security_scoped_resource(id: u32) -> Option<String> {
    invoke("__core__", &scoped_access_stop_json(id))
}

/// 플랫폼 이름 — `"macos"` | `"linux"` | `"windows"` | `"other"`.
/// Electron `process.platform` 대응 (단 Suji는 `"darwin"` 대신 `"macos"`).
pub fn platform() -> &'static str {
    let core = match __get_core() {
        Some(c) => c,
        None => return "unknown",
    };
    let ptr = (core.platform)();
    if ptr.is_null() {
        return "unknown";
    }
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("unknown")
}

/// 플랫폼 상수 — `platform()` 반환값과 비교할 때 사용.
/// Suji는 macOS/Linux/Windows만 지원.
pub const PLATFORM_MACOS: &str = "macos";
pub const PLATFORM_LINUX: &str = "linux";
pub const PLATFORM_WINDOWS: &str = "windows";

// ============================================
// Tests — 1 기능 1 테스트
// ============================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quit_is_noop_when_core_missing() {
        // __SUJI_CORE가 주입 전이면 silent no-op (crash 없음)
        quit();
    }

    #[test]
    fn platform_returns_unknown_when_core_missing() {
        // 주입 전 기본값
        assert_eq!(platform(), "unknown");
    }

    #[test]
    fn platform_constants_match_known_strings() {
        assert_eq!(PLATFORM_MACOS, "macos");
        assert_eq!(PLATFORM_LINUX, "linux");
        assert_eq!(PLATFORM_WINDOWS, "windows");
    }

    #[test]
    fn menu_set_application_menu_request_builds_nested_items() {
        let req = crate::menu::set_application_menu_request(&[crate::menu::MenuItem::Submenu {
            label: "Tools",
            enabled: true,
            submenu: vec![
                crate::menu::MenuItem::Item {
                    label: "Run",
                    click: "run",
                    enabled: true,
                },
                crate::menu::MenuItem::Checkbox {
                    label: "Flag",
                    click: "flag",
                    checked: true,
                    enabled: false,
                },
                crate::menu::MenuItem::Separator,
            ],
        }]);
        let v: serde_json::Value = serde_json::from_str(&req).unwrap();
        assert_eq!(v["cmd"], "menu_set_application_menu");
        assert_eq!(v["items"][0]["type"], "submenu");
        assert_eq!(v["items"][0]["label"], "Tools");
        assert_eq!(v["items"][0]["submenu"][0]["click"], "run");
        assert_eq!(v["items"][0]["submenu"][1]["checked"], true);
        assert_eq!(v["items"][0]["submenu"][1]["enabled"], false);
        assert_eq!(v["items"][0]["submenu"][2]["type"], "separator");
    }

    #[test]
    fn menu_set_application_menu_request_escapes_strings() {
        let req = crate::menu::set_application_menu_request(&[crate::menu::MenuItem::Submenu {
            label: "도구 \"Tools\"",
            enabled: true,
            submenu: vec![crate::menu::MenuItem::Item {
                label: "Run \\ now",
                click: "run\nnow",
                enabled: true,
            }],
        }]);
        let v: serde_json::Value = serde_json::from_str(&req).unwrap();
        assert_eq!(v["items"][0]["label"], "도구 \"Tools\"");
        assert_eq!(v["items"][0]["submenu"][0]["label"], "Run \\ now");
        assert_eq!(v["items"][0]["submenu"][0]["click"], "run\nnow");
    }

    #[test]
    fn tray_set_menu_request_builds_nested_items() {
        let req = crate::tray::set_menu_request(
            7,
            &[
                crate::tray::MenuItem::Item {
                    label: "Run",
                    click: "run",
                },
                crate::tray::MenuItem::Checkbox {
                    label: "Flag",
                    click: "flag",
                    checked: true,
                    enabled: false,
                },
                crate::tray::MenuItem::Submenu {
                    label: "More",
                    enabled: true,
                    submenu: vec![crate::tray::MenuItem::ItemWithOptions {
                        label: "Child",
                        click: "child",
                        enabled: true,
                    }],
                },
            ],
        );
        let v: serde_json::Value = serde_json::from_str(&req).unwrap();
        assert_eq!(v["cmd"], "tray_set_menu");
        assert_eq!(v["trayId"], 7);
        assert_eq!(v["items"][0]["click"], "run");
        assert_eq!(v["items"][1]["type"], "checkbox");
        assert_eq!(v["items"][1]["checked"], true);
        assert_eq!(v["items"][1]["enabled"], false);
        assert_eq!(v["items"][2]["type"], "submenu");
        assert_eq!(v["items"][2]["submenu"][0]["click"], "child");
    }

    #[test]
    fn fs_requests_build_valid_json() {
        let read: serde_json::Value =
            serde_json::from_str(&crate::fs::read_file_request("/tmp/a.txt")).unwrap();
        assert_eq!(read["cmd"], "fs_read_file");
        assert_eq!(read["path"], "/tmp/a.txt");

        let write: serde_json::Value =
            serde_json::from_str(&crate::fs::write_file_request("/tmp/a.txt", "hello\nworld"))
                .unwrap();
        assert_eq!(write["cmd"], "fs_write_file");
        assert_eq!(write["text"], "hello\nworld");

        let mkdir: serde_json::Value =
            serde_json::from_str(&crate::fs::mkdir_request("/tmp/dir", true)).unwrap();
        assert_eq!(mkdir["cmd"], "fs_mkdir");
        assert_eq!(mkdir["recursive"], true);

        let rm: serde_json::Value =
            serde_json::from_str(&crate::fs::rm_request("/tmp/x", true, false)).unwrap();
        assert_eq!(rm["cmd"], "fs_rm");
        assert_eq!(rm["recursive"], true);
        assert_eq!(rm["force"], false);
    }

    #[test]
    fn fs_file_type_from_str_maps_known_kinds() {
        assert_eq!(crate::fs::FileType::from_str("file"), crate::fs::FileType::File);
        assert_eq!(crate::fs::FileType::from_str("directory"), crate::fs::FileType::Directory);
        assert_eq!(crate::fs::FileType::from_str("symlink"), crate::fs::FileType::Symlink);
        assert_eq!(crate::fs::FileType::from_str("socket"), crate::fs::FileType::Other);
        assert_eq!(crate::fs::FileType::from_str("unknown"), crate::fs::FileType::Other);
    }

    #[test]
    fn global_shortcut_requests_build_valid_json() {
        let reg: serde_json::Value =
            serde_json::from_str(&crate::global_shortcut::register_request("Cmd+Shift+K", "openSettings"))
                .unwrap();
        assert_eq!(reg["cmd"], "global_shortcut_register");
        assert_eq!(reg["accelerator"], "Cmd+Shift+K");
        assert_eq!(reg["click"], "openSettings");

        let unreg: serde_json::Value =
            serde_json::from_str(&crate::global_shortcut::unregister_request("Cmd+Q")).unwrap();
        assert_eq!(unreg["cmd"], "global_shortcut_unregister");
        assert_eq!(unreg["accelerator"], "Cmd+Q");

        let is_reg: serde_json::Value =
            serde_json::from_str(&crate::global_shortcut::is_registered_request("Alt+F4")).unwrap();
        assert_eq!(is_reg["cmd"], "global_shortcut_is_registered");
        assert_eq!(is_reg["accelerator"], "Alt+F4");
    }

    #[test]
    fn global_shortcut_register_escapes_special_chars() {
        // 한글 + " + \ + control char 모두 wire에서 round-trip되어야 함.
        let req = crate::global_shortcut::register_request(r#"Cmd+"한글""#, "click\nwith\\ctrl");
        let parsed: serde_json::Value = serde_json::from_str(&req).unwrap();
        assert_eq!(parsed["accelerator"], r#"Cmd+"한글""#);
        assert_eq!(parsed["click"], "click\nwith\\ctrl");
    }

    #[test]
    fn fs_requests_escape_strings() {
        let stat: serde_json::Value =
            serde_json::from_str(&crate::fs::stat_request("/tmp/한글 \"a\"")).unwrap();
        assert_eq!(stat["cmd"], "fs_stat");
        assert_eq!(stat["path"], "/tmp/한글 \"a\"");

        let readdir: serde_json::Value =
            serde_json::from_str(&crate::fs::readdir_request("/tmp/a\\b")).unwrap();
        assert_eq!(readdir["cmd"], "fs_readdir");
        assert_eq!(readdir["path"], "/tmp/a\\b");
    }

    #[test]
    fn off_is_noop_on_invalid_id() {
        // id=0 등 존재하지 않는 listener off — crash 없음
        off(0);
        off(99999);
    }

    #[test]
    fn send_and_send_to_are_noop_when_core_missing() {
        // __SUJI_CORE 없을 때 crash 없음
        send("test", "{}");
        send_to(5, "test", "{}");
    }

    #[test]
    fn invoke_event_from_request_parses_window_fields() {
        let v = serde_json::json!({
            "cmd": "save",
            "__window": 7u32,
            "__window_name": "settings",
        });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 7);
        assert_eq!(ev.window.name.as_deref(), Some("settings"));
    }

    #[test]
    fn invoke_event_defaults_when_fields_missing() {
        let v = serde_json::json!({ "cmd": "ping" });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 0);
        assert!(ev.window.name.is_none());
    }

    #[test]
    fn invoke_event_parses_url_field() {
        let v = serde_json::json!({
            "__window": 2,
            "__window_name": "main",
            "__window_url": "http://localhost:5173/",
        });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 2);
        assert_eq!(ev.window.name.as_deref(), Some("main"));
        assert_eq!(ev.window.url.as_deref(), Some("http://localhost:5173/"));
    }

    #[test]
    fn invoke_event_url_is_none_when_missing() {
        let ev = InvokeEvent::from_request(&serde_json::json!({ "__window": 3 }));
        assert!(ev.window.url.is_none());
    }

    #[test]
    fn invoke_event_parses_main_frame_field() {
        let ev_main = InvokeEvent::from_request(&serde_json::json!({
            "__window": 1, "__window_main_frame": true,
        }));
        assert_eq!(ev_main.window.is_main_frame, Some(true));

        let ev_iframe = InvokeEvent::from_request(&serde_json::json!({
            "__window": 1, "__window_main_frame": false,
        }));
        assert_eq!(ev_iframe.window.is_main_frame, Some(false));

        let ev_none = InvokeEvent::from_request(&serde_json::json!({ "__window": 1 }));
        assert!(ev_none.window.is_main_frame.is_none());
    }

    #[test]
    fn invoke_event_defaults_when_types_wrong() {
        // 음수/문자열 __window, 숫자 __window_name — 전부 default로 안전 폴백.
        let v = serde_json::json!({
            "__window": "not-a-number",
            "__window_name": 42,
        });
        let ev = InvokeEvent::from_request(&v);
        assert_eq!(ev.window.id, 0);
        assert!(ev.window.name.is_none());
    }

    // proc macro 통합 테스트 — 매크로가 확장한 함수가 기대한 대로 동작하는지 검증.
    // 일반 필드 추출 경로 / InvokeEvent 자동 파생 경로 / 두 파라미터 혼합 경로.

    #[suji::handle]
    #[allow(dead_code)]
    fn greet_test(name: String) -> String {
        format!("hi {name}")
    }

    #[suji::handle]
    #[allow(dead_code)]
    fn whoami_test(event: suji::InvokeEvent) -> serde_json::Value {
        serde_json::json!({
            "id": event.window.id,
            "name": event.window.name,
        })
    }

    #[suji::handle]
    #[allow(dead_code)]
    fn save_test(text: String, event: suji::InvokeEvent) -> serde_json::Value {
        serde_json::json!({
            "text": text,
            "from_window": event.window.id,
        })
    }

    #[test]
    fn handle_macro_extracts_named_fields() {
        let req = serde_json::json!({ "name": "kim" });
        let resp = greet_test(req);
        assert_eq!(resp, serde_json::json!("hi kim"));
    }

    #[test]
    fn handle_macro_auto_injects_invoke_event() {
        let req = serde_json::json!({
            "__window": 3,
            "__window_name": "settings",
        });
        let resp = whoami_test(req);
        assert_eq!(resp, serde_json::json!({ "id": 3, "name": "settings" }));
    }

    #[test]
    fn handle_macro_mixes_fields_and_invoke_event() {
        let req = serde_json::json!({
            "text": "hi",
            "__window": 9,
        });
        let resp = save_test(req);
        assert_eq!(resp, serde_json::json!({ "text": "hi", "from_window": 9 }));
    }

    #[test]
    fn handle_macro_fills_defaults_for_missing_fields() {
        // name 필드 없음 → String::default()인 ""
        // __window 없음 → 0, name=None → json에서 null
        let resp_greet = greet_test(serde_json::json!({}));
        assert_eq!(resp_greet, serde_json::json!("hi "));

        let resp_who = whoami_test(serde_json::json!({}));
        assert_eq!(resp_who, serde_json::json!({ "id": 0, "name": null }));
    }

    #[test]
    fn web_request_set_blocked_urls_carries_patterns() {
        let v: serde_json::Value = serde_json::from_str(
            &crate::web_request::set_blocked_urls_request(&["https://*.example.com/*"]),
        )
        .unwrap();
        assert_eq!(v["cmd"], "web_request_set_blocked_urls");
        assert_eq!(v["patterns"][0], "https://*.example.com/*");
    }

    #[test]
    fn app_get_path_request_carries_name() {
        let v: serde_json::Value =
            serde_json::from_str(&crate::get_path_request("userData")).unwrap();
        assert_eq!(v["cmd"], "app_get_path");
        assert_eq!(v["name"], "userData");
    }

    #[test]
    fn shell_trash_item_request_carries_path() {
        let v: serde_json::Value =
            serde_json::from_str(&crate::shell::trash_item_request("/tmp/x")).unwrap();
        assert_eq!(v["cmd"], "shell_trash_item");
        assert_eq!(v["path"], "/tmp/x");
    }

    #[test]
    fn power_save_blocker_requests_build_valid_json() {
        let v: serde_json::Value =
            serde_json::from_str(&crate::power_save_blocker::start_request("prevent_display_sleep"))
                .unwrap();
        assert_eq!(v["cmd"], "power_save_blocker_start");
        assert_eq!(v["type"], "prevent_display_sleep");

        let s: serde_json::Value =
            serde_json::from_str(&crate::power_save_blocker::stop_request(7)).unwrap();
        assert_eq!(s["cmd"], "power_save_blocker_stop");
        assert_eq!(s["id"], 7);
    }

    #[test]
    fn desktop_capturer_requests_build_valid_json_with_escape() {
        let sources: serde_json::Value = serde_json::from_str(
            &crate::desktop_capturer::get_sources_request("screen,window"),
        )
        .unwrap();
        assert_eq!(sources["cmd"], "desktop_capturer_get_sources");
        assert_eq!(sources["types"], "screen,window");

        let capture: serde_json::Value = serde_json::from_str(
            &crate::desktop_capturer::capture_thumbnail_request("screen:1:0", "/tmp/a\"b\\c.png"),
        )
        .unwrap();
        assert_eq!(capture["cmd"], "desktop_capturer_capture_thumbnail");
        assert_eq!(capture["sourceId"], "screen:1:0");
        assert_eq!(capture["path"], "/tmp/a\"b\\c.png");
    }

    #[test]
    fn crash_reporter_requests_build_valid_json() {
        let start: serde_json::Value =
            serde_json::from_str(&crate::crash_reporter::start_request(false)).unwrap();
        assert_eq!(start["cmd"], "crash_reporter_start");
        assert_eq!(start["uploadToServer"], false);

        let add: serde_json::Value =
            serde_json::from_str(&crate::crash_reporter::add_extra_parameter_request("suite", "rs"))
                .unwrap();
        assert_eq!(add["cmd"], "crash_reporter_add_extra_parameter");
        assert_eq!(add["key"], "suite");
        assert_eq!(add["value"], "rs");

        let remove: serde_json::Value =
            serde_json::from_str(&crate::crash_reporter::remove_extra_parameter_request("suite"))
                .unwrap();
        assert_eq!(remove["cmd"], "crash_reporter_remove_extra_parameter");
        assert_eq!(remove["key"], "suite");
    }

    #[test]
    fn safe_storage_requests_build_valid_json_with_escape() {
        let set: serde_json::Value =
            serde_json::from_str(&crate::safe_storage::set_request("svc", "acc", "a\"b\\c"))
                .unwrap();
        assert_eq!(set["cmd"], "safe_storage_set");
        assert_eq!(set["service"], "svc");
        assert_eq!(set["value"], "a\"b\\c");

        let get: serde_json::Value =
            serde_json::from_str(&crate::safe_storage::get_request("svc", "acc")).unwrap();
        assert_eq!(get["cmd"], "safe_storage_get");

        let del: serde_json::Value =
            serde_json::from_str(&crate::safe_storage::delete_request("svc", "acc")).unwrap();
        assert_eq!(del["cmd"], "safe_storage_delete");
    }

    #[test]
    fn dock_set_badge_request_escapes() {
        let v: serde_json::Value =
            serde_json::from_str(&crate::dock::set_badge_request("a\"b")).unwrap();
        assert_eq!(v["cmd"], "dock_set_badge");
        assert_eq!(v["text"], "a\"b");
    }

    #[test]
    fn app_set_badge_count_request() {
        let v: serde_json::Value =
            serde_json::from_str(&crate::set_badge_count_request(7)).unwrap();
        assert_eq!(v["cmd"], "app_set_badge_count");
        assert_eq!(v["count"], 7);
    }

    #[cfg(feature = "typescript")]
    #[test]
    fn specta_type_derive_compiles() {
        use crate::Type;

        // 사용자가 작성할 패턴 — Type derive로 specta::Type trait 자동 구현.
        #[derive(Type)]
        #[allow(dead_code)]
        struct GreetReq {
            name: String,
        }
        #[derive(Type)]
        #[allow(dead_code)]
        struct GreetRes {
            greeting: String,
        }

        // Type trait 구현이 컴파일되면 specta가 향후 ts export에 사용 가능.
        let _ = std::any::type_name::<GreetReq>();
        let _ = std::any::type_name::<GreetRes>();
    }

    #[cfg(feature = "typescript")]
    #[test]
    fn typescript_suji_handlers_export_module_augmentation() {
        use crate::{typescript::SujiHandlers, Type};
        use serde::{Deserialize, Serialize};

        #[derive(Type, Serialize, Deserialize)]
        #[allow(dead_code)]
        struct PingRes {
            msg: String,
        }

        #[derive(Type, Serialize, Deserialize)]
        #[allow(dead_code)]
        struct GreetReq {
            name: String,
        }

        #[derive(Type, Serialize, Deserialize)]
        #[allow(dead_code)]
        struct GreetRes {
            greeting: String,
        }

        #[derive(Type, Serialize, Deserialize)]
        #[serde(rename_all = "camelCase")]
        #[allow(dead_code)]
        struct AddReq {
            first_value: i32,
            second_value: i32,
        }

        #[derive(Type, Serialize, Deserialize)]
        #[allow(dead_code)]
        struct AddRes {
            result: i32,
        }

        let dts = SujiHandlers::new()
            .handler::<(), PingRes>("ping")
            .handler::<GreetReq, GreetRes>("greet")
            .handler::<AddReq, AddRes>("math:add")
            .export()
            .unwrap();

        assert!(dts.contains("declare module '@suji/api'"));
        assert!(dts.contains("ping: { req: void; res: PingRes };"), "{dts}");
        assert!(dts.contains("greet: { req: GreetReq; res: GreetRes };"));
        assert!(dts.contains("\"math:add\": { req: AddReq; res: AddRes };"));
        assert!(dts.contains("export type PingRes ="));
        assert!(dts.contains("msg: string"));
        assert!(dts.contains("export type GreetReq ="));
        assert!(dts.contains("name: string"));
        assert!(dts.contains("firstValue: number"));
        assert!(dts.contains("secondValue: number"));
    }

    #[test]
    fn user_attention_requests_carry_critical_and_id() {
        let req: serde_json::Value =
            serde_json::from_str(&crate::attention_request_json(true)).unwrap();
        assert_eq!(req["cmd"], "app_attention_request");
        assert_eq!(req["critical"], true);

        let cancel: serde_json::Value =
            serde_json::from_str(&crate::attention_cancel_json(42)).unwrap();
        assert_eq!(cancel["cmd"], "app_attention_cancel");
        assert_eq!(cancel["id"], 42);
    }
}

pub mod prelude {
    pub use crate::handle;
    pub use crate::invoke;
    pub use crate::off;
    pub use crate::on;
    pub use crate::platform;
    pub use crate::quit;
    pub use crate::send;
    pub use crate::send_to;
    #[cfg(feature = "typescript")]
    pub use crate::specta;
    #[cfg(feature = "typescript")]
    pub use crate::typescript::SujiHandlers;
    pub use crate::InvokeEvent;
    #[cfg(feature = "typescript")]
    pub use crate::Type;
    pub use crate::Window;
    pub use crate::PLATFORM_LINUX;
    pub use crate::PLATFORM_MACOS;
    pub use crate::PLATFORM_WINDOWS;
    pub use serde_json::json;
}

#[macro_export]
macro_rules! export_handlers {
    // 기본 형태: handlers만
    ($($handler:ident),* $(,)?) => {
        $crate::export_handlers!(@impl [$($handler),*]; []);
    };
    // 확장 형태: handlers + event listeners (`channel => extern_fn`)
    ($($handler:ident),* $(,)? ; $($ch:literal => $listener:ident),* $(,)?) => {
        $crate::export_handlers!(@impl [$($handler),*]; [$($ch => $listener),*]);
    };
    (@impl [$($handler:ident),*]; [$($ch:literal => $listener:ident),*]) => {
        #[no_mangle]
        pub extern "C" fn backend_init(core: *const $crate::SujiCore) {
            // AtomicPtr.store는 항상 replace — 매 호출이 최신 포인터로 갱신.
            // OnceLock은 첫 set만 성공해서 테스트 격리 시 use-after-free 발생.
            $crate::__SUJI_CORE.store(
                core as *mut $crate::SujiCore,
                std::sync::atomic::Ordering::Release,
            );
            if !core.is_null() {
                let core_ref: &'static $crate::SujiCore = unsafe { std::mem::transmute(&*core) };
                // 핸들러 채널 등록
                $(
                    let ch = std::ffi::CString::new(stringify!($handler)).unwrap();
                    (core_ref.register)(ch.as_ptr());
                )*
                // 이벤트 리스너 등록 (있으면)
                $(
                    let ch = std::ffi::CString::new($ch).unwrap();
                    (core_ref.on)(ch.as_ptr(), Some($listener), std::ptr::null_mut());
                )*
            }
            eprintln!("[Rust] ready");
        }

        #[no_mangle]
        pub extern "C" fn backend_handle_ipc(request: *const std::os::raw::c_char) -> *mut std::os::raw::c_char {
            let req_str = unsafe { std::ffi::CStr::from_ptr(request) }.to_str().unwrap_or("");
            let parsed: $crate::serde_json::Value = $crate::serde_json::from_str(req_str)
                .unwrap_or($crate::serde_json::json!({}));
            let cmd = parsed.get("cmd").and_then(|v| v.as_str()).unwrap_or("");

            let response = match cmd {
                $(stringify!($handler) => {
                    let result = $handler(parsed.clone());
                    $crate::serde_json::json!({"from":"rust","cmd":cmd,"result":result}).to_string()
                }),*
                _ => $crate::serde_json::json!({"from":"rust","error":format!("unknown: {}",cmd)}).to_string(),
            };

            std::ffi::CString::new(response).unwrap().into_raw()
        }

        #[no_mangle]
        pub extern "C" fn backend_free(ptr: *mut std::os::raw::c_char) {
            if !ptr.is_null() { unsafe { drop(std::ffi::CString::from_raw(ptr)); } }
        }

        #[no_mangle]
        pub extern "C" fn backend_destroy() { eprintln!("[Rust] bye"); }
    };
}

/// 정적 링크용 — 고유 `suji_rs_*` 심볼로 backend C ABI 노출.
///
/// dlopen 데스크톱은 `export_handlers!`(고정 `backend_*`)를 dylib 네임스페이스로
/// 격리하지만, iOS 처럼 여러 백엔드를 한 바이너리에 정적 링크하면 `backend_*`가
/// 충돌한다. 이 매크로는 언어 고유 prefix(`suji_rs_`)로 내보내 Go(`suji_go_`)·
/// Zig 코어와 공존시킨다. 호스트는 `suji_core_register_handler` 로 등록.
/// (앱당 Rust 백엔드 1개 가정 — 멀티백엔드의 정상 패턴.)
///
/// NOTE: 본문은 `export_handlers!` @impl 의 의도적 복제 — 심볼명(`suji_rs_*`)과
/// stderr 로그 생략만 다르다. macro_rules 가 fn 식별자를 paste 못 해 공통화
/// 불가. 한쪽 수정 시 다른 쪽도 함께 갱신할 것.
#[macro_export]
macro_rules! export_handlers_static {
    ($($handler:ident),* $(,)?) => {
        $crate::export_handlers_static!(@impl [$($handler),*]; []);
    };
    ($($handler:ident),* $(,)? ; $($ch:literal => $listener:ident),* $(,)?) => {
        $crate::export_handlers_static!(@impl [$($handler),*]; [$($ch => $listener),*]);
    };
    (@impl [$($handler:ident),*]; [$($ch:literal => $listener:ident),*]) => {
        #[no_mangle]
        pub extern "C" fn suji_rs_backend_init(core: *const $crate::SujiCore) {
            $crate::__SUJI_CORE.store(
                core as *mut $crate::SujiCore,
                std::sync::atomic::Ordering::Release,
            );
            if !core.is_null() {
                let core_ref: &'static $crate::SujiCore = unsafe { std::mem::transmute(&*core) };
                $(
                    let ch = std::ffi::CString::new(stringify!($handler)).unwrap();
                    (core_ref.register)(ch.as_ptr());
                )*
                $(
                    let ch = std::ffi::CString::new($ch).unwrap();
                    (core_ref.on)(ch.as_ptr(), Some($listener), std::ptr::null_mut());
                )*
            }
        }

        #[no_mangle]
        pub extern "C" fn suji_rs_backend_handle_ipc(request: *const std::os::raw::c_char) -> *mut std::os::raw::c_char {
            let req_str = unsafe { std::ffi::CStr::from_ptr(request) }.to_str().unwrap_or("");
            let parsed: $crate::serde_json::Value = $crate::serde_json::from_str(req_str)
                .unwrap_or($crate::serde_json::json!({}));
            let cmd = parsed.get("cmd").and_then(|v| v.as_str()).unwrap_or("");

            let response = match cmd {
                $(stringify!($handler) => {
                    let result = $handler(parsed.clone());
                    $crate::serde_json::json!({"from":"rust","cmd":cmd,"result":result}).to_string()
                }),*
                _ => $crate::serde_json::json!({"from":"rust","error":format!("unknown: {}",cmd)}).to_string(),
            };

            std::ffi::CString::new(response).unwrap().into_raw()
        }

        #[no_mangle]
        pub extern "C" fn suji_rs_backend_free(ptr: *mut std::os::raw::c_char) {
            if !ptr.is_null() { unsafe { drop(std::ffi::CString::from_raw(ptr)); } }
        }

        #[no_mangle]
        pub extern "C" fn suji_rs_backend_destroy() {}
    };
}
