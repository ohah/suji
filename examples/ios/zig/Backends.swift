import Foundation

// zig 단독 변형 — Zig 정적 백엔드만 등록 (suji_zig_backend_*).
// 공용 sujiBridgeRequest/sujiReg 는 _shared/BackendBridge.swift.
// 반환 포인터는 백엔드 소유 — 코어가 복사 후 zigFree 로 반납(register_handler 계약).

private func zigHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    sujiBridgeRequest(channel, json).withCString { UnsafePointer(suji_zig_backend_handle_ipc($0)) }
}
private func zigFree(_ p: UnsafePointer<CChar>?) {
    suji_zig_backend_free(UnsafeMutablePointer(mutating: p))
}

func registerStaticBackends() {
    suji_zig_backend_init(nil)
    sujiReg("zig:ping", zigHandler, zigFree)
    sujiReg("zig:rev", zigHandler, zigFree)
}
