//! Shared constants for PDF print/capture output IPC.

/// PDF/capture path stack buffer. Keep in sync with browser IPC deferred slots.
pub const PDF_PATH_STACK_BUF: usize = 2048;

/// PDF 인쇄 완료 이벤트 — caller(SDK)가 listener로 path 매칭. 이름 변경 시 5 SDK
/// + 문서 모두 동시 변경 필요 (SDK_PORTING.md §4.3 cmd 표 참조).
pub const EVENT_PDF_PRINT_FINISHED: []const u8 = "window:pdf-print-finished";
pub const EVENT_PAGE_CAPTURED: []const u8 = "window:page-captured";
