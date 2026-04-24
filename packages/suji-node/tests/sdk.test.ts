/**
 * @suji/node SDK 단위 테스트 — 1 기능 1 테스트
 *
 * `globalThis.suji` 브릿지가 주입되지 않은 상태에서의 계약 검증.
 * (Suji 앱 안에서 실행될 때의 실제 동작은 E2E에서 검증.)
 *
 * 실행: `bun test packages/suji-node/tests/sdk.test.ts`
 */
import { describe, test, expect, beforeEach } from "bun:test";
import {
  quit,
  platform,
  PLATFORM_MACOS,
  PLATFORM_LINUX,
  PLATFORM_WINDOWS,
} from "../src/index";

beforeEach(() => {
  // 각 테스트가 자기 브릿지를 세팅/해제 (전역 오염 방지)
  (globalThis as any).suji = undefined;
});

describe("platform constants", () => {
  test("PLATFORM_MACOS 값", () => expect(PLATFORM_MACOS).toBe("macos"));
  test("PLATFORM_LINUX 값", () => expect(PLATFORM_LINUX).toBe("linux"));
  test("PLATFORM_WINDOWS 값", () => expect(PLATFORM_WINDOWS).toBe("windows"));
});

describe("bridge absent", () => {
  test("quit() throws when bridge missing", () => {
    expect(() => quit()).toThrow(/bridge not available/);
  });

  test("platform() throws when bridge missing", () => {
    expect(() => platform()).toThrow(/bridge not available/);
  });
});

describe("bridge stubbed", () => {
  test("quit() delegates to bridge.quit", () => {
    let called = false;
    (globalThis as any).suji = {
      quit: () => {
        called = true;
      },
      platform: () => "macos",
      handle: () => {},
      invoke: async () => "",
      invokeSync: () => "",
      send: () => {},
      on: () => 0,
      off: () => {},
      register: () => {},
    };
    quit();
    expect(called).toBe(true);
  });

  test("platform() returns bridge.platform()", () => {
    (globalThis as any).suji = {
      quit: () => {},
      platform: () => "linux",
      handle: () => {},
      invoke: async () => "",
      invokeSync: () => "",
      send: () => {},
      on: () => 0,
      off: () => {},
      register: () => {},
    };
    expect(platform()).toBe("linux");
  });
});
