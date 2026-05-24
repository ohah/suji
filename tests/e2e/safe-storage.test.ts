/**
 * safeStorage E2E — OS secure store round-trips.
 *
 * macOS: Keychain Services.
 * Windows: Credential Manager.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { callCore, getMainPage } from "./_page";

let browser: Browser;
let page: Page;

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  callCore<T>(page, request);

const SVC = `Suji-e2e-safe-storage-${process.platform}`;
const touchedAccounts = new Set<string>();

const account = (name: string) => {
  const value = `${name}-${process.pid}-${Date.now()}`;
  touchedAccounts.add(value);
  return value;
};

beforeAll(async () => {
  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  for (const acc of touchedAccounts) {
    await core({ cmd: "safe_storage_delete", service: SVC, account: acc }).catch(() => {});
  }
  await browser?.disconnect();
});

describe("safeStorage core commands", () => {
  test("set → get round-trip", async () => {
    const acc = account("roundtrip");
    const setR = await core<{ success: boolean }>({
      cmd: "safe_storage_set",
      service: SVC,
      account: acc,
      value: "secret-value",
    });
    expect(setR.success).toBe(true);

    const getR = await core<{ value: string }>({
      cmd: "safe_storage_get",
      service: SVC,
      account: acc,
    });
    expect(getR.value).toBe("secret-value");
  });

  test("same key set twice updates value", async () => {
    const acc = account("update");
    await core({ cmd: "safe_storage_set", service: SVC, account: acc, value: "first" });
    const setR = await core<{ success: boolean }>({
      cmd: "safe_storage_set",
      service: SVC,
      account: acc,
      value: "second",
    });
    expect(setR.success).toBe(true);

    const getR = await core<{ value: string }>({ cmd: "safe_storage_get", service: SVC, account: acc });
    expect(getR.value).toBe("second");
  });

  test("delete is idempotent and clears value", async () => {
    const acc = account("delete");
    await core({ cmd: "safe_storage_set", service: SVC, account: acc, value: "to-delete" });

    const del1 = await core<{ success: boolean }>({ cmd: "safe_storage_delete", service: SVC, account: acc });
    const del2 = await core<{ success: boolean }>({ cmd: "safe_storage_delete", service: SVC, account: acc });
    expect(del1.success).toBe(true);
    expect(del2.success).toBe(true);

    const getR = await core<{ value: string }>({ cmd: "safe_storage_get", service: SVC, account: acc });
    expect(getR.value).toBe("");
  });

  test("escape-sensitive value round-trips", async () => {
    const acc = account("escape");
    const value = 'a"b\\c\n한글';
    await core({ cmd: "safe_storage_set", service: SVC, account: acc, value });

    const getR = await core<{ value: string }>({ cmd: "safe_storage_get", service: SVC, account: acc });
    expect(getR.value).toBe(value);
  });

  test("service namespace isolates same account", async () => {
    const acc = account("isolation");
    const svcA = `${SVC}-A`;
    const svcB = `${SVC}-B`;
    await core({ cmd: "safe_storage_set", service: svcA, account: acc, value: "value-A" });
    await core({ cmd: "safe_storage_set", service: svcB, account: acc, value: "value-B" });

    const a = await core<{ value: string }>({ cmd: "safe_storage_get", service: svcA, account: acc });
    const b = await core<{ value: string }>({ cmd: "safe_storage_get", service: svcB, account: acc });
    expect(a.value).toBe("value-A");
    expect(b.value).toBe("value-B");

    await core({ cmd: "safe_storage_delete", service: svcA, account: acc });
    const aAfter = await core<{ value: string }>({ cmd: "safe_storage_get", service: svcA, account: acc });
    const bAfter = await core<{ value: string }>({ cmd: "safe_storage_get", service: svcB, account: acc });
    expect(aAfter.value).toBe("");
    expect(bAfter.value).toBe("value-B");

    await core({ cmd: "safe_storage_delete", service: svcB, account: acc });
  });
});
