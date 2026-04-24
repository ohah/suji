use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, ItemFn, FnArg, Pat, Type};

/// 파라미터 타입의 path 마지막 segment가 `InvokeEvent`인지 판별.
/// `InvokeEvent`, `suji::InvokeEvent`, `crate::InvokeEvent` 모두 허용.
fn is_invoke_event_type(ty: &Type) -> bool {
    if let Type::Path(tp) = ty {
        if let Some(last) = tp.path.segments.last() {
            return last.ident == "InvokeEvent";
        }
    }
    false
}

/// `#[suji::command]` 매크로
///
/// Rust 함수를 Suji 커맨드로 등록합니다.
/// 일반 파라미터는 이름으로 JSON에서 자동 추출.
/// 타입이 `InvokeEvent`인 파라미터는 wire의 `__window`/`__window_name`에서 자동 파생.
///
/// ```rust
/// #[suji::command]
/// fn greet(name: String) -> String {
///     format!("Hello, {}!", name)
/// }
///
/// #[suji::command]
/// fn save(filename: String, event: suji::InvokeEvent) -> serde_json::Value {
///     serde_json::json!({ "ok": true, "from_window": event.window.id })
/// }
/// ```
#[proc_macro_attribute]
pub fn command(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let func = parse_macro_input!(item as ItemFn);
    let func_name = &func.sig.ident;
    let func_body = &func.block;

    // 파라미터 추출 + 각 파라미터의 바인딩 코드 생성
    let param_extracts: Vec<_> = func.sig.inputs.iter().filter_map(|arg| {
        let FnArg::Typed(pat_type) = arg else { return None };
        let Pat::Ident(ident) = &*pat_type.pat else { return None };
        let name = &ident.ident;
        let ty = &pat_type.ty;
        let name_str = name.to_string();

        if is_invoke_event_type(ty) {
            // InvokeEvent: wire 메타데이터에서 파생 — 이름과 무관
            Some(quote! {
                let #name: #ty = ::suji::InvokeEvent::from_request(&__parsed);
            })
        } else {
            // 일반 필드: JSON에서 같은 이름의 키로 추출
            Some(quote! {
                let #name: #ty = __parsed.get(#name_str)
                    .and_then(|v| serde_json::from_value(v.clone()).ok())
                    .unwrap_or_default();
            })
        }
    }).collect();

    let expanded = quote! {
        /// Suji 커맨드: JSON Value를 받아서 결과를 serde_json::Value로 반환
        pub fn #func_name(__parsed: serde_json::Value) -> serde_json::Value {
            #(#param_extracts)*
            let __inner = || #func_body;
            serde_json::json!(__inner())
        }
    };

    TokenStream::from(expanded)
}
