use suji::prelude::*;

#[suji::command]
fn ping() -> String {
    "pong".to_string()
}

#[suji::command]
fn greet(name: String) -> String {
    format!("Hello, {}!", name)
}

#[suji::command]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

suji::export_commands!(ping, greet, add);
