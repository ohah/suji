/**
 * Type-only test — Node SDK call/callSync가 SujiHandlers augment를 추론.
 * tsc 컴파일 통과 = pass.
 */
import { call, callSync, invoke } from "./index";

declare module "./index" {
  interface SujiHandlers {
    ping: { req: void; res: { msg: string } };
    greet: { req: { name: string }; res: string };
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

  // untyped invoke는 그대로 동작 (backwards compat).
  const r3 = await invoke<{ ok: boolean }>("zig", { cmd: "anything" });
  const _ok: boolean = r3.ok;

  // @ts-expect-error - 'greet'은 name 필수, 인자 누락.
  await call("zig", "greet");

  // @ts-expect-error - field 이름 오타.
  await call("zig", "greet", { Name: "x" });

  // @ts-expect-error - 등록 안 된 cmd.
  await call("zig", "nonexistent-cmd");

  // @ts-expect-error - res 타입 mismatch.
  const _wrong: number = await call("zig", "greet", { name: "x" });

  void _msg; void _greet; void _smsg; void _sgreet; void _ok; void _wrong;
}
void _compileChecks;
