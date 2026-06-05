import Foundation

// python 변형 — embedded CPython 백엔드(suji_python_backend_*)만 등록.
// 데스크탑 src/platform/python.zig 모바일 대응. 공용 sujiBridgeRequest/sujiReg 는
// _shared/BackendBridge.swift. 반환 포인터는 백엔드 소유 — 코어가 복사 후 pythonFree
// 로 반납(register_handler 계약).

private func pythonHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    sujiBridgeRequest(channel, json).withCString { UnsafePointer(suji_python_backend_handle_ipc($0)) }
}
private func pythonFree(_ p: UnsafePointer<CChar>?) {
    suji_python_backend_free(UnsafeMutablePointer(mutating: p))
}

func registerStaticBackends() {
    suji_python_backend_init(nil)

    // PYTHONHOME = <bundle>/python (stdlib 이 python/lib/python3.13), entry =
    // <bundle>/main.py — build-lib.sh 가 둘을 앱 번들에 스테이징.
    guard let res = Bundle.main.resourcePath else {
        NSLog("[suji] python: no resourcePath")
        return
    }
    let home = res + "/python"
    let entry = res + "/main.py"
    let started: Bool = home.withCString { h in
        entry.withCString { e in suji_python_backend_start(h, e) == 0 }
    }
    guard started else {
        NSLog("[suji] python backend start failed (home=\(home))")
        return
    }

    // main.py 가 suji.handle 로 등록한 핸들러 이름을 받아 각 채널을 코어에 등록
    // → 프론트가 suji.invoke("ping") 처럼 데스크탑과 동일하게 호출(채널=핸들러).
    guard let cstr = suji_python_backend_channels() else { return }
    defer { suji_python_backend_free(cstr) }
    let jsonStr = String(cString: cstr)
    if let data = jsonStr.data(using: .utf8),
       let names = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
        for ch in names { sujiReg(ch, pythonHandler, pythonFree) }
    } else {
        NSLog("[suji] python: bad channels json: \(jsonStr)")
    }
}
