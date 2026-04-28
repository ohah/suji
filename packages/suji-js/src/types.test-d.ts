/**
 * Type-only test — `invoke` generic overload가 SujiHandlers augment를 정확히 추론하는지
 * 검증. tsc 컴파일 통과 = pass. 런타임 실행은 없음 (이름이 .test-d.ts라 bun이 skip).
 */
import { invoke, type InvokeOptions } from "./index";

declare module "./index" {
  interface SujiHandlers {
    ping: { req: void; res: { msg: string } };
    greet: { req: { name: string }; res: string };
    add: { req: { a: number; b: number }; res: number };
  }
}

// 컴파일 통과 = type system이 의도대로 동작.
async function _compileChecks() {
  // void req — 인자 생략 가능, 응답 타입 추론.
  const r1 = await invoke("ping");
  const _msg: string = r1.msg;

  // 일반 req — 객체 강제, 응답 타입 추론.
  const r2 = await invoke("greet", { name: "Suji" });
  const _greet: string = r2;

  // 숫자 응답.
  const r3 = await invoke("add", { a: 1, b: 2 });
  const _sum: number = r3;

  // 옵션 함께 전달.
  const r4 = await invoke("greet", { name: "x" }, { target: "rust" } as InvokeOptions);
  const _greet2: string = r4;

  // 등록 안 된 cmd — untyped (unknown 반환). 사용자가 `as`로 단언.
  const r5 = (await invoke("custom-cmd", { foo: 1 })) as { ok: boolean };
  const _ok: boolean = r5.ok;

  // @ts-expect-error - 'greet'은 req: { name: string } 필수, 인자 누락.
  await invoke("greet");

  // @ts-expect-error - req field 이름 오타.
  await invoke("greet", { Name: "x" });

  // @ts-expect-error - res 타입 mismatch (greet은 string 반환).
  const _wrong: number = await invoke("greet", { name: "x" });

  // res 추론 보존을 위해 unused expressions silence.
  void _msg; void _greet; void _sum; void _greet2; void _ok; void _wrong;
}
void _compileChecks;
