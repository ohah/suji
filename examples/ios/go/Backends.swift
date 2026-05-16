import Foundation

// go 단독 변형 — Go 정적(c-archive) 백엔드만 등록.
// 공용 sujiBridgeRequest/sujiReg 는 _shared/BackendBridge.swift.
// 반환 포인터는 백엔드 소유 — 코어가 복사 후 goFree 로 반납(register_handler 계약).

private func goHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    sujiBridgeRequest(channel, json).withCString { UnsafePointer(suji_go_backend_handle_ipc($0)) }
}
private func goFree(_ p: UnsafePointer<CChar>?) {
    suji_go_backend_free(UnsafeMutablePointer(mutating: p))
}

func registerStaticBackends() {
    suji_go_backend_init(nil)
    sujiReg("go:ping", goHandler, goFree)
    sujiReg("go:upper", goHandler, goFree)
}
