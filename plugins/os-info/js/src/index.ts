/**
 * @suji/plugin-os — OS info for Suji renderer (Electron `os` / Tauri `os` 패리티).
 *
 * ```ts
 * import { os } from '@suji/plugin-os';
 * const info = await os.info();          // { platform, arch, version, hostname, ... }
 * const p = await os.platform();         // "darwin" | "linux" | "win32"
 * ```
 */

interface SujiBridge {
  invoke(channel: string, data?: Record<string, unknown>): Promise<any>;
}

function getBridge(): SujiBridge {
  const bridge = (window as any).__suji__;
  if (!bridge) throw new Error("Suji bridge not available.");
  return bridge;
}

export interface OsInfo {
  /** Node-style platform token: "darwin" | "linux" | "win32". */
  platform: string;
  /** Suji-style platform token: "macos" | "linux" | "windows". */
  sujiPlatform: string;
  /** "arm64" | "x64" | ... */
  arch: string;
  /** OS family (zig os tag). */
  family: string;
  /** Kernel/OS release string (POSIX uname). */
  version: string;
  hostname: string;
  /** Line ending: "\n" or "\r\n". */
  eol: string;
}

async function info(): Promise<OsInfo> {
  const r = await getBridge().invoke("os:info");
  return r?.result as OsInfo;
}

export const os = {
  info,
  async platform(): Promise<string> {
    return (await info()).platform;
  },
  async arch(): Promise<string> {
    return (await info()).arch;
  },
  async version(): Promise<string> {
    return (await info()).version;
  },
  async hostname(): Promise<string> {
    return (await info()).hostname;
  },
  async eol(): Promise<string> {
    return (await info()).eol;
  },
};
