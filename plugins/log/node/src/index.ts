/**
 * @suji/plugin-log-node — Rotating file logger for Suji Node.js backends
 *
 * Renderer 의 `@suji/plugin-log` 와 동일 wire contract — `log` 백엔드에 cmd
 * embedded JSON 으로 라우팅 (state/sqlite Node wrapper 동형).
 *
 * ```ts
 * const { log } = require('@suji/plugin-log-node');
 *
 * await log.info("started", { pid: process.pid });
 * await log.error("oops", { user: "yoon" });
 * await log.setLevel("warn");
 * const tail = await log.read(50);
 * ```
 */

interface SujiBridge {
  invoke(backend: string, request: string): Promise<string>;
}

function getBridge(): SujiBridge {
  const bridge = (globalThis as any).suji as SujiBridge | undefined;
  if (!bridge) {
    throw new Error(
      "@suji/plugin-log-node: bridge not available. This module must run inside a Suji app (libnode embedding).",
    );
  }
  return bridge;
}

export type LogLevel = "trace" | "debug" | "info" | "warn" | "error" | "off";

export interface LogEntry {
  ts: number;
  level: LogLevel;
  message: string;
  context?: Record<string, unknown>;
}

async function call(cmd: string, payload: Record<string, unknown>): Promise<any> {
  const raw = await getBridge().invoke("log", JSON.stringify({ cmd, ...payload }));
  let resp: any;
  try {
    resp = JSON.parse(raw);
  } catch {
    resp = {};
  }
  if (resp?.error) throw new Error(`log: ${resp.error}`);
  return resp?.result;
}

async function writeAt(level: LogLevel, message: string, context?: Record<string, unknown>): Promise<void> {
  await call("log:write", context !== undefined ? { level, message, context } : { level, message });
}

export const log = {
  trace: (message: string, context?: Record<string, unknown>) => writeAt("trace", message, context),
  debug: (message: string, context?: Record<string, unknown>) => writeAt("debug", message, context),
  info: (message: string, context?: Record<string, unknown>) => writeAt("info", message, context),
  warn: (message: string, context?: Record<string, unknown>) => writeAt("warn", message, context),
  error: (message: string, context?: Record<string, unknown>) => writeAt("error", message, context),

  async setLevel(level: LogLevel): Promise<void> {
    await call("log:set_level", { level });
  },

  async getLevel(): Promise<LogLevel> {
    const r = await call("log:get_level", {});
    return (r?.level ?? "info") as LogLevel;
  },

  async read(lines: number = 100): Promise<LogEntry[]> {
    const r = await call("log:read", { lines: String(lines) });
    return (r?.entries ?? []) as LogEntry[];
  },

  async setPath(path: string): Promise<string> {
    const r = await call("log:set_path", { path });
    return (r?.path ?? path) as string;
  },

  async getPath(): Promise<string> {
    const r = await call("log:get_path", {});
    return (r?.path ?? "") as string;
  },
};
