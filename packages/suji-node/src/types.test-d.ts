/**
 * Type-only test — Node SDK invoke/invokeSync/call/callSync가 SujiHandlers augment를 추론.
 * tsc 컴파일 통과 = pass.
 */
import { call, callSync, invoke, invokeSync, BrowserWindow, tray, type TrayMenuItem } from "./index";

declare module "./index" {
  interface SujiHandlers {
    ping: { req: void; res: { msg: string } };
    greet: { req: { name: string }; res: string };
    add: { req: { a: number; b: number }; res: number };
  }
}

async function _compileChecks() {
  // void req — 인자 생략 가능, res 추론.
  const r1 = await call("zig", "ping");
  const _msg: string = r1.msg;

  // 일반 req — req 필드 강제, res 추론.
  const r2 = await call("zig", "greet", { name: "Suji" });
  const _greet: string = r2;

  // sync 동일 추론.
  const s1 = callSync("zig", "ping");
  const _smsg: string = s1.msg;

  const s2 = callSync("zig", "greet", { name: "x" });
  const _sgreet: string = s2;

  // raw invoke도 request.cmd 기준으로 req/res 추론.
  const r3 = await invoke("zig", { cmd: "ping" });
  const _imsg: string = r3.msg;

  const r4 = await invoke("zig", { cmd: "greet", name: "Suji" });
  const _igreet: string = r4;

  const r5 = await invoke("zig", { cmd: "add", a: 1, b: 2 });
  const _isum: number = r5;

  const s3 = invokeSync("zig", { cmd: "greet", name: "x" });
  const _isync: string = s3;

  // untyped invoke는 그대로 동작 (backwards compat).
  const r6 = await invoke<{ ok: boolean }>("zig", { cmd: "anything" });
  const _ok: boolean = r6.ok;

  // @ts-expect-error - 'greet'은 name 필수, 인자 누락.
  await call("zig", "greet");

  // @ts-expect-error - field 이름 오타.
  await call("zig", "greet", { Name: "x" });

  // @ts-expect-error - 등록 안 된 cmd.
  await call("zig", "nonexistent-cmd");

  // @ts-expect-error - res 타입 mismatch.
  const _wrong: number = await call("zig", "greet", { name: "x" });

  // @ts-expect-error - raw invoke도 req 누락 시 typed string으로 쓸 수 없어야 한다.
  const _badRawMissing: string = await invoke("zig", { cmd: "greet" });

  // @ts-expect-error - raw invoke도 field 이름 오타면 typed string으로 쓸 수 없어야 한다.
  const _badRawTypo: string = await invoke("zig", { cmd: "greet", Name: "x" });

  // @ts-expect-error - raw invoke res 타입 mismatch.
  const _badRawRes: number = await invoke("zig", { cmd: "greet", name: "x" });

  void _msg; void _greet; void _smsg; void _sgreet; void _imsg; void _igreet; void _isum;
  void _isync; void _ok; void _wrong; void _badRawMissing; void _badRawTypo; void _badRawRes;
}
void _compileChecks;

async function _bwChecks() {
  const win = await BrowserWindow.create({ title: "x" }); // Promise<BrowserWindow>
  const _id: number = win.id;
  const u = await win.getURL();
  const _url: string | null = u.url;     // GetUrlResponse.url 추론(nullable)
  const r = await win.setTitle("t");
  const _wid: number = r.windowId;       // WindowOpResponse.windowId 추론
  const view = await win.createView({ url: "https://example.com", width: 320, height: 200 });
  const _vid: number = view.viewId;
  await win.setViewBounds(_vid, { x: 0, y: 0, width: 320, height: 200 });
  await win.setViewVisible(_vid, true);
  await win.removeChildView(_vid);
  const children = await win.getChildViews();
  const _childIds: number[] = children.viewIds;

  // @ts-expect-error - id 는 readonly getter.
  win.id = 9;
  // @ts-expect-error - private 생성자.
  new BrowserWindow(1);
  // @ts-expect-error - setTitle 은 string 필수.
  await win.setTitle(123);

  void _id; void _url; void _wid; void _vid; void _childIds;
}
void _bwChecks;

async function _trayChecks() {
  await tray.create({ title: "x", tooltip: "tip", iconPath: "/tmp/tray.png" });
  const items: TrayMenuItem[] = [
    { label: "Run", click: "run", enabled: true },
    { type: "checkbox", label: "Flag", click: "flag", checked: true },
    { label: "More", submenu: [{ label: "Child", click: "child" }] },
    { type: "separator" },
  ];
  await tray.setMenu(1, items);
}
void _trayChecks;
