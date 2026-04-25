//! # suji-plugin-state
//!
//! State plugin wrapper for Suji Rust backends.
//! All calls go through `suji::invoke("state:*", ...)`.
//!
//! ```rust
//! use suji_plugin_state as state;
//!
//! state::set("user", r#""yoon""#);
//! let val = state::get("user");
//! state::delete("user");
//! let keys = state::keys();
//! ```

/// Get a value by key in the global scope. None if not found.
pub fn get(key: &str) -> Option<String> {
    get_in(key, None)
}

/// Get with explicit scope (e.g. "window:2", "session:onboard").
pub fn get_in(key: &str, scope: Option<&str>) -> Option<String> {
    let mut req = serde_json::json!({"cmd": "state:get", "key": key});
    if let Some(s) = scope { req["scope"] = serde_json::json!(s); }
    let resp = suji::invoke("state", &req.to_string())?;
    let parsed: serde_json::Value = serde_json::from_str(&resp).ok()?;
    let value = parsed.get("result")?.get("value")?;
    if value.is_null() { return None; }
    Some(value.to_string())
}

/// Set a key to a raw JSON value (global scope).
pub fn set(key: &str, value: &str) {
    set_in(key, value, None);
}

/// Set with explicit scope.
pub fn set_in(key: &str, value: &str, scope: Option<&str>) {
    let val: serde_json::Value = serde_json::from_str(value).unwrap_or(serde_json::Value::Null);
    let mut req = serde_json::json!({"cmd": "state:set", "key": key, "value": val});
    if let Some(s) = scope { req["scope"] = serde_json::json!(s); }
    suji::invoke("state", &req.to_string());
}

/// Delete a key (global scope).
pub fn delete(key: &str) { delete_in(key, None); }

pub fn delete_in(key: &str, scope: Option<&str>) {
    let mut req = serde_json::json!({"cmd": "state:delete", "key": key});
    if let Some(s) = scope { req["scope"] = serde_json::json!(s); }
    suji::invoke("state", &req.to_string());
}

/// Get all keys. With scope: only that scope's user-keys (prefix stripped).
pub fn keys() -> Vec<String> { keys_in(None) }

pub fn keys_in(scope: Option<&str>) -> Vec<String> {
    let mut req = serde_json::json!({"cmd": "state:keys"});
    if let Some(s) = scope { req["scope"] = serde_json::json!(s); }
    let resp = match suji::invoke("state", &req.to_string()) {
        Some(r) => r,
        None => return vec![],
    };
    let parsed: serde_json::Value = match serde_json::from_str(&resp) {
        Ok(v) => v,
        Err(_) => return vec![],
    };
    let keys_val = parsed.get("result").and_then(|r| r.get("keys")).and_then(|k| k.as_array());
    match keys_val {
        Some(arr) => arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        None => vec![],
    }
}

/// Clear all state (every scope).
pub fn clear() {
    let req = r#"{"cmd":"state:clear"}"#;
    suji::invoke("state", req);
}

/// Clear only one scope.
pub fn clear_scope(scope: &str) {
    let req = serde_json::json!({"cmd": "state:clear", "scope": scope}).to_string();
    suji::invoke("state", &req);
}

/// Watch a key for changes via EventBus (global scope channel).
/// Returns a listener ID that can be passed to `suji::off()` to unsubscribe.
pub fn watch(
    key: &str,
    callback: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char, *mut std::os::raw::c_void),
    arg: *mut std::os::raw::c_void,
) -> u64 {
    watch_in(key, None, callback, arg)
}

pub fn watch_in(
    key: &str,
    scope: Option<&str>,
    callback: extern "C" fn(*const std::os::raw::c_char, *const std::os::raw::c_char, *mut std::os::raw::c_void),
    arg: *mut std::os::raw::c_void,
) -> u64 {
    let channel = match scope {
        None | Some("global") => format!("state:{}", key),
        Some(s) => format!("state:{}:{}", s, key),
    };
    suji::on(&channel, callback, arg)
}
