/**
 * Linux notification runtime E2E.
 *
 * Linux Actions runs this under dbus-run-session with a fake
 * org.freedesktop.Notifications service. That lets us verify the real D-Bus
 * Notify and CloseNotification calls without relying on a desktop shell UI.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;
let service: ChildProcessWithoutNullStreams | undefined;

const runId = `${process.pid}-${Date.now()}`;
const baseDir = path.join(os.tmpdir(), `suji-notification-e2e-${runId}`);
const notifyPath = path.join(baseDir, "notify.json");
const closePath = path.join(baseDir, "close.json");
const readyPath = path.join(baseDir, "ready");
const servicePath = path.join(baseDir, "fake-notifications.py");

const core = <T = any>(request: Record<string, unknown>): Promise<T> =>
  page.evaluate(
    (req) => (window as any).__suji__.core(JSON.stringify(req)),
    request as any,
  ) as Promise<T>;

function pyString(value: string): string {
  return JSON.stringify(value);
}

async function waitForFile(filePath: string, label: string): Promise<void> {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) return;
    if (service?.exitCode !== null) {
      throw new Error(`${label} did not appear before fake notification service exited`);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${label} did not appear: ${filePath}`);
}

async function startFakeNotifications(): Promise<void> {
  fs.rmSync(baseDir, { recursive: true, force: true });
  fs.mkdirSync(baseDir, { recursive: true });
  fs.writeFileSync(
    servicePath,
    [
      "import dbus",
      "import dbus.service",
      "import dbus.mainloop.glib",
      "import json",
      "from gi.repository import GLib",
      "",
      `NOTIFY = ${pyString(notifyPath)}`,
      `CLOSE = ${pyString(closePath)}`,
      `READY = ${pyString(readyPath)}`,
      "",
      "dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)",
      "bus = dbus.SessionBus()",
      "name = dbus.service.BusName('org.freedesktop.Notifications', bus=bus, do_not_queue=True)",
      "",
      "class Notifications(dbus.service.Object):",
      "    @dbus.service.method('org.freedesktop.Notifications', in_signature='', out_signature='ssss')",
      "    def GetServerInformation(self):",
      "        return ('Suji E2E', 'Suji', '1.0', '1.2')",
      "",
      "    @dbus.service.method('org.freedesktop.Notifications', in_signature='susssasa{sv}i', out_signature='u')",
      "    def Notify(self, app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout):",
      "        with open(NOTIFY, 'w', encoding='utf-8') as f:",
      "            json.dump({",
      "                'appName': str(app_name),",
      "                'replacesId': int(replaces_id),",
      "                'appIcon': str(app_icon),",
      "                'summary': str(summary),",
      "                'body': str(body),",
      "                'actions': [str(a) for a in actions],",
      "                'hints': {str(k): str(v) for k, v in hints.items()},",
      "                'expireTimeout': int(expire_timeout),",
      "            }, f)",
      "        return dbus.UInt32(77)",
      "",
      "    @dbus.service.method('org.freedesktop.Notifications', in_signature='u', out_signature='')",
      "    def CloseNotification(self, notification_id):",
      "        with open(CLOSE, 'w', encoding='utf-8') as f:",
      "            json.dump({'notificationId': int(notification_id)}, f)",
      "",
      "Notifications(bus, '/org/freedesktop/Notifications')",
      "with open(READY, 'w', encoding='utf-8') as f:",
      "    f.write('ready')",
      "GLib.MainLoop().run()",
      "",
    ].join("\n"),
  );

  service = spawn("python3", [servicePath], { stdio: ["ignore", "pipe", "pipe"] });
  service.stdout.on("data", (chunk) => process.stdout.write(`[fake-notifications] ${chunk}`));
  service.stderr.on("data", (chunk) => process.stderr.write(`[fake-notifications] ${chunk}`));
  await waitForFile(readyPath, "notification service ready marker");
}

beforeAll(async () => {
  if (process.platform === "linux") {
    await startFakeNotifications();
  } else {
    fs.rmSync(baseDir, { recursive: true, force: true });
    fs.mkdirSync(baseDir, { recursive: true });
  }

  browser = await puppeteer.connect({
    browserURL: "http://localhost:9222",
    protocolTimeout: 30000,
    defaultViewport: null,
  });
  page = await getMainPage(browser);
  page.setDefaultTimeout(30000);
});

afterAll(async () => {
  await browser?.disconnect();
  service?.kill("SIGTERM");
  fs.rmSync(baseDir, { recursive: true, force: true });
});

describe("notification Linux runtime APIs", () => {
  test("response shape is stable on every platform", async () => {
    const supported = await core<{ supported: boolean }>({ cmd: "notification_is_supported" });
    expect(typeof supported.supported).toBe("boolean");

    const shown = await core<{ notificationId: string; success: boolean }>({
      cmd: "notification_show",
      title: "Shape",
      body: "Response shape",
      silent: true,
    });
    expect(shown.notificationId).toMatch(/^suji-notif-\d+$/);
    expect(typeof shown.success).toBe("boolean");
  });

  test.skipIf(process.platform !== "linux")(
    "Linux calls org.freedesktop.Notifications Notify and CloseNotification",
    async () => {
      fs.rmSync(notifyPath, { force: true });
      fs.rmSync(closePath, { force: true });

      const supported = await core<{ supported: boolean }>({ cmd: "notification_is_supported" });
      expect(supported.supported).toBe(true);

      const granted = await core<{ granted: boolean }>({ cmd: "notification_request_permission" });
      expect(granted.granted).toBe(true);

      const shown = await core<{ notificationId: string; success: boolean }>({
        cmd: "notification_show",
        title: "Linux title",
        body: "Linux body",
        silent: true,
      });
      expect(shown.success).toBe(true);
      expect(shown.notificationId).toMatch(/^suji-notif-\d+$/);

      await waitForFile(notifyPath, "notification Notify marker");
      const notify = JSON.parse(fs.readFileSync(notifyPath, "utf8")) as {
        appName: string;
        replacesId: number;
        appIcon: string;
        summary: string;
        body: string;
        actions: string[];
        hints: Record<string, string>;
        expireTimeout: number;
      };
      expect(notify).toEqual({
        appName: "Suji",
        replacesId: 0,
        appIcon: "",
        summary: "Linux title",
        body: "Linux body",
        actions: [],
        hints: {},
        expireTimeout: -1,
      });

      const closed = await core<{ success: boolean }>({
        cmd: "notification_close",
        notificationId: shown.notificationId,
      });
      expect(closed.success).toBe(true);

      await waitForFile(closePath, "notification CloseNotification marker");
      const close = JSON.parse(fs.readFileSync(closePath, "utf8")) as { notificationId: number };
      expect(close.notificationId).toBe(77);
    },
  );
});
