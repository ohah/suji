import UIKit
import WebKit

/// 네이티브 → JS 이벤트 트램폴린. `@convention(c)` 로 쓰려면 캡처 없는
/// 톱레벨 함수여야 한다. context(arg)로 호스트 VC를 복원한다.
private func sujiEventTrampoline(
    _ name: UnsafePointer<CChar>?,
    _ data: UnsafePointer<CChar>?,
    _ arg: UnsafeMutableRawPointer?
) {
    guard let arg = arg else { return }
    let vc = Unmanaged<SujiHostViewController>.fromOpaque(arg).takeUnretainedValue()
    let n = name.map { String(cString: $0) } ?? ""
    let d = data.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async { vc.emitToJS(name: n, json: d) }
}

// 호스트 invoke 핸들러 (suji_core_register_handler). 캡처 없는 톱레벨 +
// strdup — 코어가 즉시 복사하고 sujiHandlerFree 로 원본을 돌려준다.
// 락 없는 전역: invoke 는 WKScriptMessageHandler(메인 스레드) + single-threaded
// 코어 경로로만 진입하므로 데이터 레이스 없음.
private var sujiCounter = 0

private func sujiPingHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    return UnsafePointer(strdup("{\"pong\":true,\"from\":\"ios-native\"}"))
}

private func sujiCounterHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    sujiCounter += 1
    return UnsafePointer(strdup("{\"n\":\(sujiCounter)}"))
}

private func sujiHandlerFree(_ ptr: UnsafePointer<CChar>?) {
    free(UnsafeMutableRawPointer(mutating: ptr))
}

final class SujiHostViewController: UIViewController, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var tickListenerId: UInt64 = 0
    private var tickTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard suji_core_init() == 0 else {
            fatalError("suji_core_init failed")
        }

        // 순수 Swift 핸들러 데모.
        _ = suji_core_register_handler("ping", sujiPingHandler, sujiHandlerFree)
        _ = suji_core_register_handler("counter:inc", sujiCounterHandler, sujiHandlerFree)
        // 정적 링크된 Rust/Go 백엔드 등록 (greet/add/go:ping/go:upper).
        registerStaticBackends()

        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "suji")
        ucc.addUserScript(WKUserScript(
            source: Self.bridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        cfg.userContentController = ucc

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        if let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                     subdirectory: "web")
            ?? Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
        }

        // 네이티브 → JS 이벤트 데모: 백엔드 없이 코어가 직접 발행하는 틱을
        // 프론트가 suji.on("demo:tick") 으로 수신.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        tickListenerId = suji_core_on("demo:tick", sujiEventTrampoline, ctx)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let payload = "{\"t\":\(Int(Date().timeIntervalSince1970))}"
            "demo:tick".withCString { ev in
                payload.withCString { js in suji_core_emit(ev, js) }
            }
        }
    }

    deinit {
        tickTimer?.invalidate()
        if tickListenerId != 0 { suji_core_off(tickListenerId) }
        suji_core_destroy()
    }

    // MARK: JS → 네이티브

    func userContentController(
        _ uc: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "suji",
              let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let channel = body["channel"] as? String
        else { return }
        let json = (body["json"] as? String) ?? "{}"

        let result: String = channel.withCString { ch in
            json.withCString { js in
                guard let p = suji_core_invoke(ch, js) else { return "" }
                defer { suji_core_free(p) }
                return String(cString: p)
            }
        }
        let call = "window.__suji__.__resolve__(\(id), \(Self.jsLiteral(result)));"
        webView.evaluateJavaScript(call, completionHandler: nil)
    }

    // MARK: 네이티브 → JS

    func emitToJS(name: String, json: String) {
        let call = "window.__suji__.__emit__(\(Self.jsLiteral(name)), \(Self.jsLiteral(json)));"
        webView.evaluateJavaScript(call, completionHandler: nil)
    }

    /// Swift String → JS 안전 큰따옴표 문자열 리터럴 (JSON 인코딩 재사용).
    private static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(arr.dropFirst().dropLast()) // ["x"] → "x"
    }

    // MARK: 주입 자원

    private static let bridgeJS = """
    (function () {
      var _id = 0, _pending = {}, _listeners = {};
      function invoke(channel, payload) {
        return new Promise(function (res) {
          var id = ++_id; _pending[id] = res;
          window.webkit.messageHandlers.suji.postMessage({
            id: id, channel: String(channel),
            json: JSON.stringify(payload === undefined ? {} : payload)
          });
        });
      }
      function __resolve__(id, json) {
        var r = _pending[id]; if (!r) return; delete _pending[id];
        try { r(json ? JSON.parse(json) : null); } catch (e) { r(json); }
      }
      function on(name, cb) { (_listeners[name] = _listeners[name] || []).push(cb); }
      function __emit__(name, json) {
        var ls = _listeners[name]; if (!ls) return;
        var d; try { d = json ? JSON.parse(json) : null; } catch (e) { d = json; }
        ls.forEach(function (f) { try { f(d); } catch (e) {} });
      }
      var api = { invoke: invoke, on: on, __resolve__: __resolve__, __emit__: __emit__ };
      window.__suji__ = api; window.suji = api;
    })();
    """

    private static let fallbackHTML = """
    <!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
    <body style="font:16px -apple-system;padding:2rem">
    <h2>Suji iOS host</h2><p>index.html 번들 누락 — 브릿지만 로드됨.</p></body>
    """
}
