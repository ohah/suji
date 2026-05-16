import Foundation

// 정적 링크된 Rust/Go 백엔드를 suji_core_register_handler 로 코어에 연결.
//
// register_handler 콜백은 (channel, json) → response 인데, 백엔드의
// *_backend_handle_ipc 는 `{"cmd":"<channel>", ...payload}` 형태 요청을 받는다.
// 아래 wrapper 가 그 형태로 브리지하고, 응답 포인터는 각 백엔드의 free 로 반납.

// hot path지만 데모 단순성 우선 — 이중 JSON 라운드트립(파싱→cmd 삽입→재직렬화).
// 프로덕션 SDK 승격 시 문자열 조립 경로로 전환 권장.
private func bridgeRequest(_ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?) -> String {
    let ch = channel.map { String(cString: $0) } ?? ""
    let js = json.map { String(cString: $0) } ?? "{}"
    var obj = ((try? JSONSerialization.jsonObject(with: Data(js.utf8))) as? [String: Any]) ?? [:]
    obj["cmd"] = ch
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "{\"cmd\":\"\(ch)\"}"
}

// 반환 포인터는 백엔드 소유(into_raw/C.CString) — withCString 임시 버퍼와 무관.
// 코어가 복사 후 *Free 로 반납(suji_core_register_handler 계약).
private func rustHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    bridgeRequest(channel, json).withCString { UnsafePointer(suji_rs_backend_handle_ipc($0)) }
}
private func rustFree(_ p: UnsafePointer<CChar>?) {
    suji_rs_backend_free(UnsafeMutablePointer(mutating: p))
}

private func goHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    bridgeRequest(channel, json).withCString { UnsafePointer(suji_go_backend_handle_ipc($0)) }
}
private func goFree(_ p: UnsafePointer<CChar>?) {
    suji_go_backend_free(UnsafeMutablePointer(mutating: p))
}

/// suji_core_init() 직후 호출. 백엔드 init(코어 cross-call 미사용이라 nil) +
/// 채널별 등록. 채널명 == 백엔드 핸들러 cmd.
func registerStaticBackends() {
    suji_rs_backend_init(nil)
    suji_go_backend_init(nil)

    func reg(_ ch: String,
             _ h: @escaping @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?,
             _ f: @escaping @convention(c) (UnsafePointer<CChar>?) -> Void) {
        if suji_core_register_handler(ch, h, f) != 0 {
            NSLog("[suji] register_handler failed: \(ch)")
        }
    }
    reg("greet", rustHandler, rustFree)
    reg("add", rustHandler, rustFree)
    reg("go:ping", goHandler, goFree)
    reg("go:upper", goHandler, goFree)
}
