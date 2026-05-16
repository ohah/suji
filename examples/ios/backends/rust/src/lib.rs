//! iOS 정적 링크 Rust 백엔드 예제.
//!
//! 데스크톱 dlopen 예제(`examples/rust-backend`)와 동일 핸들러를, iOS 호스트
//! 바이너리에 정적 링크되도록 `suji_rs_*` 고유 심볼로 노출한다.

#[suji::handle]
fn greet(name: String) -> String {
    format!("Hello, {}! (from rust, statically linked on iOS)", name)
}

#[suji::handle]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

// suji_rs_backend_init / _handle_ipc / _free / _destroy 를 #[no_mangle] 로 노출.
suji::export_handlers_static!(greet, add);
