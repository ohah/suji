use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, ItemFn, FnArg, Pat};

/// `#[suji::command]` 매크로
///
/// Rust 함수를 Suji 커맨드로 등록합니다.
/// JSON 파라미터를 자동 추출하고, 결과를 자동 직렬화합니다.
///
/// ```rust
/// #[suji::command]
/// fn greet(name: String) -> String {
///     format!("Hello, {}!", name)
/// }
/// ```
#[proc_macro_attribute]
pub fn command(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let func = parse_macro_input!(item as ItemFn);
    let func_name = &func.sig.ident;
    let func_body = &func.block;

    // 파라미터 추출
    let params: Vec<_> = func.sig.inputs.iter().filter_map(|arg| {
        if let FnArg::Typed(pat_type) = arg {
            if let Pat::Ident(ident) = &*pat_type.pat {
                return Some((ident.ident.clone(), pat_type.ty.clone()));
            }
        }
        None
    }).collect();

    let param_names: Vec<_> = params.iter().map(|(n, _)| n.clone()).collect();
    let param_types: Vec<_> = params.iter().map(|(_, t)| t.clone()).collect();
    let param_strs: Vec<_> = params.iter().map(|(n, _)| n.to_string()).collect();

    // JSON에서 파라미터 추출
    let param_extracts: Vec<_> = param_strs.iter().zip(param_names.iter()).zip(param_types.iter())
        .map(|((name_str, name), ty)| {
            quote! {
                let #name: #ty = __parsed.get(#name_str)
                    .and_then(|v| serde_json::from_value(v.clone()).ok())
                    .unwrap_or_default();
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
