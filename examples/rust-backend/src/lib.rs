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

suji::export_handlers!(ping, greet, add);
