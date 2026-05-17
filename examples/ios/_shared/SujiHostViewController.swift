import Security
import UIKit
import UniformTypeIdentifiers
import UserNotifications
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
private var sujiNotifSeq = 0

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

// e2e 검증 채널 — e2e.html 이 디바이스 내에서 clipboard 등 왕복을 실행하고
// verdict JSON 을 이 채널로 보고. 앱 데이터컨테이너 Documents 에 파일로 써
// `ios-e2e.sh` 가 simctl get_app_container 로 회수·assert(log stream 보다
// 결정적 — 프로세스 종료 후에도 남음).
private func sujiE2EReportHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    let body = json.map { String(cString: $0) } ?? "{}"
    if let docs = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask).first {
        try? body.write(to: docs.appendingPathComponent("suji-e2e-report.json"),
                        atomically: true, encoding: .utf8)
    }
    return UnsafePointer(strdup("{\"ok\":true}"))
}

// 데스크톱 `__core__`(src/main.zig cefHandleCore) 의 모바일 대응 — 같은
// `@suji/api`(coreCall→`__suji__.core`) 가 iOS 에서도 동작하도록 cmd 를
// iOS 네이티브로 디스패치. 응답 JSON 은 데스크톱과 키-동형(프론트 무수정).
// JSONSerialization 으로 직렬화해 text 이스케이프 drift 방지(수동 조립 금지).
// WKScriptMessageHandler(메인 스레드)+single-thread 코어 경로라 UIPasteboard
// 접근 안전. 미지원 cmd 는 데스크톱 coreError 와 동형(unknown_cmd).
private func sujiCoreDispatch(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    let raw = json.map { String(cString: $0) } ?? "{}"
    let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
        as? [String: Any] ?? [:]
    let cmd = (obj["cmd"] as? String) ?? ""

    var resp: [String: Any] = ["from": "zig-core", "cmd": cmd]
    switch cmd {
    case "clipboard_read_text":
        resp["text"] = UIPasteboard.general.string ?? ""
    case "clipboard_write_text":
        UIPasteboard.general.string = (obj["text"] as? String) ?? ""
        resp["success"] = true
    case "clipboard_clear":
        UIPasteboard.general.items = []
        resp["success"] = true
    case "clipboard_write_html", "clipboard_write_rtf":
        // setValue 는 public.html/rtf 를 Data 로 저장해 String 왕복 실패
        // (e2e 적발) → setData(UTF-8) 로 명시 저장.
        let uti = cmd == "clipboard_write_html" ? "public.html" : "public.rtf"
        let key = cmd == "clipboard_write_html" ? "html" : "rtf"
        UIPasteboard.general.setData(
            Data(((obj[key] as? String) ?? "").utf8), forPasteboardType: uti)
        resp["success"] = true
    case "clipboard_read_html", "clipboard_read_rtf":
        let uti = cmd == "clipboard_read_html" ? "public.html" : "public.rtf"
        let key = cmd == "clipboard_read_html" ? "html" : "rtf"
        resp[key] = UIPasteboard.general.data(forPasteboardType: uti)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    case "clipboard_write_image":
        // base64 PNG → raw Data 를 public.png UTI 로(UIImage 재인코딩 회피 →
        // 바이트 정확 왕복). 데스크톱 raw PNG base64 계약과 동형.
        if let d = Data(base64Encoded: (obj["data"] as? String) ?? "") {
            UIPasteboard.general.setData(d, forPasteboardType: "public.png")
            resp["success"] = true
        } else {
            resp["success"] = false
        }
    case "clipboard_read_image":
        resp["data"] = UIPasteboard.general
            .data(forPasteboardType: "public.png")?
            .base64EncodedString() ?? ""
    case "shell_open_external":
        // canOpenURL 로 동기 판정(데스크톱 success 의미=열기 시도 가능과 동등),
        // open 은 fire-and-forget(completionHandler 비동기 — 동기 반환 불가).
        if let u = URL(string: (obj["url"] as? String) ?? ""),
           UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u, options: [:], completionHandler: nil)
            resp["success"] = true
        } else {
            resp["success"] = false
        }
    case "notification_is_supported":
        resp["supported"] = true
    case "notification_request_permission":
        // ⚠️ iOS UNUserNotificationCenter 권한은 *완전 비동기* — 동기
        // `granted` 산출 불가(getNotificationSettings 도 콜백). 데스크톱
        // 동기 계약을 깨지 않도록: 권한 요청을 발사하고 즉시 현재값(미정이면
        // false) 반환 + 콜백 확정 시 `notification:permission {granted}` 이벤트
        // 발신(앱이 재질의/이벤트로 반응). 정직한 한계.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, _ in
            let js = "{\"granted\":\(granted)}"
            "notification:permission".withCString { ev in
                js.withCString { p in suji_core_emit(ev, p) }
            }
        }
        resp["granted"] = false
    case "notification_show":
        let n = sujiNotifSeq
        sujiNotifSeq += 1
        let nid = "suji-notif-\(n)"
        let content = UNMutableNotificationContent()
        content.title = (obj["title"] as? String) ?? ""
        content.body = (obj["body"] as? String) ?? ""
        if (obj["silent"] as? Bool) != true { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: nid, content: content, trigger: nil)
        )
        resp["notificationId"] = nid
        resp["success"] = true
    case "notification_close":
        let nid = (obj["notificationId"] as? String) ?? ""
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [nid])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [nid])
        resp["success"] = true
    case "safe_storage_set", "safe_storage_get", "safe_storage_delete":
        // 데스크톱 Keychain(safe_storage)의 iOS 대응 — 동일 Security.framework
        // Keychain(kSecClassGenericPassword, service+account 키). 응답 데스크톱
        // 키-동형(set/delete=success, get=value, idempotent).
        let svc = (obj["service"] as? String) ?? ""
        let acc = (obj["account"] as? String) ?? ""
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: acc,
        ]
        if cmd == "safe_storage_set" {
            SecItemDelete(q as CFDictionary) // idempotent update
            q[kSecValueData as String] = Data(((obj["value"] as? String) ?? "").utf8)
            resp["success"] = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        } else if cmd == "safe_storage_get" {
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let st = SecItemCopyMatching(q as CFDictionary, &out)
            resp["value"] = (st == errSecSuccess ? (out as? Data) : nil)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        } else {
            let st = SecItemDelete(q as CFDictionary)
            resp["success"] = st == errSecSuccess || st == errSecItemNotFound
        }
    case "app_get_locale":
        // BCP 47 (preferredLanguages 는 "en-US" 형식; identifier 는 언더스코어).
        resp["locale"] = Locale.preferredLanguages.first ?? "en-US"
    case "app_get_name":
        let info = Bundle.main.infoDictionary
        resp["name"] = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String) ?? ""
    case "app_get_version":
        resp["version"] =
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    case "app_get_path":
        // iOS 샌드박스 매핑. ⚠️ desktop/downloads 는 데스크톱에선 ~/Desktop·
        // ~/Downloads(non-empty) 를 주는 *지원* 키지만, iOS 플랫폼 부재로
        // graceful 빈 문자열로 격하(데스크톱의 진짜 unknown 키와 동일 *형태*
        // 일 뿐 의미 동형은 아님 — 정직).
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> String {
            fm.urls(for: d, in: .userDomainMask).first?.path ?? ""
        }
        switch (obj["name"] as? String) ?? "" {
        case "home": resp["path"] = NSHomeDirectory()
        case "temp": resp["path"] = NSTemporaryDirectory()
        case "appData", "userData": resp["path"] = dir(.applicationSupportDirectory)
        case "documents": resp["path"] = dir(.documentDirectory)
        case "downloads": resp["path"] = dir(.downloadsDirectory) // 샌드박스 부재 시 격하 → ""
        default: resp["path"] = "" // desktop(데스크톱 지원)/진짜 unknown → 빈값 격하
        }
    default:
        resp["success"] = false
        resp["error"] = "unknown_cmd"
    }
    let data = (try? JSONSerialization.data(withJSONObject: resp))
        ?? Data(#"{"from":"zig-core","success":false,"error":"serialize"}"#.utf8)
    return UnsafePointer(strdup(String(decoding: data, as: UTF8.self)))
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
        // 데스크톱과 동일한 @suji/api(clipboard 등)용 __core__ 네이티브 디스패치.
        _ = suji_core_register_handler("__core__", sujiCoreDispatch, sujiHandlerFree)
        // e2e.html verdict 보고 채널 (ios-e2e.sh 가 데이터컨테이너 파일로 회수).
        _ = suji_core_register_handler("e2e:report", sujiE2EReportHandler, sujiHandlerFree)
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

        // e2e 모드(ios-e2e.sh 가 SIMCTL_CHILD_SUJI_E2E=1 주입)면 e2e.html 로드 —
        // 데모 무회귀(미설정 시 기존 index.html 경로 byte-동일).
        let page = ProcessInfo.processInfo.environment["SUJI_E2E"] == "1" ? "e2e" : "index"
        if let url = Bundle.main.url(forResource: page, withExtension: "html",
                                     subdirectory: "web")
            ?? Bundle.main.url(forResource: page, withExtension: "html") {
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

        // dialog 는 사용자 응답이 비동기 — 동기 suji_core_invoke 로 블로킹하면
        // 메인스레드(여기) 데드락(alert 표시·탭도 메인스레드). 호스트에서
        // 가로채 비동기 alert 표시 후 *같은 id* 로 __resolve__ (코어 프로토콜
        // 무변경, _pending[id] 는 그때까지 유지). 비-dialog 는 기존 동기 경로.
        if channel == "__core__",
           let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
               as? [String: Any] {
            switch (d["cmd"] as? String) ?? "" {
            case "dialog_show_message_box": presentMessageBox(id: id, opts: d); return
            case "dialog_show_error_box": presentErrorBox(id: id, opts: d); return
            case "dialog_show_open_dialog": presentDocPicker(id: id, save: false); return
            case "dialog_show_save_dialog": presentDocPicker(id: id, save: true); return
            default: break
            }
        }

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

    // 데스크톱 dialog_show_message_box 와 키-동형 응답
    // (`{from,cmd,response,checkboxChecked}`). UIAlertController 는 네이티브
    // 체크박스가 없어 checkboxChecked 는 항상 false(정직한 플랫폼 한계).
    private func presentMessageBox(id: Int, opts: [String: Any]) {
        let buttons = (opts["buttons"] as? [String]) ?? ["OK"]
        let alert = UIAlertController(
            title: opts["title"] as? String,
            message: opts["message"] as? String,
            preferredStyle: .alert
        )
        for (i, label) in buttons.enumerated() {
            alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                let json = "{\"from\":\"zig-core\",\"cmd\":\"dialog_show_message_box\","
                    + "\"response\":\(i),\"checkboxChecked\":false}"
                self?.webView.evaluateJavaScript(
                    "window.__suji__.__resolve__(\(id), \(Self.jsLiteral(json)));",
                    completionHandler: nil)
            })
        }
        present(alert, animated: true)
    }

    // 데스크톱 dialog_show_error_box(success:true; 프론트는 void)와 키-동형.
    // 1버튼 알림 — dismiss 시 resolve(message_box 가로채기와 동일 deferred).
    private func presentErrorBox(id: Int, opts: [String: Any]) {
        let alert = UIAlertController(title: opts["title"] as? String,
                                     message: opts["content"] as? String,
                                     preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            let j = "{\"from\":\"zig-core\",\"cmd\":\"dialog_show_error_box\",\"success\":true}"
            self?.webView.evaluateJavaScript(
                "window.__suji__.__resolve__(\(id), \(Self.jsLiteral(j)));", completionHandler: nil)
        })
        present(alert, animated: true)
    }

    // open/save → UIDocumentPicker(비동기 delegate). ⚠️ 모바일은 데스크톱
    // 절대경로가 아니라 보안스코프 URL 을 돌려준다(filePaths/filePath 에 .path
    // 문자열 — 의미 다름, 정직). save 는 iOS Files export 모델이라 빈 임시
    // 파일이 실제 생성됨(데스크톱 save panel 은 경로만 — 의미 근사). 키-동형
    // (open: canceled+filePaths[], save: canceled+filePath"").
    private var pendingDoc: (id: Int, save: Bool)?
    private func presentDocPicker(id: Int, save: Bool) {
        pendingDoc = (id, save)
        let picker: UIDocumentPickerViewController
        if save {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("suji-save-\(id)")
            FileManager.default.createFile(atPath: tmp.path, contents: Data())
            picker = UIDocumentPickerViewController(forExporting: [tmp])
        } else {
            picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [UTType.item])
        }
        picker.delegate = self
        present(picker, animated: true)
    }

    private func resolveDoc(_ urls: [URL], canceled: Bool) {
        guard let p = pendingDoc else { return }
        pendingDoc = nil
        let j: String
        if p.save {
            // forExporting 용 빈 임시파일 정리(pick/cancel 모두 여기 경유) —
            // id 로 결정적 경로라 재구성 삭제 안전. tmp 누적 방지.
            try? FileManager.default.removeItem(at: FileManager.default
                .temporaryDirectory.appendingPathComponent("suji-save-\(p.id)"))
            let fp = canceled ? "" : (urls.first?.path ?? "")
            j = "{\"from\":\"zig-core\",\"cmd\":\"dialog_show_save_dialog\","
                + "\"canceled\":\(canceled),\"filePath\":\(Self.jsLiteral(fp))}"
        } else {
            let arr = canceled ? [] : urls.map { $0.path }
            let list = arr.map { Self.jsLiteral($0) }.joined(separator: ",")
            j = "{\"from\":\"zig-core\",\"cmd\":\"dialog_show_open_dialog\","
                + "\"canceled\":\(canceled),\"filePaths\":[\(list)]}"
        }
        webView.evaluateJavaScript(
            "window.__suji__.__resolve__(\(p.id), \(Self.jsLiteral(j)));",
            completionHandler: nil)
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
      // coreCall(@suji/api) 전용 — 이미 stringify 된 문자열을 그대로(재인코딩
      // 금지) __core__ 채널로. 데스크톱 __suji__.core 계약과 동형.
      function core(json) {
        return new Promise(function (res) {
          var id = ++_id; _pending[id] = res;
          window.webkit.messageHandlers.suji.postMessage({
            id: id, channel: "__core__",
            json: (typeof json === "string" ? json : JSON.stringify(json))
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
      var api = { invoke: invoke, core: core, on: on, __resolve__: __resolve__, __emit__: __emit__ };
      window.__suji__ = api; window.suji = api;
    })();
    """

    private static let fallbackHTML = """
    <!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
    <body style="font:16px -apple-system;padding:2rem">
    <h2>Suji iOS host</h2><p>index.html 번들 누락 — 브릿지만 로드됨.</p></body>
    """
}

extension SujiHostViewController: UIDocumentPickerDelegate {
    func documentPicker(_ c: UIDocumentPickerViewController,
                         didPickDocumentsAt urls: [URL]) {
        resolveDoc(urls, canceled: false)
    }
    func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {
        resolveDoc([], canceled: true)
    }
}
