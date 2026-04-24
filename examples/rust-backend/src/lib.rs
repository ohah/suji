use std::os::raw::{c_char, c_void};
use suji::prelude::*;

#[suji::handle]
fn ping() -> String {
    "pong".to_string()
}

#[suji::handle]
fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}

#[suji::handle]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

// Electron 패턴: window:all-closed 이벤트에서 플랫폼별 quit.
// macOS는 창 닫혀도 앱 유지 (dock), 나머지는 종료.
extern "C" fn on_window_all_closed(
    _channel: *const c_char,
    _data: *const c_char,
    _arg: *mut c_void,
) {
    let p = platform();
    eprintln!("[Rust] window-all-closed received (platform={})", p);
    if p != PLATFORM_MACOS {
        eprintln!("[Rust] non-macOS → suji::quit()");
        quit();
    }
}

suji::export_handlers!(
    ping, greet, add;
    "window:all-closed" => on_window_all_closed
);
