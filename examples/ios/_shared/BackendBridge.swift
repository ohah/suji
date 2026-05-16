import Foundation

// 변형 공용 — 백엔드 심볼을 참조하지 않는 부분만 공유한다.
// (언어별 *Handler/*Free 는 suji_rs_*/suji_go_* 를 참조하므로 변형에 둔다 —
//  미사용 변형에서 그 심볼 링크를 강제하지 않기 위함.)

// (channel,json) → {"cmd":"<channel>", ...json}. hot path지만 데모 단순성
// 우선(이중 JSON 라운드트립). 프로덕션 SDK 승격 시 문자열 조립 경로 권장.
func sujiBridgeRequest(_ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?) -> String {
    let ch = channel.map { String(cString: $0) } ?? ""
    let js = json.map { String(cString: $0) } ?? "{}"
    var obj = ((try? JSONSerialization.jsonObject(with: Data(js.utf8))) as? [String: Any]) ?? [:]
    obj["cmd"] = ch
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let s = String(data: data, encoding: .utf8) { return s }
    return "{\"cmd\":\"\(ch)\"}"
}

// suji_core_register_handler + 실패 로깅. 변형의 registerStaticBackends() 가
// 자기 백엔드 핸들러로 호출.
func sujiReg(_ ch: String,
             _ h: @escaping @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?,
             _ f: @escaping @convention(c) (UnsafePointer<CChar>?) -> Void) {
    if suji_core_register_handler(ch, h, f) != 0 {
        NSLog("[suji] register_handler failed: \(ch)")
    }
}
