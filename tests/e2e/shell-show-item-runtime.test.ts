/**
 * Shell showItemInFolder runtime E2E.
 *
 * Linux Actions runs this under dbus-run-session with a fake FileManager1
 * service and verifies Suji calls ShowItems with the file URI.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import puppeteer, { type Browser, type Page } from "puppeteer-core";
import { getMainPage } from "./_page";

let browser: Browser;
let page: Page;
let service: ChildProcessWithoutNullStreams | undefined;

const runId = `${process.pid}-${Date.now()}`;
const baseDir = path.join(os.tmpdir(), `suji-show-item-e2e-${runId}`);
const markerPath = path.join(baseDir, "marker.json");
const readyPath = path.join(baseDir, "ready");
const servicePath = path.join(baseDir, "fake-file-manager.py");
const targetPath = path.join(baseDir, "target-file.txt");

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
      throw new Error(`${label} did not appear before fake FileManager1 exited`);
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${label} did not appear: ${filePath}`);
}

async function waitForMarker(expectedUri: string): Promise<void> {
  await waitForFile(markerPath, "FileManager1 marker");
  const data = JSON.parse(fs.readFileSync(markerPath, "utf8")) as {
    uris: string[];
    startupId: string;
  };
  expect(data.uris).toEqual([expectedUri]);
  expect(data.startupId).toBe("");
}

async function startFakeFileManager(): Promise<void> {
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
      `MARKER = ${pyString(markerPath)}`,
      `READY = ${pyString(readyPath)}`,
      "",
      "dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)",
      "bus = dbus.SessionBus()",
      "name = dbus.service.BusName('org.freedesktop.FileManager1', bus=bus, do_not_queue=True)",
      "",
      "class FileManager(dbus.service.Object):",
      "    @dbus.service.method('org.freedesktop.FileManager1', in_signature='ass', out_signature='')",
      "    def ShowItems(self, uris, startup_id):",
      "        with open(MARKER, 'w', encoding='utf-8') as f:",
      "            json.dump({'uris': [str(u) for u in uris], 'startupId': str(startup_id)}, f)",
      "",
      "FileManager(bus, '/org/freedesktop/FileManager1')",
      "with open(READY, 'w', encoding='utf-8') as f:",
      "    f.write('ready')",
      "GLib.MainLoop().run()",
      "",
    ].join("\n"),
  );

  service = spawn("python3", [servicePath], { stdio: ["ignore", "pipe", "pipe"] });
  service.stdout.on("data", (chunk) => process.stdout.write(`[fake-file-manager] ${chunk}`));
  service.stderr.on("data", (chunk) => process.stderr.write(`[fake-file-manager] ${chunk}`));
  await waitForFile(readyPath, "FileManager1 ready marker");
}

beforeAll(async () => {
  if (process.platform === "linux") {
    await startFakeFileManager();
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

describe("shell.showItemInFolder runtime APIs", () => {
  test("missing path returns false and does not call FileManager1", async () => {
    fs.rmSync(markerPath, { force: true });
    const result = await core<{ success: boolean }>({
      cmd: "shell_show_item_in_folder",
      path: path.join(baseDir, "missing.txt"),
    });
    expect(result.success).toBe(false);
    expect(fs.existsSync(markerPath)).toBe(false);
  });

  test.skipIf(process.platform !== "linux")(
    "Linux calls org.freedesktop.FileManager1.ShowItems with file URI",
    async () => {
      fs.writeFileSync(targetPath, "reveal me");
      fs.rmSync(markerPath, { force: true });

      const result = await core<{ success: boolean }>({
        cmd: "shell_show_item_in_folder",
        path: targetPath,
      });
      expect(result.success).toBe(true);
      await waitForMarker(pathToFileURL(targetPath).href);
    },
  );
});
