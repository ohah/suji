import Foundation

// sqlite 변형 — SQLite 정적 백엔드만 등록 (suji_sqlite_backend_*).
// 데스크탑 plugins/sqlite 모바일 대응. 공용 sujiBridgeRequest/sujiReg 는
// _shared/BackendBridge.swift. 반환 포인터는 백엔드 소유 — 코어가 복사 후
// sqliteFree 로 반납(register_handler 계약).

private func sqliteHandler(
    _ channel: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    sujiBridgeRequest(channel, json).withCString { UnsafePointer(suji_sqlite_backend_handle_ipc($0)) }
}
private func sqliteFree(_ p: UnsafePointer<CChar>?) {
    suji_sqlite_backend_free(UnsafeMutablePointer(mutating: p))
}

func registerStaticBackends() {
    suji_sqlite_backend_init(nil)
    sujiReg("sql:open", sqliteHandler, sqliteFree)
    sujiReg("sql:execute", sqliteHandler, sqliteFree)
    sujiReg("sql:query", sqliteHandler, sqliteFree)
    sujiReg("sql:close", sqliteHandler, sqliteFree)
}
