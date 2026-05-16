import Foundation

// 멀티 변형 — Rust + Go 정적 백엔드 등록.
// 공용 sujiBridgeRequest/sujiReg 는 _shared/BackendBridge.swift.
// 반환 포인터는 백엔드 소유 — 코어가 복사 후 *Free 로 반납(register_handler 계약).

private func rustHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    sujiBridgeRequest(channel, json).withCString { UnsafePointer(suji_rs_backend_handle_ipc($0)) }
}
private func rustFree(_ p: UnsafePointer<CChar>?) {
    suji_rs_backend_free(UnsafeMutablePointer(mutating: p))
}

private func goHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    sujiBridgeRequest(channel, json).withCString { UnsafePointer(suji_go_backend_handle_ipc($0)) }
}
private func goFree(_ p: UnsafePointer<CChar>?) {
    suji_go_backend_free(UnsafeMutablePointer(mutating: p))
}

func registerStaticBackends() {
    suji_rs_backend_init(nil)
    suji_go_backend_init(nil)
    sujiReg("greet", rustHandler, rustFree)
    sujiReg("add", rustHandler, rustFree)
    sujiReg("go:ping", goHandler, goFree)
    sujiReg("go:upper", goHandler, goFree)
}
