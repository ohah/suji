// suji 공개 모듈(@import("suji") = src/core/app.zig)의 핵심 표면을 외부
// 소비자 관점에서 사용 — 빌드되면 패키지 소비성(b.dependency)이 무결.
const suji = @import("suji");

fn ping(req: suji.Request) suji.Response {
    return req.ok(.{ .msg = "pong" });
}

pub const app = suji.app().handle("ping", ping);

comptime {
    _ = suji.exportApp(app);
}
