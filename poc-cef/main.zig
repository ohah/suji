const std = @import("std");
const cef_platform = @import("cef");

pub fn main() !void {
    // 서브프로세스 처리 (렌더러/GPU인 경우 여기서 exit)
    cef_platform.executeSubprocess();

    // CEF 초기화
    try cef_platform.initialize(.{
        .title = "Suji CEF Test",
        .width = 1024,
        .height = 768,
        .url = "https://www.google.com",
        .debug = true,
    });

    // 브라우저 창 생성
    try cef_platform.createBrowser(.{
        .title = "Suji CEF Test",
        .width = 1024,
        .height = 768,
        .url = "https://www.google.com",
    });

    // 메시지 루프 (블로킹)
    cef_platform.run();

    // 종료
    cef_platform.shutdown();
}
